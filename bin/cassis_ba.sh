#!/bin/bash
# cassis_ba.sh - UNIVERSAL joint BA (the bundle step of one tic/toc stage). Distortion is FROZEN
# by default; it can OPTIONALLY be floated (distortion-only, shared across all framelets) via the intrFloat
# arg - the Jezero/Oxia jzexp1b recipe. FULLY PARAMETERIZED, NO hardcoded cameras or site:
# the INPUT image-list + camera-list are params (any stage's cams - the transplant cams, or a previous
# stage's run-image_list.txt/run-camera_list.txt), plus refdem, dense matches, htUnc, camPosUnc, robust, an
# OPTIONAL gcp (+ fix-gcp-xyz), and the intrFloat flag. OUTPUT = the experiment dir <pairDir>/frame/<outTag>.
# tic = with gcp + fix-gcp-xyz + loose htUnc (horizontal). toc = no gcp + tight htUnc (vertical).
# Recipe constants (numIter 50, passes 2, forcedTri) from cassis_ba_stage2.sh; robust + intrFloat are now
# ARGS (no hardcode).
# Args (B LAST): <pairDir> <outTag> <imgList> <camList> <refdem> <matchpfx> <htUnc> <camPosUnc>
#   <gcpFile|no_gcp> <fixgcp:yes|no> <robust> <intrFloat:yes_intr_float|no_intr_float> <B>
#   (no_gcp = the honest sentinel for "no ground control"; intrFloat = float distortion-only or keep frozen)
set +e; umask 022
pairDir=${1:?pairDir}; outTag=${2:?outTag}; imgList=${3:?imgList}; camList=${4:?camList}
refdem=${5:?refdem}; matchpfx=${6:?matchpfx}; htUnc=${7:?htUnc}; camPosUnc=${8:?camPosUnc}
gcp=${9:?gcp (.gcp path, or "no_gcp")}; fixgcp=${10:?fixgcp (yes|no)}; robust=${11:?robust}
intrFloat=${12:?intrFloat (yes_intr_float|no_intr_float)}; B=${13:?B (cd target, LAST)}
if [ -x "$HOME/projects/BinaryBuilder/StereoPipeline/bin/bundle_adjust" ]; then
  export PATH=$HOME/projects/BinaryBuilder/StereoPipeline/bin:$PATH
  ASP=$HOME/projects/BinaryBuilder/StereoPipeline; export ISISROOT=$ASP PROJ_DATA=$ASP/share/proj
else
  eval "$($HOME/anaconda3/bin/conda shell.bash hook)"; conda activate asp_deps
  export ISISROOT=$HOME/anaconda3/envs/asp_deps
  export PATH=$HOME/projects/StereoPipeline/install/bin:$ISISROOT/bin:$PATH
fi
cd "$B" || { echo "ERROR cannot cd $B"; exit 1; }
out=$pairDir/frame/$outTag; mkdir -p "$out"
log=$B/output_${outTag}.txt; exec > "$log" 2>&1
echo "=== [cassis_ba] START $(date) host=$(uname -n) outTag=$outTag ==="

# INPUT lists are PARAMS (no hardcoded cameras/site). Validate: exist + 1-1 by count.
for f in "$imgList" "$camList" "$refdem"; do [ -s "$f" ] || { echo "ERROR missing $f"; exit 1; }; done
nI=$(wc -l < "$imgList"); nC=$(wc -l < "$camList")
echo "imgList=$imgList ($nI)  camList=$camList ($nC)  refdem=$refdem  htUnc=$htUnc  camPosUnc=$camPosUnc"
[ "$nI" = "$nC" ] && [ "$nI" -ge 2 ] || { echo "ERROR image/camera count $nI != $nC or too few"; exit 1; }

# GCP is optional: if a path is given (not "no_gcp"), add it as a positional GCP + a reproj blunder guard.
# gcp-sigma is baked into the .gcp file (cols 5-7). fixgcp=yes adds --fix-gcp-xyz (hold GCP xyz FIXED).
gcpPos=""; gcpOpt=""
if [ "$gcp" != no_gcp ]; then
  [ -s "$gcp" ] || { echo "ERROR missing gcp $gcp"; exit 1; }
  gcpPos="$gcp"; gcpOpt="--max-gcp-reproj-err 100"
  [ "$fixgcp" = yes ] && gcpOpt="$gcpOpt --fix-gcp-xyz"
  echo "GCP: $gcp ($(grep -vc '^#' "$gcp") points) fix-gcp-xyz=$fixgcp"
fi

# Intrinsics: FROZEN by default; yes_intr_float floats distortion ONLY, shared across all framelets
# (the Jezero/Oxia jzexp1b recipe). Focal/optical stay fixed. no_intr_float = no --solve-intrinsics.
intrOpt=""
if [ "$intrFloat" = yes_intr_float ]; then
  intrOpt="--solve-intrinsics --intrinsics-to-share all --intrinsics-to-float distortion"
  echo "INTRINSICS: floating distortion-only (shared)"
elif [ "$intrFloat" != no_intr_float ]; then
  echo "ERROR bad intrFloat=$intrFloat (want yes_intr_float|no_intr_float)"; exit 1
else
  echo "INTRINSICS: frozen"
fi
echo "robust-threshold=$robust"

# Joint BA: htdem pin to CTX, poses on a leash, distortion frozen or floated per intrFloat.
bundle_adjust \
  --image-list "$imgList" \
  --camera-list "$camList" \
  $gcpPos \
  --inline-adjustments \
  --match-files-prefix "$matchpfx" \
  --heights-from-dem "$refdem" \
  --heights-from-dem-uncertainty "$htUnc" \
  --heights-from-dem-robust-threshold 0.1 \
  --camera-position-uncertainty "$camPosUnc" \
  $gcpOpt \
  $intrOpt \
  --robust-threshold "$robust" \
  --num-iterations 50 \
  --num-passes 2 \
  --remove-outliers-params "75 3 100 100" \
  --min-triangulation-angle 1e-10 \
  --forced-triangulation-distance 392000 \
  --max-pairwise-matches 2000 \
  -o "$out/run" \
  || { echo "BA FAILED - tail:"; tail -25 "$out"/*log*bundle_adjust*.txt 2>/dev/null; exit 1; }
echo "=== BA done. output cams: $(ls "$out"/run-*.adjusted_state.json 2>/dev/null | wc -l) ($(date)) ==="
echo "CASSIS_BA_DONE $(date)"
