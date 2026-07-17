#!/bin/bash
# cassis_pass.sh - ONE formalized replication PASS at 18 m (the BLOCK).
# Steps: [1] BOOTSTRAP corr the aligned LINESCAN DEM vs CTX @corrRes -> dem2gcp -> GCP0 (NO framelet BA -
# the linescan is the registration anchor); [2] TIC = BA fix-gcp GCP0 from the start cams (first joint
# BA = the anchor); [3] TOC = BA no-gcp + htdem from the tic cams (vertical, keeps horizontal); [4] STEREO
# mapproject/correlate NATIVE mapprojRes, point2dem demRes; [5] EVAL corr @corrRes -> dd-H/dd-V + dz (this
# ONE corr also feeds dem2gcp); [6] dem2gcp @corrRes -> GCP1 (next block input). Reuses cassis_ba.sh,
# cassis_stereo.sh, cassis_corr.sh, gen_gcp.sh. Self-contained under qsub. Compare vs frame/toc1_ht1_stereo.
# Args (B LAST): <pairDir> <startCamDir> <linescanDem> <refDem> <mapprojDem> <matchpfx> <Llook> <Rlook>
#   <mapprojRes> <demRes> <corrRes> <corrSearch> <htUncLoose> <htUncTight> <camPosUnc> <robust> <gcpSigma>
#   <maxGcp> <maxDisp> <geounc> <outTag> <B>
set +e; umask 022
pairDir=${1:?pairDir}; startCamDir=${2:?startCamDir (start cams)}; linescanDem=${3:?linescan aligned DEM}
refDem=${4:?refDem (SHARP CTX)}; mapprojDem=${5:?mapprojDem (BLURRED CTX)}; matchpfx=${6:?matchpfx}
Llook=${7:?Llook}; Rlook=${8:?Rlook}; mapprojRes=${9:?mapprojRes (NATIVE 4.59)}; demRes=${10:?demRes (18)}
corrRes=${11:?corrRes (18)}; corrSearch=${12:?corrSearch}; htUncLoose=${13:?htUncLoose}; htUncTight=${14:?htUncTight}
camPosUnc=${15:?camPosUnc}; robust=${16:?robust}; gcpSigma=${17:?gcpSigma}; maxGcp=${18:?maxGcp}
maxDisp=${19:?maxDisp}; geounc=${20:?geounc}; outTag=${21:?outTag}; B=${22:?B (cd target, LAST)}
cd "$B" || { echo "ERROR cannot cd $B"; exit 1; }
# ASP/ISIS tools on PATH and environment are set up by the caller. See the README.
log=$B/output_${outTag}_pass.txt; exec > "$log" 2>&1
echo "=== [cassis_pass] START $(date) host=$(uname -n) outTag=$outTag ==="
echo "  pairDir=$pairDir startCamDir=$startCamDir linescanDem=$linescanDem"
echo "  mapprojRes=$mapprojRes demRes=$demRes corrRes=$corrRes corrSearch=$corrSearch"
echo "  htUncLoose=$htUncLoose htUncTight=$htUncTight camPosUnc=$camPosUnc robust=$robust gcpSigma=$gcpSigma"

for f in "$linescanDem" "$refDem" "$mapprojDem"; do [ -s "$f" ] || { echo "ERROR missing $f"; exit 1; }; done
G=$pairDir/frame/$outTag; mkdir -p "$G/dem2gcp"

# build the start-cam image/camera lists (1-1): each start-cam .json + its matching cub
img=$G/images.txt; cam=$G/cameras.txt; : > "$img"; : > "$cam"
for camf in "$startCamDir"/*.json; do
  [ -e "$camf" ] || continue
  stem=$(basename "$camf" .json)
  cub=$(ls data/$pairDir/L*/$stem.cub 2>/dev/null | head -1)
  [ -s "$cub" ] || { echo "  MISS cub for $stem"; continue; }
  echo "$cub" >> "$img"; echo "$camf" >> "$cam"
done
nI=$(wc -l < "$img"); echo "  lists: images=$nI cameras=$(wc -l < "$cam")"
[ "$nI" -ge 2 ] || { echo "ERROR too few images ($nI)"; exit 1; }

# === [1] BOOTSTRAP: corr the LINESCAN DEM vs CTX @corrRes, then dem2gcp -> GCP0 ===
echo "=== [1/6] BOOTSTRAP corr linescan vs CTX @${corrRes}m + dem2gcp $(date) ==="
boot=$G/boot
bash cassis_corr.sh "$linescanDem" "$refDem" "$corrRes" "$corrSearch" "$boot" 15 \
  || { echo "STAGE_FAIL boot corr"; exit 1; }
gcp0=$G/dem2gcp/gcp0.gcp
bash gen_gcp.sh "$boot/warped_${corrRes}m.tif" "$boot/ctx_${corrRes}m.tif" "$boot/run-F.tif" \
  "$img" "$cam" "$matchpfx" "$maxDisp" "$gcp0" "$gcpSigma" "$maxGcp" || { echo "STAGE_FAIL boot gcp"; exit 1; }
echo "  GCP0: $gcp0 ($(grep -vc '^#' "$gcp0" 2>/dev/null) pts)"

# === [2] TIC: first joint BA, fix-gcp GCP0 (from the start cams) - horizontal anchor ===
echo "=== [2/6] TIC BA fix-gcp $(date) ==="
bash cassis_ba.sh "$pairDir" "${outTag}_tic" "$img" "$cam" "$refDem" "$matchpfx" \
  "$htUncLoose" "$camPosUnc" "$gcp0" yes "$robust" no_intr_float "$B" || { echo "STAGE_FAIL tic"; exit 1; }
ticImg=$pairDir/frame/${outTag}_tic/run-image_list.txt; ticCam=$pairDir/frame/${outTag}_tic/run-camera_list.txt
[ -s "$ticImg" ] && [ -s "$ticCam" ] || { echo "STAGE_FAIL tic produced no lists"; exit 1; }

# === [3] TOC: BA no-gcp + htdem from the tic cams - vertical, keeps horizontal ===
echo "=== [3/6] TOC BA no-gcp htdem $htUncTight $(date) ==="
bash cassis_ba.sh "$pairDir" "$outTag" "$ticImg" "$ticCam" "$refDem" "$matchpfx" \
  "$htUncTight" "$camPosUnc" no_gcp no "$robust" no_intr_float "$B" || { echo "STAGE_FAIL toc"; exit 1; }
outImg=$pairDir/frame/$outTag/run-image_list.txt; outCam=$pairDir/frame/$outTag/run-camera_list.txt
[ -s "$outImg" ] && [ -s "$outCam" ] || { echo "STAGE_FAIL toc produced no lists"; exit 1; }

# === [4] STEREO: mapproject/correlate NATIVE mapprojRes, point2dem demRes ===
echo "=== [4/6] STEREO mapproj $mapprojRes DEM $demRes $(date) ==="
bash cassis_stereo.sh "$pairDir" "$outTag" "$outImg" "$outCam" "$geounc" "$mapprojDem" "$refDem" \
  "$mapprojRes" "$demRes" "$matchpfx" "$Llook" "$Rlook" 0 "$B" || { echo "STAGE_FAIL stereo"; exit 1; }
dem=$pairDir/frame/${outTag}_stereo/cassis_dem.tif
[ -s "$dem" ] || { echo "STAGE_FAIL stereo produced no DEM $dem"; exit 1; }

# === [5] EVAL corr @corrRes (dd-H/dd-V) + dz. This ONE corr also feeds dem2gcp in [6]. ===
echo "=== [5/6] EVAL corr @${corrRes}m + dz $(date) ==="
evd=$pairDir/frame/${outTag}_stereo/eval18
bash cassis_corr.sh "$dem" "$refDem" "$corrRes" "$corrSearch" "$evd" 15 || echo "  WARN eval corr failed"
geodiff "$evd/warped_${corrRes}m.tif" "$evd/ctx_${corrRes}m.tif" -o "$evd/dz" >/dev/null 2>&1 || echo "  WARN dz failed"
echo "  dz  std vs CTX (m):  $(gdalinfo -stats $evd/dz-diff.tif 2>/dev/null | grep -a STATISTICS_STDDEV | sed 's/.*=//')"
echo "  dd-H std (px):       $(gdalinfo -stats $evd/run-F-H.tif 2>/dev/null | grep -a STATISTICS_STDDEV | sed 's/.*=//')"
echo "  dd-V std (px):       $(gdalinfo -stats $evd/run-F-V.tif 2>/dev/null | grep -a STATISTICS_STDDEV | sed 's/.*=//')"

# === [6] dem2gcp @corrRes -> GCP1 (next block input) ===
echo "=== [6/6] dem2gcp @${corrRes}m -> GCP1 $(date) ==="
gcp1=$G/dem2gcp/gcp1.gcp
bash gen_gcp.sh "$evd/warped_${corrRes}m.tif" "$evd/ctx_${corrRes}m.tif" "$evd/run-F.tif" \
  "$outImg" "$outCam" "$matchpfx" "$maxDisp" "$gcp1" "$gcpSigma" "$maxGcp" || echo "  WARN dem2gcp failed"
echo "  GCP1: $gcp1 ($(grep -vc '^#' "$gcp1" 2>/dev/null) pts)"

echo "CASSIS_PASS_DONE $outTag $(date)"
echo "OUTPUTS: DEM=$dem  cams=frame/$outTag/  GCP0=$gcp0 GCP1=$gcp1  eval=$evd  tri-err=frame/${outTag}_stereo/max_tri_err.tif"
