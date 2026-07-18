#!/bin/bash
# cassis_process.sh - the SINGLE end-to-end CaSSIS pipeline, from original inputs to the FINAL DEM.
# Config-driven (sources cassis_common.conf + a per-site cassis_siteName.conf), RESUMABLE by
# stage number, and TIMED (every heavy stage prints START/DONE + elapsed via `date`). No figures.
#
# This script is TIER 2, DATA PROCESSING: the automated stages that turn the ingested cubes and cameras
# and the CTX reference into the final DEM. They run with little user input, usually on a remote/compute
# machine (a batch job). TIER 1, DATA INGESTION (fetch framelets, download kernels, ingest to cubes,
# make cameras, build the CTX reference DEM, and make the blurred mapproj DEM) is done first, on a local
# machine, with network access and inspection. Tier 1 is not part of this script (see the README).
#
# STAGES (run stage k iff fromStage <= k <= toStage; each skips cheaply if its output already exists):
#   1  linescan DEM               cassis_linescan_dem.sh   -> ls stereo DEM
#   2  align linescan -> CTX      cassis_align_cams.sh     -> cams_aligned states
#   3  aligned framelets         linescan2framelets.sh    -> frame/aligned_framelets
#   4  refit lens -> transverse   refit_transverse.sh      -> registered_cassis_cams
#   5  apply optimized distortion + refit pose (cam_gen loop)          -> startCamDir
#   6  dense matches                                       -> matchpfx*.match
#   7  pass1  (cassis_run.sh pass1)                        -> pass1 DEM
#   8  pass2  (cassis_run.sh pass2)                        -> FINAL DEM
#
# All inputs (cubs, cameras, refDem, mapprojDem) come from Tier 1 and are named in the site config.
# The final delivered DEM = <outDir>/frame/pass2_stereo/cassis_dem.tif (+ _on_ctx.tif).
#
# Usage:  cassis_process.sh <site.conf> <fromStage> <toStage> <outDir> <B>
#   e.g.  cassis_process.sh cassis_ox1.conf 1 8 ox1_out /path/to/workdir
#   fromStage..toStage is the stage range to run (1..8). outDir is where ALL outputs go (any path,
#   relative to the workdir or absolute; changes per run). Reuse an existing outDir to RESUME (each
#   stage skips if its output exists); use a fresh outDir for a clean run.
set +e; umask 022
# Make the sibling pipeline scripts (cassis_stereo.sh, cassis_run.sh, cassis_pass.sh, ...)
# findable no matter how this master is invoked, and whether or not the caller put
# CassisPipeline/bin on PATH: prepend this script's own directory. It is exported, so the
# child scripts this launches inherit it and can find their own siblings too. The ASP and
# ISIS tools must still be on PATH separately (see the README Environment section).
selfBin=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
[ -n "$selfBin" ] && export PATH="$selfBin:$PATH"
cfg=${1:?site config (cassis_siteName.conf)}
fromStage=${2:?fromStage (1..8)}
toStage=${3:?toStage (1..8)}
outDir=${4:?outDir (output dir, relative to workdir or absolute; changes per run)}
B=${5:?work base dir, LAST}
# Stages start at 1. The CTX reference DEM and the blurred mapproj DEM are Tier-1 setup
# (see the README), not stages here.
[ "$fromStage" -ge 1 ] 2>/dev/null || { echo "ERROR fromStage must be >= 1 (CTX build / mapproj DEM are Tier-1 setup, not stages)"; exit 1; }
# The ASP and ISIS tools must be on PATH and the projection/ISIS environment set
# up beforehand (activate a conda ASP environment, or use a packaged ASP build).
# See the repository README, Environment section.
cd "$B" || { echo "ERROR cannot cd $B"; exit 1; }

nick=$(basename "$cfg" .conf | sed 's/^cassis_//; s/_site$//')
[ -s "$B/cassis_common.conf" ] || { echo "ERROR missing cassis_common.conf"; exit 1; }
[ -s "$B/$cfg" ] || { echo "ERROR missing site config $cfg"; exit 1; }
source "$B/cassis_common.conf"
source "$B/$cfg"
source cassis_env_check.sh
matchpfx=${matchpfx:-$outDir/frame/dense/matches/run-disp}
# DERIVED output paths (uniform conventions; not config knobs). All outputs live under outDir.
refitCamDir=$outDir/frame/registered_cassis_cams     # stage-5 apply-distortion input + stage-6 dense cams (full names)
startCamDir=${startCamDir:-$outDir/frame/distortion_corrected_cassis_cams}   # stage-5 output start cams
linescanDem=${linescanDem:-$outDir/linescan/linescan_dem/align/aligned_oncoarse.tif}  # stage-1 aligned linescan DEM

# Pre-flight: fail early (before the long run) if the config inputs or required tools are missing.
if [ "$toStage" -ge 1 ]; then
  # refDem and mapprojDem are Tier-1 inputs named in the site config; both must exist.
  [ -s "$refDem" ] || { echo "ERROR refDem not found: $refDem (a Tier-1 input; check the site config)"; exit 1; }
  [ -s "$mapprojDem" ] || { echo "ERROR mapprojDem not found: $mapprojDem (the blurred CTX DEM, a Tier-1 input; check the site config)"; exit 1; }
  nL=$(cassis_look_cubs "$inputCassisDir" "$Llook" | wc -l | tr -d ' ')
  nR=$(cassis_look_cubs "$inputCassisDir" "$Rlook" | wc -l | tr -d ' ')
  [ "${nL:-0}" -ge 1 ] || { echo "ERROR no cubs for Llook=$Llook under inputCassisDir=$inputCassisDir"; exit 1; }
  [ "${nR:-0}" -ge 1 ] || { echo "ERROR no cubs for Rlook=$Rlook under inputCassisDir=$inputCassisDir"; exit 1; }
fi
[ "$toStage" -ge 5 ] && cassis_require bundle_adjust parallel_stereo point2dem mapproject dem_mosaic geodiff gdalwarp gdalinfo gdal_translate cam_gen

log=$B/output_${nick}_process_${fromStage}_${toStage}.txt; exec > "$log" 2>&1
echo "########## cassis_process START $(date) host=$(uname -n) nick=$nick stages $fromStage..$toStage ##########"
echo "  cfg=$cfg outDir=$outDir"
echo "  refDem=$refDem mapprojDem=$mapprojDem startCamDir=$startCamDir LL=$Llook RL=$Rlook"
echo "  optimized_distortion(c0)=$(echo $optimized_distortion | awk '{print $1}') refitPosUnc=$refitPosUnc num_matches_from_disp=$num_matches_from_disp denseGeounc=$denseGeounc geounc=$geounc"

# The heavy stages (5+) need a recent, CaSSIS-capable ASP, guarded by build date. Date is the
# guard on purpose: a feature probe is too subtle (a feature can be present yet lack the latest
# fix), and the plan is to keep pushing this floor forward as fixes land. The date is parsed from
# `parallel_stereo --version` "Build date: YYYY-MM-DD", dashes stripped to a YYYYMMDD integer, so
# the comparison stays correct across month and YEAR rollovers (a 2027+ build is a larger integer
# than any 2026 floor).
# 2026-07-17: floor set to 20260717, the fresh CaSSIS-capable ASP build. (History: was 20260710;
# briefly relaxed to 20260708 on 2026-07-16 when an l1 respin redeployed a build stamping 07-08,
# since build date is not monotonic with content; the fresh 2026-07-17 build supersedes it.)
if [ "$toStage" -ge 5 ]; then
  minAspBuild=20260717   # the fresh CaSSIS-capable ASP build; keep pushing forward as fixes land
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

# ============================ STAGES 1-8: TIER 2 DATA PROCESSING ============================
# Each stage runs its script and skips cheaply if its output already exists. All inputs (cubs, cameras,
# refDem, mapprojDem) come from Tier 1 (fetch/ingest/cameras + CTX build + the blurred mapproj DEM; see
# the README). CTX build and the blurred mapproj DEM are Tier-1 setup, not stages here.
if want 1; then
  stage_hdr 1 "linescan DEM"; t=$(date +%s)
  if [ -s "$linescanDem" ]; then echo "  linescan DEM exists - skip ($linescanDem)";
  else bash "$selfBin/cassis_linescan_dem.sh" "$cfg" "$outDir" "$B" || { echo "STAGE1_FAIL linescan DEM"; exit 1; }; fi
  stage_done 1 "linescan DEM" "$t"
fi
if want 2; then
  stage_hdr 2 "align linescan->CTX"; t=$(date +%s)
  if ls "$outDir"/linescan/linescan_dem/cams_aligned/run-*adjusted_state.json >/dev/null 2>&1; then echo "  aligned cam states exist - skip";
  else bash "$selfBin/cassis_align_cams.sh" "$cfg" "$outDir" "$B" || { echo "STAGE2_FAIL align"; exit 1; }; fi
  stage_done 2 "align ls->CTX" "$t"
fi
if want 3; then
  stage_hdr 3 "aligned framelets"; t=$(date +%s)
  if ls "$outDir"/frame/aligned_framelets/*/aligned-*.json >/dev/null 2>&1; then echo "  aligned framelets exist - skip";
  else bash "$selfBin/linescan2framelets.sh" "$cfg" "$outDir" "$B" || { echo "STAGE3_FAIL framelets"; exit 1; }; fi
  stage_done 3 "aligned framelets" "$t"
fi
if want 4; then
  stage_hdr 4 "refit lens -> transverse"; t=$(date +%s)
  n4=$(ls "$refitCamDir"/*.json 2>/dev/null | wc -l | tr -d ' ')
  if [ "${n4:-0}" -ge 2 ]; then echo "  registered_cassis_cams has $n4 cams - skip";
  else bash "$selfBin/refit_transverse.sh" "$cfg" "$outDir" "$B" || { echo "STAGE4_FAIL refit"; exit 1; }; fi
  stage_done 4 "refit transverse" "$t"
fi

# ============================ STAGE 5: apply optimized distortion + refit pose (heavy) ============================
if want 5; then
  stage_hdr 5 "apply optimized distortion + refit pose"; t=$(date +%s)
  [ -d "$refitCamDir" ] || { echo "STAGE5_FAIL missing $refitCamDir - run stage 4 first"; exit 1; }
  [ -s "$refDem" ] || { echo "STAGE5_FAIL missing refDem $refDem - a Tier-1 input; check the site config"; exit 1; }
  nref=$(ls "$refitCamDir"/*.json 2>/dev/null | wc -l | tr -d ' ')
  [ "${nref:-0}" -ge 2 ] || { echo "STAGE5_FAIL too few refit cams ($nref) in $refitCamDir"; exit 1; }
  mkdir -p "$startCamDir"
  # core count: prefer $PBS_NODEFILE (bare nproc can return 1 inside a PBS job), then nproc --all.
  NCORE=$( { [ -r "$PBS_NODEFILE" ] && wc -l < "$PBS_NODEFILE"; } 2>/dev/null || nproc --all 2>/dev/null || echo 28 )
  case "$NCORE" in ''|*[!0-9]*) NCORE=28 ;; esac
  K=$(( NCORE > 2 ? NCORE : 2 ))
  echo "  applying optimized distortion to $nref cams (K=$K concurrent) refDem=$refDem posUnc=$refitPosUnc pix=$refitPixSamples"
  set +e; i=0; done5=0
  for cam in "$refitCamDir"/*.json; do
    [ -e "$cam" ] || continue
    stem=$(basename "$cam" .json)
    out5="$startCamDir/$stem.json"
    [ -s "$out5" ] && { done5=$((done5+1)); continue; }   # resume: skip already-built
    cub=$(cassis_cub_for_stem "$inputCassisDir" "$stem")
    [ -s "$cub" ] || { echo "  MISS cub $stem"; continue; }
    cam_gen "$cub" --input-camera "$cam" --csm-refit-pose --distortion-type transverse \
      --distortion "$optimized_distortion" --camera-position-uncertainty "$refitPosUnc" --reference-dem "$refDem" \
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
    dimg=$outDir/frame/dense_images.txt; dcam=$outDir/frame/dense_cameras.txt; : > "$dimg"; : > "$dcam"
    for camf in "$refitCamDir"/*.json; do
      [ -e "$camf" ] || continue; stem=$(basename "$camf" .json)
      cub=$(cassis_cub_for_stem "$inputCassisDir" "$stem")
      [ -s "$cub" ] || { echo "  MISS cub $stem"; continue; }
      echo "$cub" >> "$dimg"; echo "$camf" >> "$dcam"
    done
    # dense mode: geounc is the PRE-BA collar (denseGeounc), NOT the DEM geounc=0
    bash "$selfBin/cassis_stereo.sh" "$outDir" "${nick}_dense" "$dimg" "$dcam" "$denseGeounc" "$mapprojDem" "$refDem" \
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
  p1dem=$outDir/frame/pass1_stereo/cassis_dem.tif
  if [ -s "$p1dem" ]; then echo "  pass1 DEM exists - skip ($p1dem)";
  else
    bash "$selfBin/cassis_run.sh" "$cfg" pass1 "$outDir" "$B" || { echo "STAGE7_FAIL pass1"; exit 1; }
  fi
  [ -s "$p1dem" ] || { echo "STAGE7_FAIL pass1 no DEM $p1dem"; exit 1; }
  echo "  pass1 DEM: $p1dem"
  stage_done 7 "pass1" "$t"
fi

# ============================ STAGE 8: pass2 -> FINAL DEM (heavy) ============================
if want 8; then
  stage_hdr 8 "pass2 (FINAL)"; t=$(date +%s)
  p2dem=$outDir/frame/pass2_stereo/cassis_dem.tif
  if [ -s "$p2dem" ]; then echo "  pass2 DEM exists - skip ($p2dem)";
  else
    bash "$selfBin/cassis_run.sh" "$cfg" pass2 "$outDir" "$B" || { echo "STAGE8_FAIL pass2"; exit 1; }
  fi
  [ -s "$p2dem" ] || { echo "STAGE8_FAIL pass2 no DEM $p2dem"; exit 1; }
  echo "  FINAL DEM: $p2dem"
  echo "  FINAL DEM on_ctx: ${p2dem%.tif}_on_ctx.tif"
  stage_done 8 "pass2" "$t"
fi

echo ""
echo "########## cassis_process DONE $(date) (total elapsed $(( $(date +%s) - t0all ))s) stages $fromStage..$toStage ##########"
echo "CASSIS_PROCESS_DONE $nick $fromStage $toStage"
