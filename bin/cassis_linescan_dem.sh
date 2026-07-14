#!/bin/bash
# cassis_linescan_dem.sh - PHASE 0: linescan DEM + sparse align to the COARSE CTX.
# One script, 3 sites (3 param sets). From the vendor framelets: assemble a continuous
# LINESCAN strip per look, tie L+R with bundle_adjust (inline), stereo, point2dem, then
# a SPARSE pc_align (hillshade initial transform, rigid, max-disp -1, num-iter 0) to the
# coarse CTX, and regrid the aligned DEM onto the coarse grid.
#
# ALL COARSE: the coarse CTX is the ONLY geometry source - its proj, grid size, tr and
# extent drive every output (seed, point2dem, align ref, regrid target). NOTHING about
# grid/proj is hardcoded; grid + proj always agree because they come from one file.
#
# Machine-aware: runs on the Mac (raw data + asp_deps) or pfe (packaged release, PBS).
# On pfe the strips must already exist (no raw framelets there); Jezero strips are made
# once on the Mac (S1-S2) and rsynced. Plan + rationale: cassis_reprocess.sh PHASE 0.
#
# Usage: cassis_linescan_dem.sh <oxia1|oxia2|jezero>
set -e

# --- machine-aware environment ---
if [ -d /home6/oalexan1 ]; then            # pfe
  umask 022
  B=/home6/oalexan1/projects/cassis_asp
  ASP=$HOME/projects/BinaryBuilder/StereoPipeline
  export PATH=$ASP/bin:$PATH
  export PROJ_LIB=$ASP/share/proj PROJ_DATA=$ASP/share/proj
  export ISISROOT=$ASP
  ONPFE=1
else                                        # Mac or l1 (portable conda: anaconda3 / miniconda3)
  CONDA=$HOME/anaconda3; [ -x "$HOME/miniconda3/bin/conda" ] && CONDA=$HOME/miniconda3
  eval "$("$CONDA/bin/conda" shell.bash hook)"; conda activate asp_deps
  B=$HOME/projects/cassis_asp
  export ISISROOT=$CONDA/envs/asp_deps ISISDATA=$HOME/projects/isis3data
  export ALESPICEROOT=$HOME/projects/isis3data
  export PATH=$HOME/projects/StereoPipeline/install/bin:$CONDA/envs/asp_deps/bin:$ISISROOT/bin:$PATH
  ONPFE=0
fi
cd "$B"

# --- per-site params (the ONLY hardcoded site facts: data, sids, workdir, coarse ctx) ---
# TODO(oalexan1): make ALL of these params (dataDir, sidL, sidR, work, coarse) explicit INPUT
#   ARGS (or a per-site config file passed in), so a NEW site does NOT require editing this
#   script's case block. Adding a site should be a command-line invocation, never a code edit.
#   Same applies to every other per-site-cased script in this pipeline (run_ls_ba.sh,
#   align_ls_to_ctx.sh, refit_transverse.sh, cassis_ba_stage2.sh, frame_*.sh, etc.).
site=$1
# GENERIC new-site path (Oleg TODO above): if all 5 params are passed as env vars, use them and SKIP
# the case block - adding a site becomes an invocation, not a code edit. Existing cases untouched.
if [ -n "$DATADIR" ] && [ -n "$SIDL" ] && [ -n "$SIDR" ] && [ -n "$WORK" ] && [ -n "$COARSE" ]; then
  dataDir=$DATADIR; sidL=$SIDL; sidR=$SIDR; work=$WORK; coarse=$COARSE
else
case "$site" in
  oxia1)  dataDir=data/oxia_planum/MY34_003806_019; sidL=276230221; sidR=276230222
          work=oxia_planum/MY34_003806_019/ls; coarse=ref/oxia_planum_ctx/blend/oxia_ctx_expanded_18m.tif ;;
  oxia2)  dataDir=data/oxia_planum/MY34_004172_162; sidL=276980361; sidR=276980362
          work=oxia_planum/MY34_004172_162/ls; coarse=ref/oxia_planum_ctx/blend/oxia_ctx_expanded_18m.tif ;;
  jezero) dataDir=data/jezero/MY36_016378_162; sidL=838849161; sidR=838849162
          work=jezero/MY36_016378_162/ls; coarse=ref/jezero_ctx/jez_ctx_expanded_18m.tif ;;
# TODO(oalexan1): the gusev entry below reuses a data/jezero fetch root for historical reasons.
#   Rename to gusev/ + data/gusev/ later. These site paths are examples; override via env vars.
  gusev)  dataDir=data/jezero/MY34_003860_344_1; sidL=276342113; sidR=276342114
          work=jezero/MY34_003860_344_1/ls; coarse=ref/gusev_ctx/gusev_ctx_clean_18m.tif ;;
  *) echo "usage: cassis_linescan_dem.sh <oxia1|oxia2|jezero|gusev>  OR set DATADIR/SIDL/SIDR/WORK/COARSE env"; exit 2 ;;
esac
fi
[ -s "$coarse" ] || { echo "ERROR missing coarse ctx $coarse"; exit 1; }
mkdir -p "$work"
log=$B/output_linescan_${site}.txt
[ "$ONPFE" = 1 ] && exec > "$log" 2>&1
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

# Good-citizen process caps (Mac shared box; pfe uses the node fully).
if [ "$ONPFE" = 1 ]; then
  [ -f "$PBS_NODEFILE" ] || { PBS_NODEFILE=$(uname -n).txt; uname -n > "$PBS_NODEFILE"; }
  MAPCAP="--threads 16"
  PSCAP="--nodes-list $PBS_NODEFILE --processes 8 --threads-multiprocess 4 --threads-singleprocess 16"
else
  MAPCAP="--processes 2 --threads 3"
  PSCAP="--processes 2 --threads-multiprocess 3 --threads-singleprocess 6"
fi

# --- S1-S2: strips + linescan ISDs (regen if missing; needs raw framelets present) ---
Ls=$work/${sidL}_strip.tif; Rs=$work/${sidR}_strip.tif
Lisd=$work/${sidL}_linescan.json; Risd=$work/${sidR}_linescan.json
if [ ! -s "$Ls" ] || [ ! -s "$Rs" ] || [ ! -s "$Lisd" ] || [ ! -s "$Risd" ]; then
  echo "=== S1 stack_strip_gen (strips, sub-pixel pitch) ==="
  [ -d "${dataDir}/L1_${sidL}" ] || { echo "ERROR no raw framelets ${dataDir}/L1_${sidL} (run S1-S2 on the Mac then rsync ls/)"; exit 1; }
  python3 stack_strip_gen.py "$dataDir" "$sidL" "$sidR" "$work" | tee "$work/strip_gen.txt"
  for sid in "$sidL" "$sidR"; do
    line=$(grep "^${sid}:" "$work/strip_gen.txt")
    rev=$(echo "$line" | grep -q REVERSE && echo 1 || echo 0)
    keep=$(echo "$line" | sed -n 's/.*KEEP=\([0-9]*\).*/\1/p')
    echo "=== S1b assemble_pushframe sid=$sid reverse=$rev keep=$keep ==="
    python3 assemble_pushframe_gen.py "$dataDir" "$sid" "$rev" "$keep" "$work/${sid}_pushframe.json"
    echo "=== S2 pushframe2linescan sid=$sid ==="
    python3 pushframe2linescan.py "$work/${sid}_pushframe.json" "$work/${sid}_linescan.json"
  done
fi
for f in "$Ls" "$Rs" "$Lisd" "$Risd"; do [ -s "$f" ] || { echo "ERROR missing $f"; exit 1; }; done

out=$work/ls_dem; mkdir -p "$out/ba" "$out/stereo" "$out/align"
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
