#!/bin/bash
# Apply the stage-1 pc_align transform to the bundle-adjusted linescan camera states, producing
# the CTX-aligned linescan states. Config-driven: reads pairDir + Llook/Rlook and derives the
# transform path (written by stage 1) by convention.
# Usage: cassis_align_cams.sh <site.conf> <workdir>
set -e
umask 022
# ASP/ISIS tools on PATH and the environment are set up by the caller. See the README.
cfg=${1:?usage: cassis_align_cams.sh <site.conf> <workdir>}
B=${2:?workdir}
cd "$B" || { echo "ERROR cannot cd $B"; exit 1; }
[ -s "$B/cassis_common.conf" ] && source "$B/cassis_common.conf"
[ -s "$B/$cfg" ] || { echo "ERROR missing site config $cfg"; exit 1; }
source "$B/$cfg"
L=$Llook; R=$Rlook
T=$pairDir/linescan/linescan_dem/align/run-transform.txt          # derived: written by stage 1
Ls=$pairDir/linescan/${L}_strip.tif; Rs=$pairDir/linescan/${R}_strip.tif
sL=$pairDir/linescan/linescan_dem/ba/run-${L}_linescan.adjusted_state.json
sR=$pairDir/linescan/linescan_dem/ba/run-${R}_linescan.adjusted_state.json
out=$pairDir/linescan/linescan_dem/cams_aligned
# Idempotent: if the aligned camera states already exist, there is nothing to do.
if ls "$out"/run-*adjusted_state.json >/dev/null 2>&1; then
  echo "aligned camera states exist, skipping: $out"
  exit 0
fi
for f in "$Ls" "$Rs" "$sL" "$sR" "$T"; do [ -s "$f" ] || { echo "MISSING $f"; exit 1; }; done
mkdir -p "$out"
echo "=== apply $T to linescan cams ==="
bundle_adjust "$Ls" "$Rs" "$sL" "$sR" \
  --initial-transform "$T" --apply-initial-transform-only \
  --inline-adjustments -o "$out/run" > "$out/log.txt" 2>&1 \
  || { echo "FAILED"; tail -20 "$out/log.txt"; exit 1; }
echo "DONE -> $out/run-*adjusted_state.json"; ls "$out"/run-*adjusted_state.json
