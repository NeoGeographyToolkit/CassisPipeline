#!/bin/bash
# cassis_ctx_bundle.sh - joint CTX + CaSSIS bundle adjustment used ONLY to produce the clean
# cross-sensor interest-point matches for the jitter solve (the camera solution is discarded). It
# mapprojects every input image (the two CTX cubs and the CaSSIS framelets) with its camera onto the
# blurred reference at the native CaSSIS resolution, so all inputs share one grid, then matches them.
# The camera solve is given enough iterations to CONVERGE (100) - too few and the cross-sensor ties
# never tighten and are discarded as outliers. Because the images are mapprojected, --ip-match-radius
# keeps the search local on the shared grid and kills long-range junk matches (recommended for every
# mapprojected bundle and stereo run in this pipeline). See
# https://stereopipeline.readthedocs.io/en/latest/examples/cassis.html#cassis-jitter
#
# Args (currDir LAST; paths relative to it):
#   imageList     one image (cub) per line, CaSSIS framelets then the two CTX cubs
#   cameraList    matching CSM camera (json) per line, same order (aligned CTX + CaSSIS)
#   drape         blurred low-res reference DEM to mapproject onto
#   refDem        sharp reference DEM (for --heights-from-dem, --auto-overlap-params)
#   ipDetect      --ip-detect-method. Use 0 (OBALoG) for this CROSS-SENSOR CTX<->CaSSIS bundle. Its
#                 coarse gradient descriptor is robust to the CTX-vs-CaSSIS radiometric/resolution
#                 difference, so its matches are few but reliable. The richer SIFT (1) and AKAZE (3)
#                 descriptors overfit sensor-specific texture and yield many FALSE cross-sensor matches
#                 (nearly all discarded by the geometric filter). The same coarseness makes 0 fail on
#                 SAME-LOOK CaSSIS framelet pairs (self-similar terrain, ambiguous matches) - those are
#                 matched separately with dense correlation or a separate AKAZE (3) pass, not here.
#   outPrefix     bundle output prefix (clean matches are <outPrefix>-*-clean.match)
#   currDir       work dir, LAST
set +e; umask 022
if [ "$#" -ne 7 ]; then
    echo "Usage: $0 imageList cameraList drape refDem ipDetect outPrefix currDir"; exit 1
fi
imageList=${1:?imageList}; cameraList=${2:?cameraList}; drape=${3:?drape}; refDem=${4:?refDem}
ipDetect=${5:?ipDetect (0|1)}; outPrefix=${6:?outPrefix}; currDir=${7:?currDir}
# ASP/ISIS tools on PATH and the environment are set up by the caller. See the README.
cd "$currDir" || { echo "ERROR cannot cd $currDir"; exit 1; }
for f in "$imageList" "$cameraList" "$drape" "$refDem"; do [ -s "$f" ] || { echo "ERROR missing $f"; exit 1; }; done
nI=$(wc -l < "$imageList"); nC=$(wc -l < "$cameraList")
[ "$nI" = "$nC" ] || { echo "ERROR image/camera count $nI != $nC"; exit 1; }
outDir=$(dirname "$outPrefix"); mkdir -p "$outDir" "$outDir/maps"
echo "=== [cassis_ctx_bundle] START $(date) images=$nI ipDetect=$ipDetect ==="
[ -z "$PBS_NODEFILE" ] && { PBS_NODEFILE=$currDir/$(uname -n).nodes.txt; uname -n > "$PBS_NODEFILE"; }

# Mapproject every image with its camera at 4.59 m (native CaSSIS; CTX ~6 m is comparable) onto the
# drape, building a 1-1 mapprojected-data list in the SAME order as the image and camera lists.
mapList=$outDir/mapproj.txt; : > "$mapList"
paste "$imageList" "$cameraList" | while IFS=$'\t' read -r img cam; do
  m=$outDir/maps/$(basename "${img%.*}").4.59m.map.tif
  mapproject --tr 4.59 "$drape" "$img" "$cam" "$m" >/dev/null 2>&1 || { echo "STAGE_FAIL mapproject $img"; exit 1; }
  echo "$m" >> "$mapList"
done
[ "$(wc -l < "$mapList")" = "$nI" ] || { echo "ERROR mapproj list count != image list"; exit 1; }

parallel_bundle_adjust                    \
  --image-list "$imageList"               \
  --camera-list "$cameraList"             \
  --mapprojected-data-list "$mapList"     \
  --auto-overlap-params "$refDem 10"      \
  --heights-from-dem "$refDem"            \
  --heights-from-dem-uncertainty 10       \
  --camera-position-uncertainty 100,100   \
  --ip-detect-method "$ipDetect"          \
  --individually-normalize                \
  --ip-per-tile 2000                      \
  --matches-per-tile 500                  \
  --ip-match-radius 20                    \
  --remove-outliers-params '75 3 100 100' \
  --max-pairwise-matches 20000            \
  --min-triangulation-angle 1e-10         \
  --forced-triangulation-distance 392000  \
  --robust-threshold 0.5                  \
  --num-passes 2                          \
  --num-iterations 100                    \
  --datum D_MARS                          \
  --nodes-list "$PBS_NODEFILE"            \
  --processes 2                           \
  --threads 4                             \
  -o "$outPrefix"                         \
  || { echo "STAGE_FAIL parallel_bundle_adjust"; exit 1; }
echo "  clean matches: $(ls "$outPrefix"-*-clean.match 2>/dev/null | wc -l)"
echo "=== [cassis_ctx_bundle] DONE $(date) -> $outPrefix ==="
