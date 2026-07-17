#!/bin/bash
# cassis_process.sh - the SINGLE end-to-end CaSSIS pipeline, from original inputs to the FINAL DEM.
# Config-driven (sources cassis_common.conf + a per-site cassis_siteName.conf), RESUMABLE by
# stage number, and TIMED (every heavy stage prints START/DONE + elapsed via `date`). No figures.
#
# STAGES (run stage k iff fromStage <= k <= toStage; each skips cheaply if its output already exists):
#   0  CTX reference build        cassis_ctx_build.sh          -> refdem + mapprojDem   [PREP]
#   1  linescan DEM               cassis_linescan_dem.sh       -> ls stereo DEM    [PREP, needs kernels]
#   2  align linescan -> CTX      cassis_align_cams.sh         -> cams_aligned states [PREP]
#   3  aligned framelets         linescan2framelets.sh        -> frame/aligned_framelets [PREP]
#   4  refit lens -> transverse   refit_transverse.sh          -> registered_cassis_cams    [PREP]
#   5  apply optimized distortion + refit pose (cam_gen loop)              -> startCamDir      [HEAVY]
#   6  dense matches                                           -> matchpfx*.match  [HEAVY]
#   7  pass1  (cassis_run.sh pass1)                        -> pass1 DEM        [HEAVY]
#   8  pass2  (cassis_run.sh pass2)                        -> FINAL DEM        [HEAVY]
#
# WHY split PREP (0-4) from HEAVY (5-8): stages 0-4 need SPICE kernels / camera generation and run on a
# workstation with the kernels; stages 5-8 are the compute-heavy part, for a cluster or compute node. A
# fresh site runs 0-4 on the prep host, then 5-8 on the compute node. For a site whose prep is already on
# disk, just run `cassis_process.sh <conf> 5 8 <B>` on the compute node.
# The final delivered DEM = <pairDir>/frame/siteName_runTag2_stereo/cassis_dem.tif (+ _on_ctx.tif).
#
# Usage:  cassis_process.sh <site.conf> <fromStage> <toStage> <tagBase> <B>
#   e.g.  cassis_process.sh cassis_ox1.conf 5 8 runTag /path/to/workdir
#   tagBase names the pass1/pass2 output dirs (frame/siteName_<tagBase>1, _<tagBase>2). Reuse an
#   existing tagBase to RESUME/skip finished passes; pass a FRESH tagBase to force a fresh run.
set +e; umask 022
cfg=${1:?site config (cassis_siteName.conf)}
fromStage=${2:?fromStage (0..8)}
toStage=${3:?toStage (0..8)}
tagBase=${4:?tagBase (pass output tag base, e.g. runTag; fresh value forces a fresh pass1/pass2)}
B=${5:?work base dir, LAST}
# The ASP and ISIS tools must be on PATH and the projection/ISIS environment set
# up beforehand (activate a conda ASP environment, or use a packaged ASP build).
# See the repository README, Environment section.
cd "$B" || { echo "ERROR cannot cd $B"; exit 1; }

nick=$(basename "$cfg" .conf | sed 's/^cassis_//; s/_site$//')
[ -s "$B/cassis_common.conf" ] || { echo "ERROR missing cassis_common.conf"; exit 1; }
[ -s "$B/$cfg" ] || { echo "ERROR missing site config $cfg"; exit 1; }
source "$B/cassis_common.conf"
source "$B/$cfg"
matchpfx=${matchpfx:-$pairDir/frame/dense/matches/run-disp}
# DERIVED per-site paths (uniform conventions; not config knobs)
refitCamDir=$pairDir/frame/registered_cassis_cams     # stage-5 apply-distortion input + stage-6 dense cams (full names)

log=$B/output_${nick}_process_${fromStage}_${toStage}.txt; exec > "$log" 2>&1
echo "########## cassis_process START $(date) host=$(uname -n) nick=$nick stages $fromStage..$toStage ##########"
echo "  cfg=$cfg pairDir=$pairDir"
echo "  refdem=$refdem mapprojDem=$mapprojDem startCamDir=$startCamDir LL=$Llook RL=$Rlook"
echo "  optimized_distortion(c0)=$(echo $optimized_distortion | awk '{print $1}') refitPosUnc=$refitPosUnc num_matches_from_disp=$num_matches_from_disp denseGeounc=$denseGeounc geounc=$geounc"

# The heavy stages (5+) need a recent ASP. Require a build from 2026/7 or later
# (2026-07-10 is the build validated on CaSSIS). Older builds lack CaSSIS support.
if [ "$toStage" -ge 5 ]; then
  minAspBuild=20260710
  aspBuild=$(parallel_stereo --version 2>/dev/null | awk '/Build date:/ {gsub(/-/,"",$3); print $3; exit}')
  if [ -z "$aspBuild" ]; then
    echo "ERROR: cannot read the ASP build date. Is ASP on PATH? Try: parallel_stereo --version"; exit 1
  fi
  if [ "$aspBuild" -lt "$minAspBuild" ]; then
    echo "ERROR: ASP build $aspBuild is older than the required $minAspBuild (2026/7). CaSSIS needs a newer ASP."; exit 1
  fi
  echo "  ASP build $aspBuild (>= $minAspBuild required)"
fi

want(){ [ "$1" -ge "$fromStage" ] && [ "$1" -le "$toStage" ]; }   # run stage $1 ?
t0all=$(date +%s)
stage_hdr(){ echo ""; echo "===== STAGE $1 [$2] START $(date) ====="; }
stage_done(){ echo "===== STAGE $1 DONE $(date) (elapsed $(( $(date +%s) - $3 ))s) ====="; }

# ============================ STAGES 0-4: PREP (prep host; not a batch job) ============================
# These call the existing per-site prep scripts. They are gated by fromStage/toStage. For a site
# whose prep is on disk, run the master from stage 5 and these never fire. If a HEAVY stage below
# needs a PREP output that is missing, it hard-errors telling you to run the prep stage on the prep host.
if want 0; then
  stage_hdr 0 "CTX build (prep)"; t=$(date +%s)
  if [ -s "$refdem" ] && [ -s "$mapprojDem" ]; then echo "  refdem+mapprojDem exist - skip ($refdem)";
  else echo "  PREP: build CTX with cassis_ctx_build.sh on the prep host, then set refdem/mapprojDem in $cfg"; fi
  stage_done 0 "CTX build" "$t"
fi
if want 1; then
  stage_hdr 1 "linescan DEM (prep)"; t=$(date +%s)
  echo "  PREP: cassis_linescan_dem.sh $nick on the prep host (needs SPICE kernels). Output linescan/linescan_dem/stereo/dem-DEM.tif"
  stage_done 1 "linescan DEM" "$t"
fi
if want 2; then
  stage_hdr 2 "align linescan->CTX (prep)"; t=$(date +%s)
  if [ -s "$linescanDEM" ]; then echo "  aligned linescan DEM exists - skip ($linescanDEM)";
  else echo "  PREP: cassis_align_cams.sh on the prep host, using the stage-1 transform -> cams_aligned states"; fi
  stage_done 2 "align ls->CTX" "$t"
fi
if want 3; then
  stage_hdr 3 "aligned framelets (prep)"; t=$(date +%s)
  if [ -d "$pairDir/frame/aligned_framelets" ]; then echo "  aligned framelets exist - skip ($pairDir/frame/aligned_framelets)";
  else echo "  PREP: linescan2framelets.sh on the prep host -> frame/aligned_framelets"; fi
  stage_done 3 "aligned framelets" "$t"
fi
if want 4; then
  stage_hdr 4 "refit lens -> transverse (prep)"; t=$(date +%s)
  n4=$(ls "$refitCamDir"/*.json 2>/dev/null | wc -l | tr -d ' ')
  if [ "${n4:-0}" -ge 2 ]; then echo "  registered_cassis_cams has $n4 cams - skip";
  else echo "  PREP: refit_transverse.sh on the prep host -> $refitCamDir"; fi
  stage_done 4 "refit transverse" "$t"
fi

# ============================ STAGE 5: apply optimized distortion + refit pose (heavy) ============================
if want 5; then
  stage_hdr 5 "apply optimized distortion + refit pose"; t=$(date +%s)
  [ -d "$refitCamDir" ] || { echo "STAGE5_FAIL missing $refitCamDir - run prep stage 4 on the prep host"; exit 1; }
  [ -s "$refdem" ] || { echo "STAGE5_FAIL missing refdem $refdem - run prep stage 0"; exit 1; }
  nref=$(ls "$refitCamDir"/*.json 2>/dev/null | wc -l | tr -d ' ')
  [ "${nref:-0}" -ge 2 ] || { echo "STAGE5_FAIL too few refit cams ($nref) in $refitCamDir"; exit 1; }
  mkdir -p "$startCamDir"
  NCORE=$( (nproc 2>/dev/null) || echo 28); K=$(( NCORE > 2 ? NCORE : 2 ))
  echo "  applying optimized distortion to $nref cams (K=$K concurrent) refdem=$refdem posUnc=$refitPosUnc pix=$refitPixSamples"
  set +e; i=0; done5=0
  for cam in "$refitCamDir"/*.json; do
    [ -e "$cam" ] || continue
    stem=$(basename "$cam" .json)
    out5="$startCamDir/$stem.json"
    [ -s "$out5" ] && { done5=$((done5+1)); continue; }   # resume: skip already-built
    cub=$(ls data/$pairDir/L*/$stem.cub 2>/dev/null | head -1)
    [ -s "$cub" ] || { echo "  MISS cub $stem"; continue; }
    cam_gen "$cub" --input-camera "$cam" --csm-refit-pose --distortion-type transverse \
      --distortion "$optimized_distortion" --camera-position-uncertainty "$refitPosUnc" --reference-dem "$refdem" \
      --datum "$refitDatum" --num-pixel-samples "$refitPixSamples" -o "$out5" > "$out5.camgen.log" 2>&1 &
    i=$((i+1)); [ $((i % K)) -eq 0 ] && wait
  done
  wait; set -e
  n5=$(ls "$startCamDir"/*.json 2>/dev/null | wc -l | tr -d ' ')
  echo "  start cams now: $n5 of $nref (already-done skipped: $done5)"
  [ "${n5:-0}" -ge 2 ] || { echo "STAGE5_FAIL too few start cams ($n5)"; exit 1; }
  # sanity: c0 of a start cam must be the optimized-distortion c0 (~ -10.8048)
  c0=$(tail -n +2 "$(ls $startCamDir/*.json | head -1)" | python3 -c "import sys,json;print('%.4f'%json.load(sys.stdin).get('m_opticalDistCoeffs',[0])[0])" 2>/dev/null)
  echo "  start-cam c0=$c0 (want -10.8048)"
  case "$c0" in -10.8*) : ;; *) echo "STAGE5_FAIL c0 wrong ($c0)"; exit 1 ;; esac
  stage_done 5 "apply distortion" "$t"
fi

# ============================ STAGE 6: dense matches (heavy) ============================
if want 6; then
  stage_hdr 6 "dense matches"; t=$(date +%s)
  nm=$(ls "$B"/$matchpfx-*.match 2>/dev/null | wc -l | tr -d ' ')
  if [ "$num_matches_from_disp" = 0 ]; then
    echo "  num_matches_from_disp=0 -> SKIP dense generation (config says do not generate matches)"
  elif [ "${nm:-0}" -ge 2 ]; then
    echo "  matches already present ($nm at $matchpfx-*.match) - skip regen (delete to force)"
  else
    echo "  generating dense matches via cassis_stereo.sh DENSE MODE (num_matches_from_disp=$num_matches_from_disp, collar geounc=$denseGeounc)"
    [ -d "$refitCamDir" ] || { echo "STAGE6_FAIL missing $refitCamDir - run prep stage 4"; exit 1; }
    # 1-1 img/cam lists from the transverse refit cams (full names)
    dimg=$pairDir/frame/dense_images.txt; dcam=$pairDir/frame/dense_cameras.txt; : > "$dimg"; : > "$dcam"
    for camf in "$refitCamDir"/*.json; do
      [ -e "$camf" ] || continue; stem=$(basename "$camf" .json)
      cub=$(ls data/$pairDir/L*/$stem.cub 2>/dev/null | head -1)
      [ -s "$cub" ] || { echo "  MISS cub $stem"; continue; }
      echo "$cub" >> "$dimg"; echo "$camf" >> "$dcam"
    done
    # dense mode: geounc is the PRE-BA collar (denseGeounc), NOT the DEM geounc=0
    bash cassis_stereo.sh "$pairDir" "${nick}_dense" "$dimg" "$dcam" "$denseGeounc" "$mapprojDem" "$refdem" \
      "$mapprojRes" "$demRes" "$matchpfx" "$Llook" "$Rlook" "$num_matches_from_disp" "$B" \
      || { echo "STAGE6_FAIL dense (see output_${nick}_dense_stereo.txt)"; exit 1; }
    nm=$(ls "$B"/$matchpfx-*.match 2>/dev/null | wc -l | tr -d ' ')
  fi
  echo "  dense match files: ${nm:-0}"
  stage_done 6 "dense matches" "$t"
fi

# ============================ STAGE 7: pass1 (heavy) ============================
if want 7; then
  stage_hdr 7 "pass1"; t=$(date +%s)
  p1dem=$pairDir/frame/${nick}_${tagBase}1_stereo/cassis_dem.tif
  if [ -s "$p1dem" ]; then echo "  pass1 DEM exists - skip ($p1dem)";
  else
    bash cassis_run.sh "$cfg" pass1 "$tagBase" "$B" || { echo "STAGE7_FAIL pass1"; exit 1; }
  fi
  [ -s "$p1dem" ] || { echo "STAGE7_FAIL pass1 no DEM $p1dem"; exit 1; }
  echo "  pass1 DEM: $p1dem"
  stage_done 7 "pass1" "$t"
fi

# ============================ STAGE 8: pass2 -> FINAL DEM (heavy) ============================
if want 8; then
  stage_hdr 8 "pass2 (FINAL)"; t=$(date +%s)
  p2dem=$pairDir/frame/${nick}_${tagBase}2_stereo/cassis_dem.tif
  if [ -s "$p2dem" ]; then echo "  pass2 DEM exists - skip ($p2dem)";
  else
    bash cassis_run.sh "$cfg" pass2 "$tagBase" "$B" || { echo "STAGE8_FAIL pass2"; exit 1; }
  fi
  [ -s "$p2dem" ] || { echo "STAGE8_FAIL pass2 no DEM $p2dem"; exit 1; }
  echo "  FINAL DEM: $p2dem"
  echo "  FINAL DEM on_ctx: ${p2dem%.tif}_on_ctx.tif"
  stage_done 8 "pass2" "$t"
fi

echo ""
echo "########## cassis_process DONE $(date) (total elapsed $(( $(date +%s) - t0all ))s) stages $fromStage..$toStage ##########"
echo "CASSIS_PROCESS_DONE $nick $fromStage $toStage"
