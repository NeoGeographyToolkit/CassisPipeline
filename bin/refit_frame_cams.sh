#!/bin/bash
# refit_frame_cams.sh - build refit per-framelet FRAME cameras (transverse lens + refit
# pose) straight from the RAW framelet cubes, BEFORE any linescan or CTX alignment. Used
# only by the refitBeforeLinescan reorder: it moves the optimized transverse lens up front
# so the linescan is assembled from the refit cameras. The output cams are consumed by
# linescan_refit_lens.py (to build the refit linescan) and by linescan2framelets.sh (stage
# 3 pose-swap), so stages 4-5 (the old late refit) are not needed.
#
# This combines the two existing operations: the 0-iteration bundle_adjust that turns the
# framelet cubes + ISDs into raw frame CSM states (as in linescan2framelets.sh), and the
# stage-5 cam_gen --csm-refit-pose --distortion-type transverse call (as in
# cassis_process.sh stage 5). Native-CaSSIS (type 9) -> transverse (type 1).
#
# Config-driven: reads inputCassisDir, Llook/Rlook, optimized_distortion, refitPosUnc,
# refitPixSamples, refitDatum, refDem. Does both looks in one call.
# Usage: refit_frame_cams.sh <site.conf> <outDir> <workdir>
set -e
umask 022
# ASP/ISIS tools on PATH and the environment are set up by the caller. See the README.
selfBin=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
cfg=${1:?usage: refit_frame_cams.sh <site.conf> <outDir> <workdir>}
outDir=${2:?outDir (output dir, relative to workdir or absolute)}
B=${3:?workdir}
cd "$B" || { echo "ERROR cannot cd $B"; exit 1; }
[ -s "$B/cassis_common.conf" ] && source "$B/cassis_common.conf"
[ -s "$B/$cfg" ] || { echo "ERROR missing site config $cfg"; exit 1; }
source "$B/$cfg"
source "$selfBin/cassis_env_check.sh"
cassis_require bundle_adjust cam_gen
[ -s "$refDem" ] || { echo "ERROR missing reference CTX (refDem) $refDem"; exit 1; }
[ -n "$optimized_distortion" ] || { echo "ERROR optimized_distortion unset (cassis_common.conf)"; exit 1; }

out_dir=$outDir/frame/refit_frame_cams_prelink
# Idempotent: skip if the refit cams already exist.
nout=$(ls "$out_dir"/*.json 2>/dev/null | grep -v adjusted_state | wc -l | tr -d ' ')
if [ "${nout:-0}" -ge 2 ]; then
  echo "refit frame cams exist ($nout), skipping: $out_dir"; exit 0
fi
mkdir -p "$out_dir"

# core count for the cam_gen fan-out (same knobs as cassis_process.sh stage 5)
NCORE=$( { [ -r "$PBS_NODEFILE" ] && wc -l < "$PBS_NODEFILE"; } 2>/dev/null || nproc --all 2>/dev/null || echo 28 )
case "$NCORE" in ''|*[!0-9]*) NCORE=28 ;; esac
K=$(( NCORE > 2 ? NCORE : 2 ))
[ -n "$CASSIS_MAX_JOBS" ] && case "$CASSIS_MAX_JOBS" in ''|*[!0-9]*) : ;; *) [ "$CASSIS_MAX_JOBS" -lt "$K" ] && K=$CASSIS_MAX_JOBS ;; esac

for entry in "L $Llook" "R $Rlook"; do
  set -- $entry; look=$1; sid=$2
  raw=$out_dir/raw_$sid
  mkdir -p "$raw"
  # framelet cubes (drop 0-valid-pixel dropouts, as linescan2framelets.sh does) + ISDs
  all_cubes=$(cassis_look_cubs "$inputCassisDir" "$sid")
  cubes=$(python3 - "$all_cubes" <<'PY'
import sys
from osgeo import gdal
import numpy as np
gdal.DontUseExceptions()
for c in sys.argv[1].split():
    d = gdal.Open(c)
    if d is not None:
        a = d.GetRasterBand(1).ReadAsArray()
        if np.any(a > -1e30):
            print(c)
PY
)
  nc=$(echo "$cubes" | grep -c .)
  isds=$(for c in $cubes; do echo ${c%.cub}.json; done)
  echo "[refit_frame_cams $look $sid] $nc valid framelet cubes"

  echo "[refit_frame_cams $sid] 0-iter BA: framelet cubes -> raw frame CSM states"
  bundle_adjust $cubes $isds --inline-adjustments --num-iterations 0   \
    --overlap-limit 1 --min-matches 0 --ip-per-image 500 -o "$raw/raw" \
    > "$raw/ba0_log.txt" 2>&1 || { echo "0-iter BA failed; see $raw/ba0_log.txt"; tail -5 "$raw/ba0_log.txt"; exit 1; }

  echo "[refit_frame_cams $sid] cam_gen refit (transverse + pose), K=$K concurrent"
  set +e; i=0
  for rawcam in "$raw"/raw-*-${sid}-*-0__4_0.adjusted_state.json; do
    [ -e "$rawcam" ] || continue
    stem=$(basename "$rawcam" .adjusted_state.json); stem=${stem#raw-}
    out="$out_dir/$stem.json"
    [ -s "$out" ] && continue
    cub=$(cassis_cub_for_stem "$inputCassisDir" "$stem")
    [ -s "$cub" ] || { echo "  MISS cub $stem"; continue; }
    cam_gen "$cub" --input-camera "$rawcam" --csm-refit-pose --distortion-type transverse \
      --distortion "$optimized_distortion" --camera-position-uncertainty "$refitPosUnc"   \
      --reference-dem "$refDem" --datum "${refitDatum:-D_MARS}"                           \
      --num-pixel-samples "${refitPixSamples:-4000}" -o "$out" > "$out.camgen.log" 2>&1 &
    i=$((i+1)); [ $((i % K)) -eq 0 ] && wait
  done
  wait; set -e
done

nrefit=$(ls "$out_dir"/*.json 2>/dev/null | grep -v adjusted_state | wc -l | tr -d ' ')
echo "REFIT_FRAME_CAMS_DONE -> $out_dir ($nrefit cams)"
[ "${nrefit:-0}" -ge 2 ] || { echo "ERROR too few refit frame cams ($nrefit)"; exit 1; }
