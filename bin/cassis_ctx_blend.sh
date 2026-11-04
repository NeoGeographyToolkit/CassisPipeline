#!/bin/bash
# cassis_ctx_blend.sh <ctxDir> <tag> <clat> <clon> - build the CTX reference DEM from downloaded DTMs.
#
# All CTX-reference work is two steps: FETCH then PROCESS. cassis_ctx_fetch.sh runs on the HEAD NODE (it
# needs net access) to compute the box and download the DTMs. This script is the PROCESS step and belongs
# on a COMPUTE NODE (qsub): it is heavy GDAL / dem_mosaic work. It warps each downloaded DTM to the grid,
# crops to the box, removes outliers, feather-blends, and makes the blur5 mapproj DEM. Warps are cached as
# dl/*_gw.tif, so re-running to try a different blend costs minutes (the warps are reused).
#
# Inputs expected under <ctxDir> (produced by cassis_ctx_fetch.sh):
#   dl/*_dem.tif   each controlled-CTX DTM as downloaded (warped here to the 18 m grid, cached as _gw.tif).
#   box_te.txt     one line "xmin ymin xmax ymax" (projected meters) = the 3x-footprint crop box.
# Output:
#   <ctxDir>/<tag>_ctx_18m.tif           the reference DEM (seamless, consensus elevations, cropped to box)
#   <ctxDir>/<tag>_ctx_18m_hillshade.tif multidirectional hillshade
#   <ctxDir>/<tag>_ctx_18m_blur5.tif     the blurred mapprojDem (regenerated from the reference)
#
# Method (per the cassis-pipeline skill's canonical recipe):
#   1. downsample each 18 m warp to sub-8 (144 m)
#   2. dem_mosaic --median the sub-8 tiles -> a consensus surface
#   3. geodiff each sub-8 tile vs the consensus; REMOVE a DTM if |mean| > 30 m OR stddev > 40 m (outlier).
#      All-removed fallback: keep every warp.
#   4. dem_mosaic (DEFAULT = feathered weighted average, NOT --median) the SURVIVORS' full-res warps once.
#      Median rejects outlier values but leaves hard tile SEAMS; feathering the already-removed survivors is
#      seamless AND keeps the consensus elevations. Crop to the box.
#   5. hillshade + regenerate the blur5 mapprojDem from the new reference.
#
# ASP tools (dem_mosaic, geodiff, gdalwarp, gdaldem, gdalinfo) must be on PATH, and PROJ/GDAL data set, as
# for the other pipeline scripts. The caller sets up the environment; this script hardcodes no paths.
set -e; umask 022; ulimit -c 0
ctxDir=${1:?ctxDir (holds dl/*_gw.tif and box_te.txt)}
tag=${2:?tag (output basename, e.g. the site id)}
clat=${3:?clat (site center latitude, for warping any missing tiles)}
clon=${4:?clon (site center longitude)}
threads=${CTX_THREADS:-20}

[ -s "$ctxDir/box_te.txt" ] || { echo "ERROR missing $ctxDir/box_te.txt"; exit 1; }
read TE0 TE1 TE2 TE3 < "$ctxDir/box_te.txt"
echo "[ctx_blend] box -te $TE0 $TE1 $TE2 $TE3  threads=$threads"

PROJ="+proj=stere +lat_0=$clat +lon_0=$clon +k=1 +x_0=0 +y_0=0 +R=3396190 +units=m +no_defs"

# Warp any raw DTM still missing its 18 m _gw.tif (cached ones are reused).
for raw in "$ctxDir"/dl/*_dem.tif; do
  [ -s "$raw" ] || continue
  c="$ctxDir/dl/$(basename "$raw" .tif)_gw.tif"
  if [ ! -s "$c" ]; then
    gdalwarp -q -overwrite -t_srs "$PROJ" -tr 18 18 -tap -r cubicspline "$raw" "$c" >/dev/null 2>&1 &
    while [ "$(jobs -r | wc -l)" -ge "$threads" ]; do wait -n 2>/dev/null || break; done
  fi
done
wait

echo "[ctx_blend] downsampling warps to sub-8 (144 m)"
for c in "$ctxDir"/dl/*_gw.tif; do
  [ -s "$c" ] || continue
  s8="$ctxDir/dl/$(basename "$c" _gw.tif)_sub8.tif"
  if [ ! -s "$s8" ]; then
    gdalwarp -q -overwrite -tr 144 144 -r cubicspline "$c" "$s8" >/dev/null 2>&1 &
    while [ "$(jobs -r | wc -l)" -ge "$threads" ]; do wait -n 2>/dev/null || break; done
  fi
done
wait

sub8_tiles=$(ls "$ctxDir"/dl/*_sub8.tif 2>/dev/null)
n_tiles=$(echo $sub8_tiles | wc -w)
echo "[ctx_blend] $n_tiles sub-8 tiles"
[ "$n_tiles" -gt 0 ] || { echo "ERROR no sub-8 tiles to blend"; exit 1; }

echo "[ctx_blend] sub-8 median consensus"
rm -f "$ctxDir"/_sub8_median*.tif
dem_mosaic --threads "$threads" --median $sub8_tiles -o "$ctxDir/_sub8_median" >/dev/null 2>&1
med_tif=$(ls "$ctxDir"/_sub8_median*.tif 2>/dev/null | head -1)
[ -s "$med_tif" ] || { echo "ERROR failed to build sub-8 median"; exit 1; }

echo "[ctx_blend] remove outliers vs consensus (|mean|>30 m or stddev>40 m)"
surviving_gw=""; removed_count=0; keep_count=0
mkdir -p "$ctxDir/outlier_diff"
for s8 in "$ctxDir"/dl/*_sub8.tif; do
  base=$(basename "$s8" _sub8.tif)
  gw="$ctxDir/dl/${base}_gw.tif"
  [ -s "$gw" ] || continue
  diff_out="$ctxDir/outlier_diff/${base}"
  rm -f "${diff_out}"*
  # geodiff operates on the FIRST arg's domain: tile first, consensus last.
  geodiff --threads 1 "$s8" "$med_tif" -o "$diff_out" >/dev/null 2>&1 || true
  diff_tif="${diff_out}-diff.tif"
  keep=1
  if [ -s "$diff_tif" ]; then
    stats=$(gdalinfo -stats "$diff_tif" 2>/dev/null | grep -E "STATISTICS_MEAN=|STATISTICS_STDDEV=")
    mean=$(echo "$stats" | grep "STATISTICS_MEAN=" | cut -d= -f2)
    std=$(echo "$stats" | grep "STATISTICS_STDDEV=" | cut -d= -f2)
    if [ -n "$mean" ] && [ -n "$std" ]; then
      is_outlier=$(python3 -c "print(1 if (abs(float('$mean'))>30.0 or float('$std')>40.0) else 0)" 2>/dev/null || echo 0)
      if [ "$is_outlier" -eq 1 ]; then echo "  REMOVE $base: mean=$mean std=$std"; keep=0; removed_count=$((removed_count+1)); fi
    fi
  fi
  [ "$keep" -eq 1 ] && { surviving_gw="$surviving_gw $gw"; keep_count=$((keep_count+1)); }
done
echo "[ctx_blend] kept $keep_count, removed $removed_count"
if [ "$keep_count" -lt 1 ]; then
  echo "[ctx_blend] WARNING all tiles removed - falling back to all warps"
  surviving_gw=$(ls "$ctxDir"/dl/*_gw.tif 2>/dev/null)
fi

echo "[ctx_blend] full-res feathered blend of survivors"
rm -f "$ctxDir"/_blend*.tif
dem_mosaic --threads "$threads" $surviving_gw -o "$ctxDir/_blend" >/dev/null 2>&1
bl=$(ls "$ctxDir"/_blend*.tif 2>/dev/null | head -1)
[ -s "$bl" ] || { echo "ERROR dem_mosaic blend failed"; exit 1; }

echo "[ctx_blend] crop to box -> ${tag}_ctx_18m.tif"
gdalwarp -q -overwrite -te $TE0 $TE1 $TE2 $TE3 -tr 18 18 -r near -co COMPRESS=LZW "$bl" "$ctxDir/${tag}_ctx_18m.tif"
gdaldem hillshade -multidirectional -compute_edges "$ctxDir/${tag}_ctx_18m.tif" "$ctxDir/${tag}_ctx_18m_hillshade.tif" >/dev/null 2>&1

echo "[ctx_blend] regenerate blur5 mapprojDem"
rm -f "$ctxDir"/_cb18*.tif
dem_mosaic --threads "$threads" --dem-blur-sigma 5 "$ctxDir/${tag}_ctx_18m.tif" -o "$ctxDir/_cb18" >/dev/null 2>&1
bl5=$(ls "$ctxDir"/_cb18*.tif 2>/dev/null | head -1)
[ -s "$bl5" ] && mv "$bl5" "$ctxDir/${tag}_ctx_18m_blur5.tif"

echo "[ctx_blend] DONE -> $ctxDir/${tag}_ctx_18m.tif"
gdalinfo -stats "$ctxDir/${tag}_ctx_18m.tif" 2>/dev/null | grep -E "Size is|VALID_PERCENT"
