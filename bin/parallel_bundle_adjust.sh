#!/bin/bash
# parallel_bundle_adjust.sh - CaSSIS joint bundle adjustment of the framelet frame
# cameras, matched in the mapprojected domain and height-constrained to the CTX
# reference DEM. Specific to the CaSSIS pipeline (Mars, D_MARS).
#
# Matching runs on the mapprojected framelets (--mapprojected-data-list). Which
# image pairs overlap is found from their ground footprints on the CTX DEM
# (--auto-overlap-params), so same-look and cross-look (L-R) pairs are handled
# uniformly by ground overlap, with no look-ordering special case. The trailing
# DEM on the mapproj list is NOT needed: it is read from the mapprojected
# geoheaders (ASP build 1/2026 or later). The triangulated points are pulled to
# the CTX DEM with --heights-from-dem.
#
# ASP tools must be on PATH and the environment set up by the caller (see the
# README). Run under qsub on a compute node, or locally.
#
# Usage:
#   parallel_bundle_adjust.sh <imageList> <cameraList> <mapprojList> <dem> <outPrefix> <workDir>
#     imageList   one framelet image (cub) per line
#     cameraList  matching CSM camera (json) per line, SAME order as imageList
#     mapprojList matching mapprojected framelet (tif) per line, SAME order
#     dem         the CTX reference DEM (latest/best), for auto-overlap + heights
#     outPrefix   bundle_adjust output prefix (under workDir or absolute)
#     workDir     work directory, LAST (the script cd-s into it)
set +e; umask 022
imageList=${1:?imageList (framelet cubs, one per line)}
cameraList=${2:?cameraList (CSM json, same order as imageList)}
mapprojList=${3:?mapprojList (mapprojected framelets, same order)}
dem=${4:?dem (CTX reference DEM for auto-overlap + heights-from-dem)}
outPrefix=${5:?outPrefix (bundle_adjust output prefix)}
B=${6:?workDir (cd target, LAST)}
cd "$B" || { echo "ERROR cannot cd $B"; exit 1; }

# Inputs must exist.
for f in "$imageList" "$cameraList" "$mapprojList" "$dem"; do
  [ -s "$f" ] || { echo "ERROR input not found: $f"; exit 1; }
done
# The three lists must be one-to-one: same length, same order.
nI=$(grep -c . "$imageList"); nC=$(grep -c . "$cameraList"); nM=$(grep -c . "$mapprojList")
{ [ "$nI" = "$nC" ] && [ "$nI" = "$nM" ]; } || { echo "ERROR list lengths differ: image=$nI camera=$nC mapproj=$nM"; exit 1; }

# parallel_bundle_adjust needs a --nodes-list. Under PBS this is provided; when
# run locally, make a one-line file naming this host.
if [ -z "$PBS_NODEFILE" ]; then
  PBS_NODEFILE=$B/$(uname -n).nodes.txt
  uname -n > "$PBS_NODEFILE"
fi

mkdir -p "$(dirname "$outPrefix")"
log=$B/output_parallel_ba_$(basename "$outPrefix").txt
exec > "$log" 2>&1
echo "START $(date) host=$(uname -n)"
echo "imageList=$imageList cameraList=$cameraList mapprojList=$mapprojList"
echo "dem=$dem outPrefix=$outPrefix workDir=$B images=$nI"

# One option per line, with its value on that same line.
parallel_bundle_adjust \
  --image-list "$imageList" \
  --camera-list "$cameraList" \
  --mapprojected-data-list "$mapprojList" \
  --auto-overlap-params "$dem 10" \
  --heights-from-dem "$dem" \
  --heights-from-dem-uncertainty 10 \
  --ip-per-tile 1000 \
  --matches-per-tile 300 \
  --max-pairwise-matches 20000 \
  --min-triangulation-angle 1e-10 \
  --forced-triangulation-distance 392000 \
  --robust-threshold 0.5 \
  --num-passes 2 \
  --num-iterations 50 \
  --remove-outliers-params "75 3 100 100" \
  --datum D_MARS \
  --nodes-list "$PBS_NODEFILE" \
  --processes 8 \
  --threads 4 \
  -o "$outPrefix"
rc=$?

echo "DONE $(date) rc=$rc"
exit $rc
