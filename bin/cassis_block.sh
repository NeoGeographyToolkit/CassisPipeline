#!/bin/bash
# cassis_block.sh - ONE tic-toc BLOCK that BUILDS ON a previous block's output (no bootstrap).
# The repeating unit: INPUT {cams (imgList+camList), gcp} -> tic (fix-gcp) -> toc
# (no-gcp htdem) -> stereo (mapproj NATIVE mapprojRes, point2dem demRes) -> corr @corrRes (dd-H/dd-V @that px)
# + dz -> dem2gcp @corrRes -> OUTPUT {DEM, cams, new gcp}. Same as cassis_pass.sh minus the linescan bootstrap.
# Block 1 = cassis_pass.sh (bootstrap + block); block 2..N = cassis_block.sh on the prev block's {cams, gcp}.
# Reuses cassis_ba.sh / cassis_stereo.sh / cassis_corr.sh / gen_gcp.sh. Self-contained qsub.
# Args (B LAST): <pairDir> <inImgList> <inCamList> <inGcp> <refdem> <mapprojDem> <matchpfx> <Llook> <Rlook>
#   <mapprojRes> <demRes> <corrRes> <corrSearch> <htUncTic> <htUncToc> <camPosUnc> <robust> <gcpSigma>
#   <maxGcp> <maxDisp> <geounc> <outTag> <B>
set +e; umask 022
pairDir=${1:?pairDir}; inImgList=${2:?inImgList (prev block run-image_list.txt)}; inCamList=${3:?inCamList}
inGcp=${4:?inGcp (prev block gcp)}; refdem=${5:?refdem}; mapprojDem=${6:?mapprojDem}; matchpfx=${7:?matchpfx}
Llook=${8:?Llook}; Rlook=${9:?Rlook}; mapprojRes=${10:?mapprojRes (NATIVE 4.59)}; demRes=${11:?demRes (18)}
corrRes=${12:?corrRes (18)}; corrSearch=${13:?corrSearch}; htUncTic=${14:?htUncTic}; htUncToc=${15:?htUncToc}
camPosUnc=${16:?camPosUnc}; robust=${17:?robust}; gcpSigma=${18:?gcpSigma}; maxGcp=${19:?maxGcp}
maxDisp=${20:?maxDisp}; geounc=${21:?geounc}; outTag=${22:?outTag}
tocGcpMode=${23:?tocGcpMode (no_gcp|soft_gcp)}; B=${24:?B (cd target, LAST)}
cd "$B" || { echo "ERROR cannot cd $B"; exit 1; }
# ASP/ISIS tools on PATH and environment are set up by the caller. See the README.
log=$B/output_${outTag}_block.txt; exec > "$log" 2>&1
echo "=== [cassis_block] START $(date) host=$(uname -n) outTag=$outTag (builds on $inImgList) ==="
echo "  inGcp=$inGcp mapprojRes=$mapprojRes demRes=$demRes corrRes=$corrRes htUncTic=$htUncTic htUncToc=$htUncToc"
for f in "$inImgList" "$inCamList" "$inGcp" "$refdem" "$mapprojDem"; do [ -s "$f" ] || { echo "ERROR missing $f"; exit 1; }; done
G=$pairDir/frame/$outTag; mkdir -p "$G/dem2gcp"

# === [1] TIC: BA fix-gcp on the input gcp (from the input cams) - horizontal anchor ===
echo "=== [1/4] TIC BA fix-gcp $(date) ==="
bash cassis_ba.sh "$pairDir" "${outTag}_tic" "$inImgList" "$inCamList" "$refdem" "$matchpfx" \
  "$htUncTic" "$camPosUnc" "$inGcp" yes "$robust" no_intr_float "$B" || { echo "STAGE_FAIL tic"; exit 1; }
ticImg=$pairDir/frame/${outTag}_tic/run-image_list.txt; ticCam=$pairDir/frame/${outTag}_tic/run-camera_list.txt
[ -s "$ticImg" ] && [ -s "$ticCam" ] || { echo "STAGE_FAIL tic no lists"; exit 1; }

# === [2] TOC: BA + htdem from the tic cams - vertical, keeps horizontal ===
# TOC gcp mode: default no_gcp (pure vertical). soft_gcp reuses the INPUT gcp at its baked
# sigma with fixgcp=no (a SOFT anchor, not fixed), to pull under-constrained END framelets toward CTX
# without disturbing the well-behaved mid-strip. Used for ox1 where the strip ends drift; a per-site
# choice, off by default so every other site is byte-identical to before.
tocGcp=no_gcp; tocFix=no
if [ "$tocGcpMode" = soft_gcp ]; then
  [ -s "$inGcp" ] || { echo "STAGE_FAIL toc soft_gcp but inGcp missing $inGcp"; exit 1; }
  tocGcp="$inGcp"; tocFix=no
  echo "  TOC soft-GCP: $inGcp ($(grep -vc '^#' "$inGcp") pts, sigma from file, fixgcp=no)"
elif [ "$tocGcpMode" != no_gcp ]; then
  echo "STAGE_FAIL bad tocGcpMode=$tocGcpMode (want no_gcp|soft_gcp)"; exit 1
fi
echo "=== [2/4] TOC BA htdem $htUncToc tocGcpMode=$tocGcpMode $(date) ==="
bash cassis_ba.sh "$pairDir" "$outTag" "$ticImg" "$ticCam" "$refdem" "$matchpfx" \
  "$htUncToc" "$camPosUnc" "$tocGcp" "$tocFix" "$robust" no_intr_float "$B" || { echo "STAGE_FAIL toc"; exit 1; }
outImg=$pairDir/frame/$outTag/run-image_list.txt; outCam=$pairDir/frame/$outTag/run-camera_list.txt
[ -s "$outImg" ] && [ -s "$outCam" ] || { echo "STAGE_FAIL toc no lists"; exit 1; }

# === [3] STEREO: mapproject/correlate NATIVE mapprojRes, point2dem demRes ===
echo "=== [3/4] STEREO mapproj $mapprojRes DEM $demRes $(date) ==="
bash cassis_stereo.sh "$pairDir" "$outTag" "$outImg" "$outCam" "$geounc" "$mapprojDem" "$refdem" \
  "$mapprojRes" "$demRes" "$matchpfx" "$Llook" "$Rlook" 0 "$B" || { echo "STAGE_FAIL stereo"; exit 1; }
dem=$pairDir/frame/${outTag}_stereo/cassis_dem.tif
[ -s "$dem" ] || { echo "STAGE_FAIL stereo no DEM $dem"; exit 1; }

# === [4] EVAL corr @corrRes (dd-H/dd-V @that px) + dz, then dem2gcp -> new gcp ===
echo "=== [4/4] EVAL corr @${corrRes}m + dz + dem2gcp $(date) ==="
evd=$pairDir/frame/${outTag}_stereo/eval18
bash cassis_corr.sh "$dem" "$refdem" "$corrRes" "$corrSearch" "$evd" 15 || echo "  WARN eval corr failed"
geodiff "$evd/warped_${corrRes}m.tif" "$evd/ctx_${corrRes}m.tif" -o "$evd/dz" >/dev/null 2>&1 || echo "  WARN dz failed"
echo "  dz  std vs CTX (m):  $(gdalinfo -stats $evd/dz-diff.tif 2>/dev/null | grep -a STATISTICS_STDDEV | sed 's/.*=//')"
echo "  dd-H std (px@${corrRes}m): $(gdalinfo -stats $evd/run-F-H.tif 2>/dev/null | grep -a STATISTICS_STDDEV | sed 's/.*=//')"
echo "  dd-V std (px@${corrRes}m): $(gdalinfo -stats $evd/run-F-V.tif 2>/dev/null | grep -a STATISTICS_STDDEV | sed 's/.*=//')"
gcpN=$G/dem2gcp/gcp.gcp
bash gen_gcp.sh "$evd/warped_${corrRes}m.tif" "$evd/ctx_${corrRes}m.tif" "$evd/run-F.tif" \
  "$outImg" "$outCam" "$matchpfx" "$maxDisp" "$gcpN" "$gcpSigma" "$maxGcp" || echo "  WARN dem2gcp failed"
echo "  new GCP: $gcpN ($(grep -vc '^#' "$gcpN" 2>/dev/null) pts)"

echo "CASSIS_BLOCK_DONE $outTag $(date)"
echo "OUTPUTS: DEM=$dem  cams=frame/$outTag/  gcp=$gcpN  eval=$evd  tri-err=frame/${outTag}_stereo/max_tri_err.tif"
