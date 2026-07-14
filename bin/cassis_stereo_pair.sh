#!/bin/bash
# cassis_stereo_pair.sh - ONE per-pair stereo unit, invoked by GNU parallel from the cassis_stereo.sh
# driver. Sources an env file (the fixed params the driver wrote) and does one pair in one of 3 modes:
#   dem  = mapprojected stereo (geounc=0) + point2dem  (DEM mode; pairs come from existing match files)
#   lr   = mapprojected stereo (geounc collar) + --num-matches-from-disparity + copy match  (dense L-R)
#   same = raw affineepipolar stereo + --num-matches-from-disparity + copy match  (dense same-look L-L/R-R)
# Args: <mode> <a> <b> <envfile>. The env file sets: out geounc drape nmd PROJ demRes matchPrefix
#   imgList camList T. This worker sets its own ASP env and caps per-worker threads so a pool of them
#   does not oversubscribe the node.
set +e
mode=${1:?mode (dem|lr|same)}; a=${2:?a}; b=${3:?b}; envf=${4:?envfile}
[ -s "$envf" ] || { echo "  PAIR $a $b: no envfile $envf"; exit 0; }
# ASP/ISIS tools on PATH and environment are inherited from the caller (GNU
# parallel carries the environment to each worker). See the README.
source "$envf"
T=${T:-2}
# cap math-library threads per worker (imitate parallel_stereo's MKL guard) so K workers x T threads
# do not oversubscribe; parallel_stereo itself gets T via its own flags below.
export OMP_NUM_THREADS=$T MKL_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 VECLIB_MAXIMUM_THREADS=1

# resolve the BA/refit camera + image (cub) for a stem from the 1-1 lists
idx_of(){ awk -v n="$1" '{x=$0;sub(/.*\//,"",x);sub(/\.[^.]*$/,"",x); if(x==n){print NR;exit}}' "$imgList"; }
cam_of(){ local i=$(idx_of "$1"); [ -n "$i" ] && sed -n "${i}p" "$camList"; }
img_of(){ local i=$(idx_of "$1"); [ -n "$i" ] && sed -n "${i}p" "$imgList"; }

od=$out/stereo/${a}__${b}
ca=$(cam_of "$a"); cb=$(cam_of "$b")
mf=${matchPrefix}-${a}__${b}.match

case "$mode" in
  dem)
    if [ -s "$od/dem-DEM.tif" ] && gdalinfo -stats "$od/dem-DEM.tif" 2>/dev/null | grep -q STATISTICS_MINIMUM; then exit 0; fi
    [ -s "$out/maps/$a.tif" ] && [ -s "$out/maps/$b.tif" ] && [ -s "$ca" ] && [ -s "$cb" ] || { echo "  skip dem $a $b (no input)"; exit 0; }
    rm -rf "$od"; mkdir -p "$od"
    parallel_stereo --processes 1 --threads-multiprocess $T --threads-singleprocess $T \
      --alignment-method none --stereo-algorithm asp_mgm --subpixel-mode 9 --corr-seed-mode 1 \
      --min-matches 5 --ip-per-tile 2000 \
      --mapproj-geolocation-uncertainty $geounc \
      --ip-match-radius 20 \
      "$out/maps/$a.tif" "$out/maps/$b.tif" "$ca" "$cb" "$od/run" "$drape" > "$od.log" 2>&1 \
      || { echo "  STEREO FAIL $a $b"; exit 0; }
    point2dem --errorimage \
      --max-valid-triangulation-error 8 \
      --t_srs "$PROJ" \
      --tr $demRes \
      "$od/run-PC.tif" -o "$od/dem" >> "$od.log" 2>&1 || echo "  p2d FAIL $a $b"
    ;;
  lr)
    [ -s "$mf" ] && exit 0
    [ -s "$out/maps/$a.tif" ] && [ -s "$out/maps/$b.tif" ] && [ -s "$ca" ] && [ -s "$cb" ] || { echo "  skip lr $a $b (no ortho/cam)"; exit 0; }
    rm -rf "$od"; mkdir -p "$od"
    parallel_stereo --processes 1 --threads-multiprocess $T --threads-singleprocess $T \
      --alignment-method none --stereo-algorithm asp_mgm --subpixel-mode 9 --corr-seed-mode 1 \
      --mapproj-geolocation-uncertainty $geounc \
      --num-matches-from-disparity $nmd --max-disp-spread 120 \
      "$out/maps/$a.tif" "$out/maps/$b.tif" "$ca" "$cb" "$od/run" "$drape" > "$od.log" 2>&1 \
      || { echo "  LR FAIL $a $b"; exit 0; }
    m=$(ls $od/run-disp-*.match 2>/dev/null | head -1); [ -n "$m" ] && cp -f "$m" "$mf" || echo "  NO MATCH lr $a $b"
    ;;
  same)
    [ -s "$mf" ] && exit 0
    ia=$(img_of "$a"); ib=$(img_of "$b")
    [ -s "$ia" ] && [ -s "$ib" ] && [ -s "$ca" ] && [ -s "$cb" ] || { echo "  skip same $a $b (no input)"; exit 0; }
    rm -rf "$od"; mkdir -p "$od"
    parallel_stereo --processes 1 --threads-multiprocess $T --threads-singleprocess $T \
      --alignment-method affineepipolar --stereo-algorithm asp_mgm --subpixel-mode 9 --corr-seed-mode 1 \
      --ip-detect-method 1 --ip-per-image 12000 \
      --num-matches-from-disparity $nmd --min-triangulation-angle 1e-10 \
      "$ia" "$ib" "$ca" "$cb" "$od/run" > "$od.log" 2>&1 \
      || { echo "  SAME FAIL $a $b"; exit 0; }
    m=$(ls $od/run-disp-*.match 2>/dev/null | head -1); [ -n "$m" ] && cp -f "$m" "$mf" || echo "  NO MATCH same $a $b"
    ;;
  *) echo "  bad mode $mode"; exit 0 ;;
esac
