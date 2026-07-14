#!/bin/bash
# CaSSIS dem2gcp CORRELATOR stage, parameterized by resolution + search radius.
# Warps two DEMs to a COMMON grid (taken from <ref_ctx> proj+extent) at <res> m with
# cubicspline, hillshades each with GDAL (-multidirectional -compute_edges -alt 15),
# then parallel_stereo --correlator-mode (asp_mgm, corr-kernel 9 9, subpixel 9) ->
# <out_dir>/run-F.tif (H/V/validity = the input-DEM -> ref-CTX disparity). This
# disparity feeds the ground control point generation and is also used to measure
# the horizontal registration of a DEM to the CTX reference.
# Usage: cassis_corr.sh <in_dem> <ref_ctx> <res> <corr_search> <out_dir>
umask 022
set -e
in=${1:?in_dem}; ref=${2:?ref_ctx}; res=${3:?res}; S=${4:?corr_search}; out=${5:?out_dir}
alt=${6:-15}   # OPTIONAL (shared script; other callers omit it). Default 15. My driver passes it explicitly.
# ASP/ISIS tools on PATH and environment are set up by the caller. See the README.
mkdir -p $out
echo "cassis_corr: in=$in ref=$ref res=$res search=$S out=$out"
# --- Co-grid CTX + the CaSSIS DEM on ONE grid, CROPPED to the CaSSIS footprint (shared box). ---
# The dd correlator is weak at sub-pixel, so gdalwarp (NOT the correlator) does the co-gridding, and
# CTX (the "nice" grid) is NOT knocked off its lattice: crop CTX by an INTEGER pixel window
# (gdal_translate -srcwin = no resample, stays on CTX's grid), then warp ONLY the CaSSIS DEM onto that
# exact extent+size (-te + -ts). Requires ref (CTX) to be AT <res> (we pass the 18 m CTX at res 18).
# FALLBACK to the old full-extent warp of both if ref res != <res>, the window is degenerate, or the
# two outputs end up different sizes (a hard co-grid ASSERT: a size mismatch = an unphysical dd shift).
# Use GDAL CLI (PBS python3 lacks osgeo). Strip gdalsrsinfo's leading blank line for -t_srs.
gdalsrsinfo -o wkt "$ref" | sed '/^[[:space:]]*$/d' > $out/_srs.wkt
do_fullwarp(){
  local TE
  TE=$(gdalinfo "$ref" | awk '/Upper Left/{gsub(/[(),]/," ");ulx=$3;uly=$4}/Lower Right/{gsub(/[(),]/," ");lrx=$3;lry=$4}END{print ulx,lry,lrx,uly}')
  gdalwarp -overwrite -t_srs $out/_srs.wkt -te $TE -tr $res $res -r cubicspline "$in"  $out/warped_${res}m.tif >/dev/null
  gdalwarp -overwrite -t_srs $out/_srs.wkt -te $TE -tr $res $res -r cubicspline "$ref" $out/ctx_${res}m.tif    >/dev/null
}
read ROX ROY <<< "$(gdalinfo "$ref" | awk '/^Origin/{gsub(/[(),]/," ");print $3,$4}')"
RPX=$(gdalinfo "$ref" | awk '/Pixel Size/{gsub(/[(),]/," ");v=$4;if(v<0)v=-v;print v}')
read RW RH <<< "$(gdalinfo "$ref" | awk '/^Size is/{gsub(/,/," ");print $3,$4}')"
read IULX IULY ILRX ILRY <<< "$(gdalinfo "$in" | awk '/Upper Left/{gsub(/[(),]/," ");ulx=$3;uly=$4}/Lower Right/{gsub(/[(),]/," ");lrx=$3;lry=$4}END{print ulx,uly,lrx,lry}')"
win=$(awk -v rox="$ROX" -v roy="$ROY" -v px="$RPX" -v rw="$RW" -v rh="$RH" -v res="$res" \
  -v iulx="$IULX" -v iuly="$IULY" -v ilrx="$ILRX" -v ilry="$ILRY" 'BEGIN{
    d=px-res; if(d<0)d=-d; if(d>0.02*res){print "FALLBACK"; exit}
    xoff=int((iulx-rox)/px); yoff=int((roy-iuly)/px);
    xend=int((ilrx-rox)/px+0.999999); yend=int((roy-ilry)/px+0.999999);
    if(xoff<0)xoff=0; if(yoff<0)yoff=0; if(xend>rw)xend=rw; if(yend>rh)yend=rh;
    xs=xend-xoff; ys=yend-yoff; if(xs<2||ys<2){print "FALLBACK"; exit}
    printf "%d %d %d %d", xoff, yoff, xs, ys}')
if [ "$win" = FALLBACK ] || [ -z "$win" ]; then
  echo "  crop: FALLBACK full-extent warp (ref res!=$res or degenerate window)"; do_fullwarp
else
  set -- $win; XOFF=$1; YOFF=$2; XS=$3; YS=$4
  echo "  crop: CTX srcwin $XOFF $YOFF $XS $YS -> CaSSIS footprint on CTX grid"
  gdal_translate -q -srcwin $XOFF $YOFF $XS $YS "$ref" $out/ctx_${res}m.tif || true
  CTE=$(gdalinfo $out/ctx_${res}m.tif | awk '/Upper Left/{gsub(/[(),]/," ");ulx=$3;uly=$4}/Lower Right/{gsub(/[(),]/," ");lrx=$3;lry=$4}END{print ulx,lry,lrx,uly}')
  gdalwarp -overwrite -t_srs $out/_srs.wkt -te $CTE -ts $XS $YS -r cubicspline "$in" $out/warped_${res}m.tif >/dev/null || true
fi
# ASSERT identical grid size (else the dd carries an unphysical framing shift -> fall back to full warp).
WS=$(gdalinfo $out/warped_${res}m.tif 2>/dev/null | awk '/^Size is/{gsub(/,/," ");print $3"x"$4}')
CS2=$(gdalinfo $out/ctx_${res}m.tif   2>/dev/null | awk '/^Size is/{gsub(/,/," ");print $3"x"$4}')
if [ -z "$WS" ] || [ "$WS" != "$CS2" ]; then
  echo "  co-grid ASSERT failed (warped '$WS' vs ctx '$CS2') -> FALLBACK full-extent warp"; do_fullwarp
fi
gdaldem hillshade -multidirectional -compute_edges -alt $alt $out/warped_${res}m.tif $out/warped_hill.tif > /dev/null
gdaldem hillshade -multidirectional -compute_edges -alt $alt $out/ctx_${res}m.tif    $out/ctx_hill.tif    > /dev/null
parallel_stereo --correlator-mode --stereo-algorithm asp_mgm \
  --corr-kernel 9 9 --ip-per-image 40000 --subpixel-mode 9 \
  --corr-search -$S -$S $S $S --processes 8 \
  $out/warped_hill.tif $out/ctx_hill.tif \
  --num-matches-from-disparity 40000 \
  $out/run > $out/corr.log 2>&1
echo "CORR_DONE -> $out/run-F.tif"

# --- RAW disparity bands for ANALYSIS (dd-H = across-track, dd-V = along-track) ---
# CRITICAL: NEVER analyze run-F.tif with gdalinfo/gdal_translate. Its band 3 is a VALIDITY
# MASK that generic GDAL ignores, so invalid (uncorrelated) pixels read as 0 and pollute the
# dd-H/dd-V stats - a mostly-invalid flat scene then looks like ~0 shift, hiding the real one.
# disparitydebug --raw writes Float32 H/V with real nodata (-1e6). ALWAYS stat THESE two files,
# never run-F.tif. disparitydebug needs ISIS initialized (ISISROOT set), which the
# caller's environment provides (see the README).
if disparitydebug --raw $out/run-F.tif --output-prefix $out/run-F > $out/disparitydebug.log 2>&1; then
  echo "DISP_BANDS -> $out/run-F-H.tif (dd-H), $out/run-F-V.tif (dd-V)  [analyze THESE, not run-F.tif]"
else
  echo "WARN disparitydebug failed ($out/disparitydebug.log) - set ISISROOT before dd-H/dd-V analysis"
fi
