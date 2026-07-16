#!/bin/bash
# Apply the PHASE 0 pc_align transform to the BA-tied linescan camera states ->
# CTX-aligned linescan states.
# Usage: cassis_align_cams.sh <pairDir> <sidL> <sidR> <transform.txt> [label]
#   pairDir       the site pair directory (holds linescan/)
#   sidL sidR     the left/right look sequence identifiers
#   transform.txt the pc_align run-transform.txt from cassis_linescan_dem.sh
set -e
# ASP/ISIS tools on PATH and environment (ISIS kernels) are set up by the caller.
# Run this from your work directory. See the repository README.
W=${1:?usage: cassis_align_cams.sh <pairDir> <sidL> <sidR> <transform.txt> [label]}
L=${2:?sidL}; R=${3:?sidR}
T=${4:?transform (the pc_align run-transform.txt from cassis_linescan_dem.sh)}
label=${5:-$W}
Ls=$W/linescan/${L}_strip.tif; Rs=$W/linescan/${R}_strip.tif
sL=$W/linescan/linescan_dem/ba/run-${L}_linescan.adjusted_state.json
sR=$W/linescan/linescan_dem/ba/run-${R}_linescan.adjusted_state.json
out=$W/linescan/linescan_dem/cams_aligned
for f in "$Ls" "$Rs" "$sL" "$sR" "$T"; do [ -s "$f" ] || { echo "MISSING $f"; exit 1; }; done
mkdir -p "$out"
echo "=== apply $T to linescan cams [$label] ==="
bundle_adjust "$Ls" "$Rs" "$sL" "$sR" \
  --initial-transform "$T" --apply-initial-transform-only \
  --inline-adjustments -o "$out/run" > "$out/log.txt" 2>&1 \
  || { echo "FAILED"; tail -20 "$out/log.txt"; exit 1; }
echo "DONE -> $out/run-*adjusted_state.json"; ls "$out"/run-*adjusted_state.json
