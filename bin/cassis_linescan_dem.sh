#!/bin/bash
# cassis_linescan_dem.sh - linescan DEM + sparse align to a coarse CTX DEM.
# From the framelet cubes: assemble a continuous LINESCAN strip per look, tie L+R with
# bundle_adjust (inline), stereo, point2dem, then a SPARSE pc_align (hillshade initial
# transform, rigid, max-disp -1, num-iter 0) to the coarse CTX, and regrid the aligned DEM
# onto the coarse grid.
#
# ALL COARSE: the coarse CTX is the ONLY geometry source - its proj, grid size, tr and
# extent drive every output (seed, point2dem, align ref, regrid target). Nothing about
# grid/proj is hardcoded; grid + proj always agree because they come from one file.
#
# Usage: cassis_linescan_dem.sh <site.conf> <outDir> <workdir>
set -e

# ASP/ISIS tools on PATH and the environment are set up by the caller. See the README.
umask 022
cfg=${1:?usage: cassis_linescan_dem.sh <site.conf> <outDir> <workdir>}
outDir=${2:?outDir (output dir, relative to workdir or absolute)}
B=${3:?workdir}
cd "$B" || { echo "ERROR cannot cd $B"; exit 1; }
# The helper python scripts live next to this script (the pipeline bin dir), so
# invoke them by their own location, not relative to the work dir.
BIN=$(cd "$(dirname "$0")" && pwd)
[ -s "$B/cassis_common.conf" ] && source "$B/cassis_common.conf"
[ -s "$B/$cfg" ] || { echo "ERROR missing site config $cfg"; exit 1; }
source "$B/$cfg"
source cassis_env_check.sh
cassis_require bundle_adjust parallel_stereo point2dem pc_align gdalwarp gdalinfo gdalsrsinfo

# Input cubs come from inputCassisDir (found by look sid); outputs go under outDir.
site=$(basename "$cfg" .conf | sed 's/^cassis_//; s/_site$//')   # nick, for the log name
dataDir=$inputCassisDir
sidL=$Llook; sidR=$Rlook
work=$outDir/linescan
coarse=$refDem
[ -s "$coarse" ] || { echo "ERROR missing reference CTX (refDem) $coarse"; exit 1; }
mkdir -p "$work"
# Idempotent: if the final aligned linescan DEM already exists, there is nothing to do.
# Checked before the log redirect below, so the message reaches the terminal.
if [ -s "$work/linescan_dem/align/aligned_oncoarse.tif" ]; then
  echo "linescan DEM exists, skipping: $work/linescan_dem/align/aligned_oncoarse.tif"
  exit 0
fi
log=$B/output_linescan_${site}.txt
exec > "$log" 2>&1
echo "START $(date) host=$(uname -n) site=$site"

# --- grid + proj: SINGLE source of truth = the coarse CTX (agreement guaranteed) ---
srs=$(gdalsrsinfo -o proj4 "$coarse" | tr -d '\n' | sed 's/^ *//; s/ *$//')
GI=$(gdalinfo "$coarse")
NX=$(echo "$GI" | awk -F'[ ,]+' '/^Size is/{print $3}')
NY=$(echo "$GI" | awk -F'[ ,]+' '/^Size is/{print $4}')
TR=$(echo "$GI" | awk '/Pixel Size/{gsub(/[(),]/," "); print $4; exit}')
read XMIN YMIN XMAX YMAX < <(echo "$GI" | awk '/Upper Left/{gsub(/[(),]/," "); ulx=$3; uly=$4} /Lower Right/{gsub(/[(),]/," "); lrx=$3; lry=$4} END{print ulx, lry, lrx, uly}')
echo "coarse=$coarse"
echo "srs='$srs'"
echo "grid: tr=$TR size=${NX}x${NY} te='$XMIN $YMIN $XMAX $YMAX'"

# Parallel processing caps. Defaults are conservative for a shared workstation.
# Override via the environment for a dedicated compute node (more processes/threads).
MAPCAP=${MAPCAP:-"--processes 2 --threads 3"}
PSCAP=${PSCAP:-"--processes 2 --threads-multiprocess 3 --threads-singleprocess 6"}

# --- S1-S2: strips + linescan ISDs (regen if missing; needs raw framelets present) ---
Ls=$work/${sidL}_strip.tif; Rs=$work/${sidR}_strip.tif
Lisd=$work/${sidL}_linescan.json; Risd=$work/${sidR}_linescan.json
if [ ! -s "$Ls" ] || [ ! -s "$Rs" ] || [ ! -s "$Lisd" ] || [ ! -s "$Risd" ]; then
  echo "=== S1 stack_strip_gen (strips, sub-pixel pitch) ==="
  [ -n "$(cassis_look_cubs "$inputCassisDir" "$sidL")" ] || { echo "ERROR no framelet cubs for look $sidL under $inputCassisDir"; exit 1; }
  python3 "$BIN/stack_strip_gen.py" "$dataDir" "$sidL" "$sidR" "$work" | tee "$work/strip_gen.txt"
  for sid in "$sidL" "$sidR"; do
    line=$(grep "^${sid}:" "$work/strip_gen.txt")
    rev=$(echo "$line" | grep -q REVERSE && echo 1 || echo 0)
    keep=$(echo "$line" | sed -n 's/.*KEEP=\([0-9]*\).*/\1/p')
    echo "=== S1b assemble_pushframe sid=$sid reverse=$rev keep=$keep ==="
    python3 "$BIN/assemble_pushframe_gen.py" "$dataDir" "$sid" "$rev" "$keep" "$work/${sid}_pushframe.json"
    echo "=== S2 pushframe2linescan sid=$sid ==="
    python3 "$BIN/pushframe2linescan.py" "$work/${sid}_pushframe.json" "$work/${sid}_linescan.json"
  done
fi
for f in "$Ls" "$Rs" "$Lisd" "$Risd"; do [ -s "$f" ] || { echo "ERROR missing $f"; exit 1; }; done

out=$work/linescan_dem; mkdir -p "$out/ba" "$out/stereo" "$out/align"
seed=$coarse                                    # all coarse: seed = coarse ctx

# --- S3: BA tie (L+R linescan, inline) ---
bap=$out/ba/run
Lc=$bap-$(basename ${Lisd%.json}).adjusted_state.json
Rc=$bap-$(basename ${Risd%.json}).adjusted_state.json
if [ -s "$Lc" ] && [ -s "$Rc" ]; then
  echo "=== S3 BA states present, skip ==="
else
  echo "=== S3 bundle_adjust --inline-adjustments (tie L+R linescan) ==="
  bundle_adjust "$Ls" "$Rs" "$Lisd" "$Risd" --inline-adjustments --datum D_MARS \
    --ip-detect-method 1 --ip-per-image 50000 --threads 6 \
    --remove-outliers-params "75 100 50 50" \
    --num-iterations 100 --robust-threshold 2 \
    -o "$bap" > "$out/ba_log.txt" 2>&1 || { echo "BA FAILED"; tail -25 "$out/ba_log.txt"; exit 1; }
  grep -iE "convergence angle|filtered interest" "$out/ba_log.txt" | head
fi

# --- S4: stereo WITHOUT mapproject (correlate at NATIVE res) + point2dem at native ---
# Mapprojecting at the coarse 18 m grid destroyed the ~4.59 m native CaSSIS detail and
# made the DEM rough. Correlate the raw strips directly (BA-tied cams, affineepipolar) so
# correlation runs at native res, and point2dem at NATIVE (auto-tr, ~4.59 m) so the DEM
# matches the prior 4.59 m products. proj comes from the coarse ctx (the coarse only
# dictates PROJ + the alignment target, NEVER the correlation/output res).
echo "=== S4 stereo (NO mapproject, native correlation) + point2dem native ==="
if [ -s "$out/stereo/run-PC.tif" ]; then
  echo "S4 PC present, skip stereo"
else
  parallel_stereo $PSCAP --alignment-method affineepipolar --stereo-algorithm asp_mgm \
    --subpixel-mode 9 --subpixel-kernel 7 7 --rm-half-kernel 0 0 --edge-buffer-size 0 \
    --rm-cleanup-passes 0 --erode-max-size 0 --corr-seed-mode 1 --sgm-collar-size 256 \
    "$Ls" "$Rs" "$Lc" "$Rc" "$out/stereo/run" \
    > "$out/stereo_log.txt" 2>&1 || { echo "STEREO FAILED"; tail -30 "$out/stereo_log.txt"; exit 1; }
fi
point2dem --errorimage --t_srs "$srs" "$out/stereo/run-PC.tif" -o "$out/stereo/dem" \
  > "$out/p2d_log.txt" 2>&1
dem=$out/stereo/dem-DEM.tif
echo "DEM after BA+stereo (native res): $dem"; ls -la "$dem"

# --- S5: sparse hillshade-init alignment to the coarse CTX ---
# Align the linescan stereo DEM to the coarse CTX with SPARSE interest points matched between the two
# hillshades: pc_align --initial-transform-from-hillshading rigid (RANSAC-filtered), no dense
# correlation and no match file. This is reliable ONLY because both DEMs are first put on the SAME
# coarse CTX grid (demc, below) before matching. The old failure of hillshade-init alone ("not enough
# valid matches" -> a degenerate scale + thousands-of-km transform that threw the cameras below the
# surface) came entirely from a hillshade SCALE MISMATCH (CTX ~18-20 m vs CaSSIS native ~4.6 m).
# Putting both on one grid removes that, and sparse IP then locks crater-on-crater. Dense correlation
# of the hillshades was the earlier workaround, but it has its own failure: on low-texture terrain it
# locks onto the featureless plains and leaves a 6-20 px residual, so sparse-IP is preferred. The CTX
# is windowed to the linescan footprint + a 10% margin (0 is tightest on texture-rich scenes but
# starves low-texture ones; 10% is the uniform value that serves both). Call 2 (below) applies the
# resulting transform to the point cloud. Judge the result by a red/green hillshade overlay, not dh/dv.
echo "=== S5 sparse hillshade-init align: pc_align --initial-transform-from-hillshading rigid ==="
al=$out/align; mkdir -p "$al"
# 1. put the native linescan DEM on the coarse CTX grid (same proj/extent/res) so hillshades match
demc=$al/ls_oncoarsegrid.tif
gdalwarp -q -overwrite -t_srs "$srs" -te $XMIN $YMIN $XMAX $YMAX -ts $NX $NY -r cubicspline \
  "$dem" "$demc" > "$out/align_warp_src.txt" 2>&1
# WINDOW coarse+demc to the linescan footprint + 10% margin BEFORE matching, so the sparse IP
# cannot lock onto a FAR spurious match on low-texture plains (a km-scale spurious-shift bug).
read WX0 WY0 WX1 WY1 < <(python3 -c "
from osgeo import gdal; import numpy as np
d=gdal.Open('$demc'); b=d.GetRasterBand(1); nd=b.GetNoDataValue(); a=b.ReadAsArray()
m=np.isfinite(a) if nd is None else (np.isfinite(a)&(a!=nd)); ys,xs=np.where(m); g=d.GetGeoTransform()
x0=g[0]+xs.min()*g[1]; x1=g[0]+(xs.max()+1)*g[1]; y0=g[3]+(ys.max()+1)*g[5]; y1=g[3]+ys.min()*g[5]
mx=abs(x1-x0)*0.1; my=abs(y1-y0)*0.1
print(min(x0,x1)-mx, min(y0,y1)-my, max(x0,x1)+mx, max(y0,y1)+my)")
cwin=$al/ctx_win.tif; dwin=$al/dem_win.tif
gdalwarp -q -overwrite -te $WX0 $WY0 $WX1 $WY1 -r cubicspline "$coarse" "$cwin" >/dev/null 2>&1
gdalwarp -q -overwrite -te $WX0 $WY0 $WX1 $WY1 -r cubicspline "$demc"   "$dwin" >/dev/null 2>&1
echo "  WINDOWED CTX to linescan footprint: $WX0 $WY0 $WX1 $WY1"
# ============================ ALIGN TOOLBOX (fall-through, corr-eval gated) ============================
# The align is a TOOLBOX: run a method, verify it with the corr-eval, and if it fails, fall through to the
# next method. Two helpers keep it DRY (no duplicated apply/eval code). run-transform.txt is always the
# cassis->ctx transform (pc_align ctx=ref cassis=source), the direction stage 2 (cassis_align_cams.sh) needs.

# helper: apply $al/run-transform.txt to the stereo PC -> native + coarse-grid aligned DEMs (+ error image)
apply_and_regrid() {
  pc_align --max-displacement -1 --num-iterations 0 --initial-transform "$al/run-transform.txt" \
    --save-transformed-source-points "$coarse" "$out/stereo/run-PC.tif" -o "$al/applied" \
    > "$out/align_apply.txt" 2>&1 || { echo "  APPLY FAILED"; tail -20 "$out/align_apply.txt"; }
  point2dem --errorimage --t_srs "$srs" "$al/applied-trans_source.tif" -o "$al/aligned" \
    > "$out/align_p2d.txt" 2>&1
  gdalwarp -overwrite -t_srs "$srs" -te $XMIN $YMIN $XMAX $YMAX -ts $NX $NY -r cubicspline \
    "$al/aligned-DEM.tif" "$al/aligned_oncoarse.tif" > "$out/align_warp.txt" 2>&1
  [ -s "$al/aligned-IntersectionErr.tif" ] && gdalwarp -overwrite -t_srs "$srs" -te $XMIN $YMIN $XMAX $YMAX \
    -ts $NX $NY -r cubicspline "$al/aligned-IntersectionErr.tif" "$al/aligned_oncoarse_err.tif" \
    > "$out/align_warp_err.txt" 2>&1
}
# helper: window the aligned DEM to the cwin grid, hillshade, write the red/green overlay (the eyeball judge),
# and correlate (asp_mgm, tight -25..25) for a robust-median residual dh/dv -> sets GDH GDV. set +e so a guard
# sub-command can never abort a good align. The tight eval is stable even on smooth terrain (verified oxia1).
eval_and_overlay() {
  set +e
  awin=$al/aligned_win.tif
  gdalwarp -q -overwrite -te $WX0 $WY0 $WX1 $WY1 -tr $TR $TR -r cubicspline \
    "$al/aligned_oncoarse.tif" "$awin" > /dev/null 2>&1
  gdaldem hillshade -alt 12 -multidirectional -compute_edges "$cwin"  "$al/guard_ctx_hs.tif" > /dev/null 2>&1
  gdaldem hillshade -alt 12 -multidirectional -compute_edges "$awin"  "$al/guard_ls_hs.tif"  > /dev/null 2>&1
  python3 - "$al/guard_ctx_hs.tif" "$al/guard_ls_hs.tif" "$al/align_overlay.tif" <<'PYO'
import sys, numpy as np
from osgeo import gdal
gdal.DontUseExceptions()
c=gdal.Open(sys.argv[1]); g=gdal.Open(sys.argv[2])
ca=c.GetRasterBand(1).ReadAsArray(); ga=g.GetRasterBand(1).ReadAsArray()
h=min(ca.shape[0],ga.shape[0]); w=min(ca.shape[1],ga.shape[1]); ca=ca[:h,:w]; ga=ga[:h,:w]
out=gdal.GetDriverByName('GTiff').Create(sys.argv[3],w,h,3,gdal.GDT_Byte)
out.SetGeoTransform(c.GetGeoTransform()); out.SetProjection(c.GetProjection())
out.GetRasterBand(1).WriteArray(ca.astype('uint8')); out.GetRasterBand(2).WriteArray(ga.astype('uint8'))
out.GetRasterBand(3).WriteArray(np.zeros((h,w),'uint8')); out.FlushCache()
PYO
  mkdir -p "$al/guard"
  parallel_stereo --correlator-mode --allow-different-gsd-in-correlator-mode \
    --stereo-algorithm asp_mgm --corr-kernel 9 9 --ip-per-tile 400 \
    --subpixel-mode 9 --corr-search -40 -40 40 40 $PSCAP \
    "$al/guard_ctx_hs.tif" "$al/guard_ls_hs.tif" "$al/guard/run" > "$out/align_guard.txt" 2>&1
  disparitydebug --raw "$al/guard/run-F.tif" --output-prefix "$al/guard/dd" > /dev/null 2>&1
  read GDH GDV < <(python3 - "$al/guard/dd-H.tif" "$al/guard/dd-V.tif" <<'PYG'
import numpy as np, sys
from osgeo import gdal
def md(f):
    d=gdal.Open(f)
    if d is None: return 999.0
    a=d.GetRasterBand(1).ReadAsArray().astype('float64'); nd=d.GetRasterBand(1).GetNoDataValue()
    m=np.isfinite(a)&(a!=nd)&(np.abs(a)<1e5)
    return float(np.median(a[m])) if m.any() else 999.0
print(f"{md(sys.argv[1]):.2f} {md(sys.argv[2]):.2f}")
PYG
)
}
# helper: is the current residual a PASS? |median| <= 10 px for BOTH dh and dv.
align_ok() { awk -v h="${GDH:-999}" -v v="${GDV:-999}" 'BEGIN{h=(h<0?-h:h);v=(v<0?-v:v);exit (h>10||v>10)?1:0}'; }

# ---- METHOD 1 (default): sparse hillshade-init, rigid (no scale). Works on textured sites. ----
echo "=== S5 METHOD 1: sparse hillshade-init (pc_align --initial-transform-from-hillshading rigid) ==="
pc_align --max-displacement -1 --num-iterations 0 --max-num-reference-points 1000000 \
  --initial-transform-from-hillshading rigid --initial-transform-ransac-params 1000 3 \
  --save-transformed-source-points "$cwin" "$dwin" -o "$al/run" > "$out/align_log.txt" 2>&1 \
  || { echo "  method 1 pc_align FAILED (recorded)"; tail -20 "$out/align_log.txt"; }
grep -aE "Translation vector|magnitude of translation|Number of.*matches" "$out/align_log.txt" | sed 's/^/  /'
GDH=999; GDV=999; method="sparse-IP"
[ -s "$al/run-transform.txt" ] && { apply_and_regrid; eval_and_overlay; }
echo "  method 1 (sparse-IP) residual dh/dv median = ${GDH} / ${GDV} px"

# ---- METHOD 2 (fall-through): asp_bm dense correlation + NED translation. Triggered only if method 1 fails. ----
# For low-texture sites (oxia1) sparse IP finds too few inliers -> a spurious transform, and the true shift is
# large (oxia1 ~164 px). asp_bm BLOCK MATCHING gives a CONSISTENT dense disparity where asp_mgm plains-locks;
# we take its robust MEDIAN disparity as a pure TRANSLATION (horizontal), recover the vertical with one
# translation-only ICP pass, and apply both as a num-iterations-0 --initial-ned-translation (no ICP drift).
if ! align_ok; then
  echo "=== S5 METHOD 1 failed the corr-eval -> METHOD 2: asp_bm dense correlation + NED translation ==="
  m2=$al/m2; mkdir -p "$m2"
  # a bigger window so a large low-texture shift is reachable (CTX fills what it has; nodata beyond is fine)
  read BX0 BY0 BX1 BY1 < <(python3 -c "print($WX0-4000,$WY0-4000,$WX1+4000,$WY1+4000)")
  cwin2=$m2/ctx_win.tif; dwin2=$m2/dem_win.tif
  gdalwarp -q -overwrite -te $BX0 $BY0 $BX1 $BY1 -tr $TR $TR -r cubicspline "$coarse" "$cwin2" >/dev/null 2>&1
  gdalwarp -q -overwrite -te $BX0 $BY0 $BX1 $BY1 -tr $TR $TR -r cubicspline "$demc"   "$dwin2" >/dev/null 2>&1
  gdaldem hillshade -alt 12 -multidirectional -compute_edges "$cwin2" "$m2/ctx_hs.tif" >/dev/null 2>&1
  gdaldem hillshade -alt 12 -multidirectional -compute_edges "$dwin2" "$m2/ls_hs.tif"  >/dev/null 2>&1
  mkdir -p "$m2/corr"
  parallel_stereo --correlator-mode --allow-different-gsd-in-correlator-mode --stereo-algorithm asp_bm \
    --corr-kernel 21 21 --cost-mode 2 --subpixel-mode 1 --corr-search -200 -200 200 200 $PSCAP \
    "$m2/ls_hs.tif" "$m2/ctx_hs.tif" "$m2/corr/run" > "$out/align_m2corr.txt" 2>&1
  disparitydebug --raw "$m2/corr/run-F.tif" --output-prefix "$m2/dd" >/dev/null 2>&1
  read MDH MDV < <(python3 - "$m2/dd-H.tif" "$m2/dd-V.tif" <<'PYM'
import numpy as np, sys
from osgeo import gdal
def md(f):
    d=gdal.Open(f)
    if d is None: return 0.0
    a=d.GetRasterBand(1).ReadAsArray().astype('float64'); nd=d.GetRasterBand(1).GetNoDataValue()
    v=a[np.isfinite(a)&(a!=nd)&(np.abs(a)<1e5)]; return float(np.median(v)) if v.size else 0.0
print(f"{md(sys.argv[1])} {md(sys.argv[2])}")
PYM
)
  Nn=$(python3 -c "print(-1.0*($MDV)*$TR)"); Ee=$(python3 -c "print(($MDH)*$TR)")
  echo "  asp_bm median disparity dh=$MDH dv=$MDV px -> horizontal NED  N=$Nn  E=$Ee (m)"
  # translation-only ICP to recover the vertical (its horizontal drifts on plains, so we discard that)
  pc_align --max-displacement -1 --num-iterations 40 --compute-translation-only \
    --initial-ned-translation "$Nn $Ee 0" --max-num-reference-points 2000000 \
    "$cwin2" "$dwin2" -o "$m2/icp" > "$out/align_m2icp.txt" 2>&1
  Dd=$(python3 -c "
import re
try:
    t=open('$out/align_m2icp.txt').read()
    m=re.findall(r'North-East-Down, meters\): Vector3\(([^)]*)\)', t)
    print(m[-1].split(',')[2].strip() if m else '0')
except Exception: print('0')")
  echo "  ICP vertical Down=$Dd m"
  # final transform: pure translation (asp_bm horizontal + ICP vertical), num-iter 0 -> run-transform.txt
  pc_align --max-displacement -1 --num-iterations 0 --initial-ned-translation "$Nn $Ee $Dd" \
    --save-transformed-source-points "$cwin2" "$dwin2" -o "$al/run" > "$out/align_m2final.txt" 2>&1
  method="asp_bm-dense"
  [ -s "$al/run-transform.txt" ] && { apply_and_regrid; eval_and_overlay; }
  echo "  method 2 (asp_bm-dense) residual dh/dv median = ${GDH} / ${GDV} px"
fi

# ---- report + final catch ----
if [ -s "$al/aligned_oncoarse.tif" ]; then
  echo "ALIGNED DEM (native): $al/aligned-DEM.tif ; on coarse grid: $al/aligned_oncoarse.tif"
  echo "  ALIGN METHOD USED: $method ; final residual dh/dv median = ${GDH} / ${GDV} px"
  echo "  RED/GREEN OVERLAY (the align judge): $al/align_overlay.tif (R=CTX G=aligned, yellow=registered)"
  align_ok || echo "  *** WARNING: linescan->CTX ALIGNMENT residual dh/dv median > 10 px after all methods. Inspect $al/align_overlay.tif (R=CTX, G=aligned) by eye. ***"
else
  echo "NO aligned DEM produced - all align methods failed (see $out/align_*.txt)"
fi
echo "DONE $(date) [$site]"
