#!/bin/bash
# cassis_ctx_jitter.sh - joint CTX (linescan) + CaSSIS (frame) jitter solve, the pixel-level
# CTX<->CaSSIS refinement documented at
# https://stereopipeline.readthedocs.io/en/latest/examples/cassis.html#cassis-jitter
# Refines the CTX linescan pose samples and the CaSSIS frame poses together, tied by the clean
# matches from the joint bundle (cassis_ctx_bundle.sh) and constrained to the jitter-free CTX
# reference DEM with --heights-from-dem plus a dense, tight anchor grid. The anchor uncertainty is
# the key knob: too loose and the CTX poses over-fit the ties and the stereo DEM fragments; 25 m
# holds it. The input cameras are the already CTX-aligned ones (cassis_ctx_align.sh output for CTX,
# the pass cameras for CaSSIS). Mars. Single node, threaded.
#
# Args (currDir LAST; all other paths are relative to it):
#   imageList    one image (cub) per line, CaSSIS framelets then the two CTX cubs
#   cameraList   matching CSM camera (json) per line, same order (aligned CTX + CaSSIS)
#   matchPrefix  clean-match-files prefix from cassis_ctx_bundle.sh
#   refDem       CTX reference DEM, for --heights-from-dem and --anchor-dem
#   outPrefix    jitter_solve output prefix
#   currDir      work dir, LAST
set +e; umask 022
if [ "$#" -ne 6 ]; then
    echo "Usage: $0 imageList cameraList matchPrefix refDem outPrefix currDir"; exit 1
fi
imageList=${1:?imageList}; cameraList=${2:?cameraList}; matchPrefix=${3:?matchPrefix}
refDem=${4:?refDem}; outPrefix=${5:?outPrefix}; currDir=${6:?currDir}
# ASP/ISIS tools on PATH and the environment are set up by the caller. See the README.
cd "$currDir" || { echo "ERROR cannot cd $currDir"; exit 1; }
for f in "$imageList" "$cameraList" "$refDem"; do [ -s "$f" ] || { echo "ERROR missing $f"; exit 1; }; done
nI=$(wc -l < "$imageList"); nC=$(wc -l < "$cameraList")
[ "$nI" = "$nC" ] || { echo "ERROR image/camera count $nI != $nC"; exit 1; }
mkdir -p "$(dirname "$outPrefix")"
echo "=== [cassis_ctx_jitter] START $(date) images=$nI matchPrefix=$matchPrefix ==="
# The cross-sensor ties start with a large reprojection error (that misregistration is what is being
# solved), so --max-initial-reprojection-error keeps them. Anchor 50/tile at 25 m uncertainty is the
# recommended working set (see the doc); --num-lines-per-position/orientation are the CTX pose segment
# lengths. Cameras are NOT extra-constrained (--camera-position-uncertainty is generous).
jitter_solve                                \
  --image-list "$imageList"                 \
  --camera-list "$cameraList"               \
  --clean-match-files-prefix "$matchPrefix" \
  --heights-from-dem "$refDem"              \
  --heights-from-dem-uncertainty 10         \
  --anchor-dem "$refDem"                    \
  --anchor-dem-uncertainty 25               \
  --num-anchor-points-per-tile 50           \
  --camera-position-uncertainty 100,100     \
  --num-lines-per-position 1000             \
  --num-lines-per-orientation 250           \
  --max-pairwise-matches 20000              \
  --min-matches 1                           \
  --min-triangulation-angle 1e-10           \
  --forced-triangulation-distance 392000    \
  --max-initial-reprojection-error 500      \
  --robust-threshold 0.5                    \
  --num-passes 2                            \
  --num-iterations 50                       \
  --threads 8                               \
  -o "$outPrefix"                           \
  || { echo "STAGE_FAIL jitter_solve"; exit 1; }
echo "=== [cassis_ctx_jitter] DONE $(date) -> $outPrefix ==="
