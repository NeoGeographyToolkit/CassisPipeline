#!/bin/bash
# cassis_ctx_stereo.sh - stereo of one CTX pair with GIVEN cameras (e.g. the jitter-refined ones),
# producing a CTX DEM. Mapprojects both CTX images onto the blurred reference at the native CTX
# resolution, then runs mapprojected stereo (alignment none) and point2dem. Used to remake the CTX
# DEM after cassis_ctx_jitter.sh. See
# https://stereopipeline.readthedocs.io/en/latest/examples/cassis.html#cassis-jitter
#
# Args (currDir LAST; paths relative to it):
#   leftCub rightCub   the two CTX cubs
#   leftCam rightCam   the two CTX CSM cameras (json), matching the cubs
#   drape              blurred low-res reference DEM to mapproject onto
#   refDem             sharp reference DEM (sets projection for point2dem)
#   outDir             output dir (mapproj + stereo + DEM go here)
#   currDir            work dir, LAST
set +e; umask 022
if [ "$#" -ne 8 ]; then
    echo "Usage: $0 leftCub rightCub leftCam rightCam drape refDem outDir currDir"; exit 1
fi
leftCub=${1:?leftCub}; rightCub=${2:?rightCub}; leftCam=${3:?leftCam}; rightCam=${4:?rightCam}
drape=${5:?drape}; refDem=${6:?refDem}; outDir=${7:?outDir}; currDir=${8:?currDir}
# ASP/ISIS tools on PATH and the environment are set up by the caller. See the README.
cd "$currDir" || { echo "ERROR cannot cd $currDir"; exit 1; }
for f in "$leftCub" "$rightCub" "$leftCam" "$rightCam" "$drape" "$refDem"; do
  [ -s "$f" ] || { echo "ERROR missing $f"; exit 1; }
done
srs=$(gdalsrsinfo -o proj4 "$refDem" 2>/dev/null | tr -d '\n')
[ -n "$srs" ] || { echo "ERROR no PROJ from refDem"; exit 1; }
mkdir -p "$outDir"
lmap=$outDir/$(basename "${leftCub%.*}").map.tif
rmap=$outDir/$(basename "${rightCub%.*}").map.tif
echo "=== [cassis_ctx_stereo] START $(date) outDir=$outDir ==="
# Mapproject at 6 m (native CTX GSD) onto the drape. Correlation is at that resolution; only the
# output DEM is at the coarse 18 m grid.
mapproject --tr 6 --processes 2 --threads 2 "$drape" "$leftCub"  "$leftCam"  "$lmap" >/dev/null 2>&1 || { echo "STAGE_FAIL mapproject L"; exit 1; }
mapproject --tr 6 --processes 2 --threads 2 "$drape" "$rightCub" "$rightCam" "$rmap" >/dev/null 2>&1 || { echo "STAGE_FAIL mapproject R"; exit 1; }
parallel_stereo                       \
  --alignment-method none             \
  --stereo-algorithm asp_mgm          \
  --processes 2                       \
  --threads-multiprocess 4            \
  "$lmap" "$rmap" "$leftCam" "$rightCam" \
  "$outDir/run" "$drape"              \
  || { echo "STAGE_FAIL parallel_stereo"; exit 1; }
point2dem --errorimage --tr 18 --t_srs "$srs" "$outDir/run-PC.tif" -o "$outDir/ctx" \
  || { echo "STAGE_FAIL point2dem"; exit 1; }
echo "=== [cassis_ctx_stereo] DONE $(date) -> $outDir/ctx-DEM.tif ==="
