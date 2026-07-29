#!/bin/bash
# cassis_ctx_align.sh - align a rough single-pair CTX DEM (and its cameras) to the reference CTX DEM
# before the joint jitter solve. A single alignment step fails on this low-texture terrain, so both
# DEMs are first coarsened 4x with gdalwarp -r average (which removes the correlator corrugation and
# leaves the large craters), then a single pc_align finds a rigid hillshade transform and, because
# the iteration count is nonzero, refines it with point-to-plane ICP in the same run (this recovers
# the rotation). The rigid transform is grid-independent, so it applies directly to the native-
# resolution cameras. Getting the rotation right is essential: a residual rotation propagates through
# the jitter solve. Check the result by eye before proceeding. See
# https://stereopipeline.readthedocs.io/en/latest/examples/cassis.html#cassis-jitter
#
# Args (currDir LAST; paths relative to it):
#   ctxDem   the rough single-pair CTX DEM (from cassis_ctx_stereo.sh on the bundle-adjusted cams)
#   refDem   the reference CTX DEM to align to
#   leftCub rightCub   the two CTX cubs
#   leftCam rightCam   the two CTX cameras to which the transform is applied
#   outDir   output dir (coarse DEMs, transform, aligned cameras)
#   currDir  work dir, LAST
set +e; umask 022
if [ "$#" -ne 8 ]; then
    echo "Usage: $0 ctxDem refDem leftCub rightCub leftCam rightCam outDir currDir"; exit 1
fi
ctxDem=${1:?ctxDem}; refDem=${2:?refDem}; leftCub=${3:?leftCub}; rightCub=${4:?rightCub}
leftCam=${5:?leftCam}; rightCam=${6:?rightCam}; outDir=${7:?outDir}; currDir=${8:?currDir}
# ASP/ISIS tools on PATH and the environment are set up by the caller. See the README.
cd "$currDir" || { echo "ERROR cannot cd $currDir"; exit 1; }
for f in "$ctxDem" "$refDem" "$leftCub" "$rightCub" "$leftCam" "$rightCam"; do
  [ -s "$f" ] || { echo "ERROR missing $f"; exit 1; }
done
mkdir -p "$outDir"
echo "=== [cassis_ctx_align] START $(date) outDir=$outDir ==="
# Coarsen both DEMs 4x (18 -> 72 m) with -r average.
gdalwarp -q -overwrite -r average -tr 72 72 "$ctxDem" "$outDir/ctx_72.tif" || { echo "STAGE_FAIL coarsen ctx"; exit 1; }
gdalwarp -q -overwrite -r average -tr 72 72 "$refDem" "$outDir/ref_72.tif" || { echo "STAGE_FAIL coarsen ref"; exit 1; }
# One pc_align: hillshade interest-point transform, then point-to-plane ICP (nonzero iterations).
pc_align                                          \
  --initial-transform-from-hillshading rigid      \
  --max-displacement 300                          \
  --num-iterations 2000                           \
  --save-transformed-source-points                \
  "$outDir/ref_72.tif" "$outDir/ctx_72.tif"       \
  -o "$outDir/run"                                \
  || { echo "STAGE_FAIL pc_align"; exit 1; }
[ -s "$outDir/run-transform.txt" ] || { echo "STAGE_FAIL no transform"; exit 1; }
# Apply the rigid transform to the native-resolution cameras.
bundle_adjust "$leftCub" "$rightCub" "$leftCam" "$rightCam" \
  --initial-transform "$outDir/run-transform.txt"          \
  --apply-initial-transform-only                           \
  -o "$outDir/aligned/run"                                 \
  || { echo "STAGE_FAIL apply transform"; exit 1; }
echo "  aligned cameras -> $outDir/aligned/run-*.adjusted_state.json"
echo "  INSPECT: grid the transformed source cloud (point2dem $outDir/run-trans_source.tif) and"
echo "  confirm it sits on the reference before proceeding."
echo "=== [cassis_ctx_align] DONE $(date) ==="
