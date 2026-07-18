#!/bin/bash
# cassis_make_cameras.sh - create a CSM camera model (.json) for each CaSSIS
# framelet cube, with isd_generate.
#
# One cube in, one camera file out, next to the cube. Requires:
#   - a full ISISDATA (base + tgo, including the ESA CaSSIS metakernel),
#   - the CaSSIS-capable ALE and USGSCSM (the environment described in the README),
#   - ISISDATA and ALESPICEROOT set by the caller.
# No spiceinit. Runs one cube at a time (light, no download). Idempotent: a cube
# that already has a .json is skipped, so a re-run only fills in what is missing.
#
# Usage: cassis_make_cameras.sh <site data root>
#   The site data root holds the per-look subdirectories L*_*, each with .cub files.

SITE=${1:?usage: cassis_make_cameras.sh <site data root>}

# Use the ACTIVE conda env's own isd_generate (via CONDA_PREFIX), never one that happens to be first
# on PATH: ASP ships an older isd_generate, and switching envs does not always update PATH, but
# CONDA_PREFIX is reliable. isd_generate comes from ALE; the usgscsm_cassis env has the CaSSIS-capable
# ALE. See the README Environment section.
# find our sibling scripts whether we were invoked by path or via PATH (bare name)
_bin=$(cd "$(dirname "$0")" 2>/dev/null && pwd); case "$0" in */*) : ;; *) _bin=$(cd "$(dirname "$(command -v "$0")")" 2>/dev/null && pwd) ;; esac
source "$_bin/cassis_env_check.sh"
cassis_require_ale
ISD="$CONDA_PREFIX/bin/isd_generate"

n=0; ok=0; miss=0
for look in "$SITE"/L*_*/; do
  [ -d "$look" ] || continue
  for cub in "$look"*.cub; do
    [ -e "$cub" ] || continue
    n=$((n + 1))
    json="${cub%.cub}.json"
    if [ -s "$json" ]; then ok=$((ok + 1)); continue; fi
    "$ISD" -n -o "$json" "$cub"
    if [ -s "$json" ]; then
      ok=$((ok + 1))
    else
      echo "MISSING json $(basename "$cub") (if this persists, check the ALE version has CaSSIS support)"
      miss=$((miss + 1))
    fi
  done
done
echo "CASSIS_CAMERAS_DONE site=$SITE cameras=$ok missing=$miss cubes=$n"
