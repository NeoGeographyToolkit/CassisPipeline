#!/bin/bash
# Apply the PHASE 0 pc_align transform to the BA-tied linescan camera states ->
# CTX-aligned linescan states.
# Usage: cassis_align_cams.sh <oxia1|oxia2|jezero>
set -e
CONDA=$HOME/anaconda3; [ -x "$HOME/miniconda3/bin/conda" ] && CONDA=$HOME/miniconda3
eval "$("$CONDA/bin/conda" shell.bash hook)"; conda activate asp_deps
export ISISROOT=$CONDA/envs/asp_deps ISISDATA=$HOME/projects/isis3data ALESPICEROOT=$HOME/projects/isis3data
export PATH=$HOME/projects/StereoPipeline/install/bin:$CONDA/envs/asp_deps/bin:$ISISROOT/bin:$PATH
cd ~/projects/cassis_asp
# GENERIC new-site path: if W/L/R/T are passed as env vars, use them and SKIP the case block.
if [ -n "$W" ] && [ -n "$L" ] && [ -n "$R" ] && [ -n "$T" ]; then
  :
else
case "$1" in
 oxia1)  W=oxia_planum/MY34_003806_019; L=276230221; R=276230222; T=$W/ls/ls_dem/align/run-transform.txt ;;
 oxia2)  W=oxia_planum/MY34_004172_162; L=276980361; R=276980362; T=$W/ls/ls_dem/align2/run-transform.txt ;;
 jezero) W=jezero/MY36_016378_162;      L=838849161; R=838849162; T=$W/ls/ls_dem/align/run-transform.txt ;;
 *) echo "usage: cassis_align_cams.sh <oxia1|oxia2|jezero>  OR set W/L/R/T env"; exit 2 ;;
esac
fi
Ls=$W/ls/${L}_strip.tif; Rs=$W/ls/${R}_strip.tif
sL=$W/ls/ls_dem/ba/run-${L}_linescan.adjusted_state.json
sR=$W/ls/ls_dem/ba/run-${R}_linescan.adjusted_state.json
out=$W/ls/ls_dem/cams_aligned
for f in "$Ls" "$Rs" "$sL" "$sR" "$T"; do [ -s "$f" ] || { echo "MISSING $f"; exit 1; }; done
mkdir -p "$out"
echo "=== apply $T to linescan cams [$1] ==="
bundle_adjust "$Ls" "$Rs" "$sL" "$sR" \
  --initial-transform "$T" --apply-initial-transform-only \
  --inline-adjustments -o "$out/run" > "$out/log.txt" 2>&1 \
  || { echo "FAILED"; tail -20 "$out/log.txt"; exit 1; }
echo "DONE -> $out/run-*adjusted_state.json"; ls "$out"/run-*adjusted_state.json
