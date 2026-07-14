#!/bin/bash
# cassis_build_sl.sh - GENERIC sl/ short-name farm (the .match hash-trap defense). Symlinks
# frame/sl/L<k>.{cub,json} (k = framelet index) -> the canonical framelet cube (data/) + its TRANSVERSE
# refit cam (frame/sl_refit_full/<stem>.json). Built ONCE. $PWD-absolute targets to the canonical files
# (no run-dir indirection).
#   Args: $1 pairDir  $2 dataDir  $3 sidL  $4 sidR  $5 camDir(full-name transverse cams, frame/sl_refit_full)
set -e
# Run this from your work directory. See the repository README.
P=$1; DATA=$2; sidL=$3; sidR=$4; CAM=$5
[ -n "$CAM" ] || { echo "usage: cassis_build_sl.sh pairDir dataDir sidL sidR camDir"; exit 1; }
sl=$P/frame/sl; mkdir -p "$sl"
for spec in L:$sidL R:$sidR; do
  lab=${spec%:*}; sid=${spec#*:}
  for cub in $DATA/L*_$sid/*-$sid-*-0__4_0.cub; do
    [ -e "$cub" ] || continue
    stem=$(basename "$cub" .cub)
    k=$(echo "$stem" | sed -n "s/.*-$sid-\([0-9]\{1,\}\)-0__4_0/\1/p")
    cam="$CAM/$stem.json"
    [ -s "$cam" ] || { echo "MISSING cam $cam"; continue; }
    ln -sf "$PWD/$cub" "$sl/$lab$k.cub"
    ln -sf "$PWD/$cam" "$sl/$lab$k.json"
  done
done
echo "sl/ entries: $(ls "$sl"/ | wc -l)  (.cub $(ls "$sl"/*.cub 2>/dev/null|wc -l) + .json $(ls "$sl"/*.json 2>/dev/null|wc -l))"
echo "CASSIS_BUILD_SL_DONE $sl"
