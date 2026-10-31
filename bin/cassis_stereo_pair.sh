#!/bin/bash
# cassis_stereo_pair.sh - one per-pair stereo unit, invoked by GNU parallel from the
# cassis_stereo.sh driver. Sources an env file (the fixed params the driver wrote) and
# does one pair in one of 3 modes:
#   dem  = mapprojected stereo (geounc=0) + point2dem (DEM mode; pairs from existing
#          match files)
#   lr   = mapprojected stereo (geounc collar) + --num-matches-from-disparity + copy
#          match (dense L-R)
#   same = raw affineepipolar stereo + --num-matches-from-disparity + copy match
#          (dense same-look L-L/R-R)
# Args: <mode> <a> <b> <envfile>. The env file sets: out geounc mapprojDem nmd PROJ
#   demRes matchPrefix imgList camList T. This worker sets its own ASP env and caps
#   per-worker threads so a pool of them does not oversubscribe the node.
set +e
mode=${1:?mode (dem|lr|same)}; a=${2:?a}; b=${3:?b}; envf=${4:?envfile}
[ -s "$envf" ] || { echo "  PAIR $a $b: no envfile $envf"; exit 0; }
# ASP/ISIS tools on PATH and environment are inherited from the caller (GNU
# parallel carries the environment to each worker). See the README.
source "$envf"
T=${T:-2}
# cap math-library threads per worker (imitate parallel_stereo's MKL guard) so K
# workers x T threads do not oversubscribe; parallel_stereo itself gets T via its own
# flags below.
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
      "$out/maps/$a.tif" "$out/maps/$b.tif" "$ca" "$cb" "$od/run" "$mapprojDem" > "$od.log" 2>&1 \
      || { echo "  STEREO FAIL $a $b"; exit 0; }
    point2dem --errorimage              \
      --max-valid-triangulation-error 8 \
      --t_srs "$PROJ"                   \
      --tr $demRes                      \
      "$od/run-PC.tif" -o "$od/dem" >> "$od.log" 2>&1 || echo "  p2d FAIL $a $b"
    ;;
  lr)
    [ -s "$mf" ] && exit 0
    [ -s "$out/maps/$a.tif" ] && [ -s "$out/maps/$b.tif" ] && [ -s "$ca" ] && [ -s "$cb" ] || { echo "  skip lr $a $b (no ortho/cam)"; exit 0; }
    # Dense cross-look match in the mapprojected domain. Try --corr-seed-mode 1 (the fast
    # pyramid seed) first. On thin-overlap pairs its low-resolution D_sub can come back empty
    # ("No tiles were generated"), producing no match. Fall back to --corr-seed-mode 0 (a
    # direct full search in the interest-point search window), which recovers those marginal
    # pairs. The seed mode is the only difference between the two attempts.
    lr_try() {  # $1 = corr-seed-mode; echoes the produced dense match file (empty if none)
      rm -rf "$od"; mkdir -p "$od"
      parallel_stereo --processes 1 --threads-multiprocess $T --threads-singleprocess $T \
        --alignment-method none --stereo-algorithm asp_mgm --subpixel-mode 9 --corr-seed-mode "$1" \
        --mapproj-geolocation-uncertainty $geounc \
        --num-matches-from-disparity $nmd --max-disp-spread 120 \
        "$out/maps/$a.tif" "$out/maps/$b.tif" "$ca" "$cb" "$od/run" "$mapprojDem" > "$od.log" 2>&1
      ls "$od"/run-disp-*.match 2>/dev/null | head -1
    }
    m=$(lr_try 1)
    if [ -z "$m" ]; then
      echo "  lr $a $b: --corr-seed-mode 1 produced no match (thin-overlap empty disparity); retrying with --corr-seed-mode 0"
      m=$(lr_try 0)
    fi
    [ -n "$m" ] && cp -f "$m" "$mf" || echo "  NO MATCH lr $a $b (--corr-seed-mode 1 and 0 both failed)"
    ;;
  same)
    # Same-look tie between consecutive framelets. PRIMARY = full-frame affineepipolar (the
    # proven path; it matches most textured pairs richly). It ABORTS on low-texture (crater)
    # pairs because it needs >=20 matched interest points to estimate the search range over a
    # ~220-line raw disparity and the bland overlap cannot supply them; for THOSE we FALL BACK
    # to the crop-window matcher below. (Crop-win is NOT used wholesale: it restricts the
    # correlator to a ~57-row overlap band, so at the ~0.16-deg same-look convergence the
    # num-matches-from-disparity triangulation hits "empty bounding box" on the lowest-
    # convergence pairs that affineepipolar's full-frame geometry handles fine - so affine
    # leads and crop-win only rescues the pairs affine cannot match at all.)
    #
    # The crop-win overlap band sees the SAME ground over ~(H-advance) rows (~57 of 280) at ONE
    # end of each framelet. Restrict the correlator to the overlap
    # band with --left/right-image-crop-win. Inside the windows the overlap is ~full and the
    # residual disparity is only a few pixels (plus the pad offset), so plain alignment-method
    # none with a small explicit --corr-search locks densely even on featureless floor, with NO
    # interest points. ASP emits the matches in FULL-FRAME coordinates (verified), so no crop
    # offset bookkeeping is needed. The overlap END is known ahead of time from the per-look
    # framelet_order_reversed the stitch recorded (reversed=1 -> lower-index framelet overlaps at
    # its TOP, higher at BOTTOM; reversed=0 -> the opposite), VERIFIED on both looks, so we crop
    # deterministically with ONE stereo per pair, falling back to try-both only if that flag is
    # missing. Some lowest-convergence pairs fail crop-win triangulation too (empty bounding box);
    # those stay unmatched, same as before - the net effect is affine's set plus the crater pairs
    # crop-win can triangulate, never fewer than affine alone.
    [ -s "$mf" ] && exit 0
    ia=$(img_of "$a"); ib=$(img_of "$b")
    [ -s "$ia" ] && [ -s "$ib" ] && [ -s "$ca" ] && [ -s "$cb" ] || { echo "  skip same $a $b (no input)"; exit 0; }
    # PRIMARY: full-frame affineepipolar (proven; keep whatever it matches). Only on abort/no
    # match do we fall through to the crop-window rescue below.
    aff="$od/aff"; rm -rf "$aff"; mkdir -p "$aff"
    parallel_stereo --processes 1 --threads-multiprocess $T --threads-singleprocess $T                  \
      --alignment-method affineepipolar --stereo-algorithm asp_mgm --subpixel-mode 9 --corr-seed-mode 1 \
      --ip-detect-method 1 --ip-per-image 12000                                                         \
      --num-matches-from-disparity $nmd --min-triangulation-angle 1e-10                                 \
      "$ia" "$ib" "$ca" "$cb" "$aff/run" > "$aff.log" 2>&1
    m=$(ls "$aff"/run-disp-*.match 2>/dev/null | head -1)
    if [ -n "$m" ] && [ -s "$m" ]; then cp -f "$m" "$mf"; echo "  same $a $b: affine match"; exit 0; fi
    echo "  same $a $b: affine failed, trying crop-win rescue"
    # framelet size (W x H) from the image; defaults for CaSSIS PAN if gdalinfo is unavailable
    sz=$(gdalinfo "$ia" 2>/dev/null | sed -n 's/.*Size is \([0-9][0-9]*\), \([0-9][0-9]*\).*/\1 \2/p' | head -1)
    W=$(echo "$sz" | awk '{print $1}'); H=$(echo "$sz" | awk '{print $2}')
    case "$W" in ''|*[!0-9]*) W=2048 ;; esac
    case "$H" in ''|*[!0-9]*) H=280 ;; esac
    K=90; [ "$K" -ge "$H" ] && K=$(( H > 20 ? H - 10 : H ))   # overlap-band window (rows)
    topwin="0 0 $W $K"; botwin="0 $(( H - K )) $W $K"
    nmatch() { [ -s "$1" ] && python3 -c "import struct,sys;print(struct.unpack('<q',open(sys.argv[1],'rb').read(8))[0])" "$1" 2>/dev/null || echo 0; }
    same_try() {  # $1=outdir $2=left-cropwin $3=right-cropwin $4=corr-seed-mode ; echoes match path
      rm -rf "$1"; mkdir -p "$1"
      parallel_stereo --processes 1 --threads-multiprocess $T --threads-singleprocess $T           \
        --left-image-crop-win $2 --right-image-crop-win $3                                         \
        --alignment-method none --stereo-algorithm asp_mgm --subpixel-mode 9 --corr-seed-mode "$4" \
        --corr-search -24 -55 24 55                                                                \
        --num-matches-from-disparity $nmd --min-triangulation-angle 1e-10                          \
        "$ia" "$ib" "$ca" "$cb" "$1/run" > "$1.log" 2>&1
      ls "$1"/run-disp-*.match 2>/dev/null | head -1
    }
    cropped_try() {  # $1=left-cropwin $2=right-cropwin (into $od); seed 1 then 0; echoes match
      local m; m=$(same_try "$od" "$1" "$2" 1); [ -z "$m" ] && m=$(same_try "$od" "$1" "$2" 0); echo "$m"
    }
    # this pair's look + its reverse flag + the two framelet indices (a=left, b=right)
    rev=-1; sid=""
    case "$a" in *"$Llook"*) sid=$Llook; rev=${revLlook:--1} ;; *"$Rlook"*) sid=$Rlook; rev=${revRlook:--1} ;; esac
    ai=$(echo "$a" | sed -E "s/.*-${sid}-([0-9]+)-0__4_0.*/\1/"); bi=$(echo "$b" | sed -E "s/.*-${sid}-([0-9]+)-0__4_0.*/\1/")
    case "$ai$bi" in ''|*[!0-9]*) rev=-1 ;; esac   # index parse failed -> fall back to try-both
    best=""; bestn=0
    if [ "$rev" = 1 ] || [ "$rev" = 0 ]; then
      # rule: reversed=1 -> lower-index framelet crops TOP (higher BOTTOM); reversed=0 -> opposite
      if [ "$ai" -lt "$bi" ]; then   # a=left is the lower index
        if [ "$rev" = 1 ]; then lcw=$topwin; rcw=$botwin; else lcw=$botwin; rcw=$topwin; fi
      else                            # a=left is the higher index
        if [ "$rev" = 1 ]; then lcw=$botwin; rcw=$topwin; else lcw=$topwin; rcw=$botwin; fi
      fi
      best=$(cropped_try "$lcw" "$rcw"); bestn=$(nmatch "$best")
    else                              # reverse flag unavailable -> try both ends, keep the richer
      best=$(cropped_try "$botwin" "$topwin"); bestn=$(nmatch "$best")
      if [ "${bestn:-0}" -lt 200 ]; then
        od_save=$od; od="${od}_flip"; m2=$(cropped_try "$topwin" "$botwin"); od=$od_save
        n2=$(nmatch "$m2"); [ "${n2:-0}" -gt "${bestn:-0}" ] && { best="$m2"; bestn=$n2; }
      fi
    fi
    [ -n "$best" ] && [ -s "$best" ] && { cp -f "$best" "$mf"; echo "  same $a $b: $bestn matches (crop-win, rev=$rev)"; } \
      || echo "  NO MATCH same $a $b (crop-win, rev=$rev)"
    ;;
  *) echo "  bad mode $mode"; exit 0 ;;
esac
