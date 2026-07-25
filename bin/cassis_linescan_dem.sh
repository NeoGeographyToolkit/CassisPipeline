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
# 2. sparse hillshade-init: pc_align hillshades cwin/dwin internally, matches interest points between
#    them, and RANSAC-fits a rigid transform (writes run-transform.txt). No dense correlation, no match file.
pc_align --max-displacement -1 --num-iterations 0 --max-num-reference-points 1000000 \
  --initial-transform-from-hillshading rigid --initial-transform-ransac-params 1000 3 \
  --save-transformed-source-points "$cwin" "$dwin" -o "$al/run" > "$out/align_log.txt" 2>&1 \
  || { echo "ALIGN FAILED (recorded)"; tail -25 "$out/align_log.txt"; }
grep -aE "Translation vector|magnitude of translation|Number of.*matches" "$out/align_log.txt" | sed 's/^/  /'
if [ -s "$al/run-transform.txt" ]; then
  pc_align --max-displacement -1 --num-iterations 0 --initial-transform "$al/run-transform.txt" \
    --save-transformed-source-points "$coarse" "$out/stereo/run-PC.tif" -o "$al/applied" \
    > "$out/align_apply.txt" 2>&1 || { echo "APPLY FAILED"; tail -20 "$out/align_apply.txt"; }
  point2dem --errorimage --t_srs "$srs" "$al/applied-trans_source.tif" -o "$al/aligned" \
    > "$out/align_p2d.txt" 2>&1
  gdalwarp -overwrite -t_srs "$srs" -te $XMIN $YMIN $XMAX $YMAX -ts $NX $NY -r cubicspline \
    "$al/aligned-DEM.tif" "$al/aligned_oncoarse.tif" > "$out/align_warp.txt" 2>&1
  [ -s "$al/aligned-IntersectionErr.tif" ] && gdalwarp -overwrite -t_srs "$srs" -te $XMIN $YMIN $XMAX $YMAX \
    -ts $NX $NY -r cubicspline "$al/aligned-IntersectionErr.tif" "$al/aligned_oncoarse_err.tif" \
    > "$out/align_warp_err.txt" 2>&1
  echo "ALIGNED DEM (native): $al/aligned-DEM.tif ; on coarse grid: $al/aligned_oncoarse.tif"
  ls -la "$al/aligned-DEM.tif" "$al/aligned_oncoarse.tif" 2>/dev/null
  # ALIGNMENT GUARDRAIL (non-blocking): window the ALIGNED linescan to the SAME grid as the windowed CTX
  # (cwin), hillshade both, then (a) write a red/green RGB overlay for the eye (R=CTX, G=aligned; yellow =
  # registered - the real judge) and (b) correlate them for a robust-median residual dh/dv as a coarse
  # automated catch, so a bad align can never be silent (it hides in dz, which is horizontal-blind).
  # The two hillshades MUST be the same size or the correlator errors; hence the window-to-cwin-grid step.
  # set +e so a guard sub-command (correlate/hillshade) can never abort an otherwise-good align.
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
  echo "  RED/GREEN OVERLAY (the align judge): $al/align_overlay.tif (R=CTX G=aligned, yellow=registered)"
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
  echo "  ALIGN CHECK: post-align residual dh/dv median = ${GDH:-?} / ${GDV:-?} px (good is |median| < ~10)"
  awk -v h="${GDH:-999}" -v v="${GDV:-999}" 'BEGIN{h=(h<0?-h:h); v=(v<0?-v:v); exit (h>10||v>10)?1:0}' \
    || echo "  *** WARNING: linescan->CTX ALIGNMENT LIKELY FAILED (residual dh/dv median > 10 px). The CTX ref may be OVERSIZED for this site (it must be windowed to the linescan footprint) or the terrain too low-texture. Inspect $al/align_overlay.tif (R=CTX, G=aligned) by eye. ***"
else
  echo "NO transform - hillshade-init failed (fallback: dense-disparity align, pc_align RST)"
fi
echo "DONE $(date) [$site]"
