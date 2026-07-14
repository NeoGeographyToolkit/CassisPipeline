#!/bin/bash
# cassis_isd_l1.sh - GENERIC NAIF-direct CSM ISD (.json) generation for CaSSIS framelet cubes.
# Generic (not site-hardcoded). RUNS ON l1 (or Mac).
# NO spiceinit. Env ale_cassis = cassis_support branch of ~/projects/ale (ALE 1.2.0 + CassisDistortion),
# ISOLATED env (NEVER asp_deps); emits ISD optical_distortion={'cassis':{...36...}} = CaSSIS type 9.
# isd_generate CLI does NOT work for CaSSIS (TGO NaifSpice driver not in its search); isd_gen.py
# (ale.loads only_naif_spice=True + per-OBS-DATE metakernel) DOES, on NON-spiceinit cubes. Build
# metakernels first (sequential, no races), then per-look ISD in parallel. Idempotent (skips cubes with
# a .json). NO `set -u` (conda hooks use unbound vars).
#   Arg: $1 = site data root (default data/MY34_004756_354_1); looks are its L*_* subdirs.
ISIS_ENV=${ISIS_ENV:-ale_cassis}
SITE=${1:-data/MY34_004756_354_1}
ROOT=${ROOT:-$HOME/projects/cassis_asp}
JOBS=${JOBS:-10}
CONDA=$HOME/anaconda3; [ -x "$HOME/miniconda3/bin/conda" ] && CONDA=$HOME/miniconda3
eval "$("$CONDA/bin/conda" shell.bash hook)"; conda activate "$ISIS_ENV"
export ISISDATA=$HOME/projects/isis3data
export ALESPICEROOT=$ISISDATA
cd "$ROOT" || exit 1
tag=$(echo "$SITE" | tr '/' '_'); TM=/tmp/cassis_tm_$tag; mkdir -p "$TM"

# 1. Build all per-date metakernels first (sequential, fast; avoids parallel races).
for look in $SITE/L*_*/; do
  cubes=( "$look"*.cub ); [ -e "${cubes[0]}" ] || continue
  d8=$(basename "${cubes[0]}" | grep -oE '[0-9]{8}' | head -1)
  tm=$TM/cas_${d8}.tm
  [ -s "$tm" ] || bash build_metakernel.sh "$tm" "$d8" >/dev/null 2>&1
done

# 2. Generate ISDs per look IN PARALLEL (each look independent; cap at $JOBS).
for look in $SITE/L*_*/; do
  cubes=( "$look"*.cub ); [ -e "${cubes[0]}" ] || continue
  d8=$(basename "${cubes[0]}" | grep -oE '[0-9]{8}' | head -1)
  tm=$TM/cas_${d8}.tm
  todo=(); for c in "${cubes[@]}"; do [ -s "${c%.cub}.json" ] || todo+=( "$c" ); done
  [ ${#todo[@]} -eq 0 ] && continue
  while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do wait -n; done
  echo "=== $look : ${#todo[@]} cubes, date $d8 ==="
  ( python isd_gen.py "$tm" "${todo[@]}" >/dev/null 2>&1 ) &
done
wait

# 3. Report.
ncub=$(find $SITE -name '*.cub' | wc -l | tr -d ' '); done=0; fail=0
for look in $SITE/L*_*/; do
  for c in "$look"*.cub; do [ -e "$c" ] || continue; [ -s "${c%.cub}.json" ] && done=$((done+1)) || { echo "MISSING json $(basename $c)"; fail=$((fail+1)); }; done
done
echo "CASSIS_ISD_DONE env=$ISIS_ENV site=$SITE json=$done missing=$fail total_json=$(find $SITE -name '*.json'|wc -l|tr -d ' ')/$ncub"
