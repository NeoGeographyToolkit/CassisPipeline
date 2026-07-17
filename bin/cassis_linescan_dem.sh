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
# Usage: cassis_linescan_dem.sh <label> <dataDir> <sidL> <sidR> <work> <coarseCTX>
set -e

# ASP/ISIS tools on PATH and environment (ISIS kernels) are set up by the caller.
# Run this from your work directory. See the repository README.
umask 022
B=$PWD
cd "$B"
# The helper python scripts live next to this script (the pipeline bin dir), not
# in the work dir, so invoke them by their own location, not CWD-relative.
BIN=$(cd "$(dirname "$0")" && pwd)

# --- site params: ALL from explicit args, nothing hardcoded ---
site=${1:?usage: cassis_linescan_dem.sh <label> <dataDir> <sidL> <sidR> <work> <coarseCTX>}
dataDir=${2:?dataDir (holds L1_<sidL>/ and L2_<sidR>/ framelet cubes)}
sidL=${3:?sidL}; sidR=${4:?sidR}
work=${5:?work (linescan output directory)}
coarse=${6:?coarseCTX (its proj/grid/extent drive every output)}
[ -s "$coarse" ] || { echo "ERROR missing coarse ctx $coarse"; exit 1; }
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
  [ -d "${dataDir}/L1_${sidL}" ] || { echo "ERROR no framelet cubes ${dataDir}/L1_${sidL}"; exit 1; }
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

# --- S5: sparse pc_align to coarse, DEM-to-DEM (hillshade init NEEDS both to be DEMs) ---
# Call 1: align the gridded stereo DEM to the coarse ctx DEM via hillshade (rigid, num-iter
# 0) to GET the transform. Hillshade-init REQUIRES both inputs be DEMs (ASP errors on a raw
# cloud). Call 2: APPLY that transform to the stereo PC (no hillshade, just --initial-
# transform) so the aligned DEM keeps the triangulation error band. point2dem at native;
# gdalwarp to the coarse EXTENT + coarse RES (18 m) -> aligned_oncoarse.tif.
echo "=== S5 pc_align hillshade-init coarse <- stereo DEM (transform), apply to PC ==="
al=$out/align
pc_align --max-displacement -1 --initial-transform-from-hillshading rigid --num-iterations 0 \
  "$coarse" "$dem" -o "$al/run" > "$out/align_log.txt" 2>&1 \
  || { echo "ALIGN FAILED (recorded)"; tail -25 "$out/align_log.txt"; }
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
else
  echo "NO transform - hillshade-init failed (fallback: dense-disparity align, pc_align RST)"
fi
echo "DONE $(date) [$site]"
