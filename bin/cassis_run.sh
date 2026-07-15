#!/bin/bash
# cassis_run.sh - CONFIG-DRIVEN pass driver. Sources a shared recipe (cassis_common.conf) +
# a per-site config (cassis_siteName.conf), hard-errors on any unset var or missing input,
# then runs ONE stage: pass1 via cassis_pass.sh, pass2 via cassis_block.sh (builds on pass1's
# cams+GCP1). Uses the existing full-name dense matches. The output tag carries the SITE NICK, so
# every worker's output_<tag>_*.txt is PER-SITE automatically. cassis_process.sh delegates stages
# 7-8 here; it can also be run standalone for a single pass.
# Usage:  cassis_run.sh <site.conf> <pass1|pass2> <tagBase> <B>
#   e.g.  cassis_run.sh cassis_jezero.conf pass1 cpass /path/to/workdir
#   -> nick=jezero, pass1 outTag=jezero_cpass1 (frame/jezero_cpass1*, frame/jezero_cpass1_stereo);
#      pass2 outTag=jezero_cpass2 builds on frame/jezero_cpass1/. ALL new runs are geounc=0. The
#      OLD on-disk frame/pass1_stereo,pass2_stereo were made EARLIER at geounc=50; we do NOT re-run
#      or overwrite them - kept only as the "before" picture to compare the new geounc=0 result against.
set +e; umask 022
cfg=${1:?site config (cassis_siteName.conf)}; stage=${2:?stage pass1|pass2}
tagBase=${3:?outTag base e.g. cpass}; B=${4:?work base LAST}
# The ASP and ISIS tools must be on PATH and the environment set up beforehand.
# See the repository README, Environment section.
cd "$B" || { echo "ERROR cannot cd $B"; exit 1; }

nick=$(basename "$cfg" .conf | sed 's/^cassis_//; s/_site$//')
[ -s "$B/cassis_common.conf" ] || { echo "ERROR missing cassis_common.conf"; exit 1; }
[ -s "$B/$cfg" ] || { echo "ERROR missing site config $cfg"; exit 1; }
source "$B/cassis_common.conf"
source "$B/$cfg"
matchpfx=${matchpfx:-$pairDir/frame/dense/matches/run-disp}   # uniform; a config MAY override
pass2TocGcp=${pass2TocGcp:-no_gcp}   # pass2 TOC gcp mode (no_gcp default; soft_gcp per site)

# validate every var is set (no silent default) + inputs exist
for v in pairDir refdem drape linescanDEM startCamDir Llook Rlook matchpfx \
         mapprojRes demRes corrRes corrSearch htUncTic htUncToc camPosUnc robust gcpSigma maxGcp maxDisp geounc; do
  eval "val=\$$v"; [ -n "$val" ] || { echo "ERROR config var $v is UNSET"; exit 1; }
done
for f in "$refdem" "$drape" "$linescanDEM"; do [ -s "$f" ] || { echo "ERROR missing input $f"; exit 1; }; done
ncam=$(ls "$startCamDir"/*.json 2>/dev/null | wc -l | tr -d ' ')
[ "${ncam:-0}" -ge 2 ] || { echo "ERROR too few start cams in $startCamDir ($ncam)"; exit 1; }

log=$B/output_${nick}_${tagBase}_${stage}_run.txt; exec > "$log" 2>&1
echo "=== [cassis_run] START $(date) host=$(uname -n) nick=$nick site=$pairDir stage=$stage ==="
echo "  cfg=$cfg  GEO=$geounc MPR=$mapprojRes DR=$demRes CR=$corrRes CS=$corrSearch HTIC=$htUncTic HTOC=$htUncToc CPU=$camPosUnc ROB=$robust GS=$gcpSigma MG=$maxGcp MD=$maxDisp"
echo "  refdem=$refdem drape=$drape linescanDEM=$linescanDEM startCamDir=$startCamDir ($ncam cams) LL=$Llook RL=$Rlook"

# Dense matches are emitted full-name by cassis_stereo.sh DENSE mode (imgList = full-name cams), so
# the BA and dem2gcp find them directly - no short->full conversion step.

if [ "$stage" = pass1 ]; then
  outTag=${nick}_${tagBase}1
  echo "===== pass1 outTag=$outTag $(date) ====="
  bash cassis_pass.sh "$pairDir" "$startCamDir" "$linescanDEM" "$refdem" "$drape" "$matchpfx" "$Llook" "$Rlook" \
    "$mapprojRes" "$demRes" "$corrRes" "$corrSearch" "$htUncTic" "$htUncToc" "$camPosUnc" "$robust" "$gcpSigma" \
    "$maxGcp" "$maxDisp" "$geounc" "$outTag" "$B" || { echo "PASS1_FAIL (see output_${outTag}_pass.txt)"; exit 1; }
elif [ "$stage" = pass2 ]; then
  p1Tag=${nick}_${tagBase}1; outTag=${nick}_${tagBase}2
  P1IMG=$pairDir/frame/${p1Tag}/run-image_list.txt
  P1CAM=$pairDir/frame/${p1Tag}/run-camera_list.txt
  P1GCP=$pairDir/frame/${p1Tag}/dem2gcp/gcp1.gcp
  for f in "$P1IMG" "$P1CAM" "$P1GCP"; do [ -s "$f" ] || { echo "PASS1 output missing $f - run pass1 first"; exit 1; }; done
  echo "===== pass2 outTag=$outTag (builds on $p1Tag: img=$(wc -l <"$P1IMG") cam=$(wc -l <"$P1CAM") gcp=$(grep -vc '^#' "$P1GCP")) $(date) ====="
  bash cassis_block.sh "$pairDir" "$P1IMG" "$P1CAM" "$P1GCP" "$refdem" "$drape" "$matchpfx" "$Llook" "$Rlook" \
    "$mapprojRes" "$demRes" "$corrRes" "$corrSearch" "$htUncTic" "$htUncToc" "$camPosUnc" "$robust" "$gcpSigma" \
    "$maxGcp" "$maxDisp" "$geounc" "$outTag" "$pass2TocGcp" "$B" || { echo "PASS2_FAIL (see output_${outTag}_block.txt)"; exit 1; }
else
  echo "ERROR unknown stage '$stage' (want pass1|pass2)"; exit 1
fi
dem=$pairDir/frame/${outTag}_stereo/dem_frame_mosaic.tif
[ -s "$dem" ] || { echo "STAGE produced no DEM $dem"; exit 1; }
echo "=== [cassis_run] DONE $(date) stage=$stage DEM=$dem ==="
echo "CASSIS_WF1_RUN_DONE $pairDir $stage $dem"
