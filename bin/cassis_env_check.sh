#!/bin/bash
# cassis_env_check.sh - shared environment sanity checks, sourced by the pipeline scripts.
# Fails early and clearly if the conda environment or the tools a stage needs are missing,
# instead of dying deep inside a long run. Self-contained: defines shell functions only.
#
# The pipeline expects an ACTIVATED conda environment (provides gdal, proj, and for the prep
# stages ALE, isd_generate, and the CSM plugin) plus, for the heavy stages, a packaged ASP build
# on PATH. Two environments are in play (ingest vs cameras+processing); see the README. We
# deliberately use the conda env's own isd_generate, not any older copy bundled with ASP.

# cassis_require <cmd> [<cmd> ...] - CONDA_PREFIX must be set and every command must be on PATH.
cassis_require() {
  if [ -z "${CONDA_PREFIX:-}" ]; then
    echo "ERROR: CONDA_PREFIX is not set. Activate the pipeline conda environment first (see the README)."
    exit 1
  fi
  local c miss=0
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || { echo "ERROR: required tool '$c' not found on PATH (CONDA_PREFIX=$CONDA_PREFIX)."; miss=1; }
  done
  [ "$miss" -eq 0 ] || { echo "  Activate the correct environment or put the tool on PATH (README Environment section)."; exit 1; }
}

# cassis_require_ale - the CaSSIS camera step needs the conda env's ALE and CSM plugin (not ASP's
# likely-older bundled copies) plus gdal. Verify they are present.
cassis_require_ale() {
  cassis_require gdal_translate
  [ -x "$CONDA_PREFIX/bin/isd_generate" ] || { echo "ERROR: $CONDA_PREFIX/bin/isd_generate not found. Activate the CaSSIS ALE/usgscsm environment."; exit 1; }
  ls "$CONDA_PREFIX"/lib/libale* >/dev/null 2>&1 || { echo "ERROR: libale not found in $CONDA_PREFIX/lib (a recent ALE with CaSSIS support is required)."; exit 1; }
  ls "$CONDA_PREFIX"/lib/csmplugins/libusgscsm* >/dev/null 2>&1 || { echo "ERROR: libusgscsm CSM plugin not found in $CONDA_PREFIX/lib/csmplugins."; exit 1; }
}

# cassis_isd_generate <args> - run the conda env's isd_generate (never ASP's). On failure, hint at ALE.
cassis_isd_generate() {
  local isd="$CONDA_PREFIX/bin/isd_generate"
  [ -x "$isd" ] || { echo "ERROR: $isd not found. Activate the CaSSIS ALE/usgscsm environment."; exit 1; }
  "$isd" "$@" || { echo "ERROR: isd_generate failed. Check that you have a recent enough ALE (with CaSSIS support)."; return 1; }
}

# --- input look-up helpers: find framelet cubs by the LOOK ID in the filename ---
# The cube filename is cas_cal_sc_...-PAN-<sid>-<framelet>-0__4_0.cub, so a look is identified by its
# sid, not by any subdir name. We only require the two looks' cubs be somewhere under inputCassisDir
# (flat, or one subdir deep such as our fetch's L1_<sid>/). No L1_/L2_ naming is assumed.

# cassis_look_cubs <inputCassisDir> <sid> - echo the cubs for a look (found by sid), sorted.
cassis_look_cubs() {
  ls "$1"/*/*-"$2"-*-0__4_0.cub "$1"/*-"$2"-*-0__4_0.cub 2>/dev/null | sort -u
}

# cassis_cub_for_stem <inputCassisDir> <stem> - echo the single cub named <stem>.cub (first match).
cassis_cub_for_stem() {
  ls "$1"/*/"$2".cub "$1"/"$2".cub 2>/dev/null | head -1
}
