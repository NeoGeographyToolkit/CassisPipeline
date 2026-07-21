#!/bin/bash
# cassis_run.sh - CONFIG-DRIVEN pass driver. Sources a shared recipe (cassis_common.conf) +
# a per-site config (cassis_siteName.conf), hard-errors on any unset var or missing input,
# then runs ONE stage: pass1 via cassis_pass.sh, pass2 via cassis_block.sh (builds on pass1's
# cams+GCP1). Uses the dense matches under outDir. cassis_process.sh delegates stages 7-8 here; it
# can also be run standalone for a single pass. The site nick (from the config name) labels the logs.
# Usage:  cassis_run.sh <site.conf> <pass1|pass2> <outDir> <B>
#   e.g.  cassis_run.sh cassis_jezero.conf pass1 jezero_out /path/to/workdir
#   pass1 -> outDir/frame/pass1 (+ pass1_stereo); pass2 -> outDir/frame/pass2, building on pass1.
#   All runs are geounc=0.
set +e; umask 022
cfg=${1:?site config (cassis_siteName.conf)}; stage=${2:?stage pass1|pass2}
outDir=${3:?outDir (output dir, relative to workdir or absolute; changes per run)}; B=${4:?work base LAST}
# The ASP and ISIS tools must be on PATH and the environment set up beforehand.
# See the repository README, Environment section.
cd "$B" || { echo "ERROR cannot cd $B"; exit 1; }

nick=$(basename "$cfg" .conf | sed 's/^cassis_//; s/_site$//')
[ -s "$B/cassis_common.conf" ] || { echo "ERROR missing cassis_common.conf"; exit 1; }
[ -s "$B/$cfg" ] || { echo "ERROR missing site config $cfg"; exit 1; }
source "$B/cassis_common.conf"
source "$B/$cfg"
source cassis_env_check.sh
cassis_require bundle_adjust parallel_stereo point2dem mapproject dem_mosaic geodiff gdalwarp gdalinfo
matchpfx=${matchpfx:-$outDir/frame/dense/matches/run-disp}   # uniform; a config MAY override
pass2Gcp=${pass2Gcp:-no_gcp}   # pass2 TOC gcp mode: no_gcp default; soft_gcp is a general off-by-default option
# linescanDem and startCamDir are derived from outDir by convention (a config MAY override).
startCamDir=${startCamDir:-$outDir/frame/distortion_corrected_cassis_cams}
linescanDem=${linescanDem:-$outDir/linescan/linescan_dem/align/aligned_oncoarse.tif}

# validate every var is set (no silent default) + inputs exist
for v in inputCassisDir outDir refDem mapprojDem linescanDem startCamDir Llook Rlook matchpfx \
         mapprojRes demRes corrRes corrSearch htUncLoose htUncTight camPosUnc robust gcpSigma maxGcp maxDisp geounc; do
  eval "val=\$$v"; [ -n "$val" ] || { echo "ERROR config var $v is UNSET"; exit 1; }
done
for f in "$refDem" "$mapprojDem" "$linescanDem"; do [ -s "$f" ] || { echo "ERROR missing input $f"; exit 1; }; done
ncam=$(ls "$startCamDir"/*.json 2>/dev/null | wc -l | tr -d ' ')
[ "${ncam:-0}" -ge 2 ] || { echo "ERROR too few start cams in $startCamDir ($ncam)"; exit 1; }

log=$B/output_${nick}_${stage}_run.txt; exec > "$log" 2>&1
echo "=== [cassis_run] START $(date) host=$(uname -n) nick=$nick site=$outDir stage=$stage ==="
echo "  cfg=$cfg  GEO=$geounc MPR=$mapprojRes DR=$demRes CR=$corrRes CS=$corrSearch HTIC=$htUncLoose HTOC=$htUncTight CPU=$camPosUnc ROB=$robust GS=$gcpSigma MG=$maxGcp MD=$maxDisp"
echo "  refDem=$refDem mapprojDem=$mapprojDem linescanDem=$linescanDem startCamDir=$startCamDir ($ncam cams) LL=$Llook RL=$Rlook"

# Dense matches are emitted full-name by cassis_stereo.sh DENSE mode (imgList = full-name cams), so
# the BA and dem2gcp find them directly - no short->full conversion step.

if [ "$stage" = pass1 ]; then
  outTag=pass1
  echo "===== pass1 outTag=$outTag $(date) ====="
  bash cassis_pass.sh "$outDir" "$startCamDir" "$linescanDem" "$refDem" "$mapprojDem" "$matchpfx" "$Llook" "$Rlook" \
    "$mapprojRes" "$demRes" "$corrRes" "$corrSearch" "$htUncLoose" "$htUncTight" "$camPosUnc" "$robust" "$gcpSigma" \
    "$maxGcp" "$maxDisp" "$geounc" "$outTag" "$inputCassisDir" "$B" || { echo "PASS1_FAIL (see output_${outTag}_pass.txt)"; exit 1; }
elif [ "$stage" = pass2 ]; then
  p1Tag=pass1; outTag=pass2
  P1IMG=$outDir/frame/${p1Tag}/run-image_list.txt
  P1CAM=$outDir/frame/${p1Tag}/run-camera_list.txt
  P1GCP=$outDir/frame/${p1Tag}/dem2gcp/gcp1.gcp
  for f in "$P1IMG" "$P1CAM" "$P1GCP"; do [ -s "$f" ] || { echo "PASS1 output missing $f - run pass1 first"; exit 1; }; done
  echo "===== pass2 outTag=$outTag (builds on $p1Tag: img=$(wc -l <"$P1IMG") cam=$(wc -l <"$P1CAM") gcp=$(grep -vc '^#' "$P1GCP")) $(date) ====="
  bash cassis_block.sh "$outDir" "$P1IMG" "$P1CAM" "$P1GCP" "$refDem" "$mapprojDem" "$matchpfx" "$Llook" "$Rlook" \
    "$mapprojRes" "$demRes" "$corrRes" "$corrSearch" "$htUncLoose" "$htUncTight" "$camPosUnc" "$robust" "$gcpSigma" \
    "$maxGcp" "$maxDisp" "$geounc" "$outTag" "$pass2Gcp" "$B" || { echo "PASS2_FAIL (see output_${outTag}_block.txt)"; exit 1; }
else
  echo "ERROR unknown stage '$stage' (want pass1|pass2)"; exit 1
fi
dem=$outDir/frame/${outTag}_stereo/cassis_dem.tif
[ -s "$dem" ] || { echo "STAGE produced no DEM $dem"; exit 1; }
echo "=== [cassis_run] DONE $(date) stage=$stage DEM=$dem ==="
echo "CASSIS_WF1_RUN_DONE $outDir $stage $dem"
