#!/bin/bash
# cassis_ingest_cubes.sh - GENERIC CaSSIS framelet -> ISIS cube ingest (NO kernels).
# Parametrized by the site data root. For each look dir under it whose .dat count
# == .xml count: tgocassis2isis on each calibrated framelet .xml -> .cub, then inject
# SpacecraftClockStartCount from the XML hex-ASCII exposuretimestamp (PSA-export framelets lack the
# clock keyword camera init needs; OBSOLETED by ISIS PR 6079 once that reaches the build). Idempotent
# (skips framelets that already have a .cub). Camera generation is done SEPARATELY, with
# cassis_make_cameras.sh. NO `set -u` (conda hooks use unbound vars).
#   Arg: $1 = site data root; the looks are its L*_* subdirectories.
SITEDATA=${1:?usage: cassis_ingest_cubes.sh <site data root>}
source cassis_env_check.sh
cassis_require_isisdata
cassis_require tgocassis2isis editlab
LOCK=/tmp/cassis_ingest_$(echo "$SITEDATA" | tr '/' '_').lock
mkdir "$LOCK" 2>/dev/null || { echo "another ingest running (lock $LOCK); exit"; exit 0; }
trap 'rmdir "$LOCK" 2>/dev/null' EXIT
# ASP/ISIS tools on PATH and environment (ISIS kernels) are set up by the caller.
# Run this from your work directory. See the repository README.
for look in "$SITEDATA"/L*_*; do
  [ -d "$look" ] || continue
  nd=$(ls "$look"/*.dat 2>/dev/null | wc -l | tr -d ' ')
  nx=$(ls "$look"/*.xml 2>/dev/null | wc -l | tr -d ' ')
  [ "$nd" -ge 1 ] && [ "$nd" = "$nx" ] || { echo "skip (incomplete $nd/$nx): $look"; continue; }
  done_cub=$(ls "$look"/*.cub 2>/dev/null | wc -l | tr -d ' ')
  [ "$done_cub" = "$nd" ] && { echo "already ingested: $look"; continue; }
  echo "=== ingest $look ($nd framelets) ==="
  for xml in "$look"/*.xml; do
    cub="${xml%.xml}.cub"
    [ -s "$cub" ] && continue
    tgocassis2isis from="$xml" to="$cub" >/dev/null 2>&1 || { echo "  FAIL tgocassis2isis $(basename $xml)"; continue; }
    ts=$(grep -ioE '<em16_tgo_cas:exposuretimestamp>[0-9a-fA-F]+' "$xml" | sed 's/.*>//')
    if [ -n "$ts" ]; then
      clk=$(echo "$ts" | xxd -r -p 2>/dev/null)
      [ -n "$clk" ] && editlab from="$cub" options=addkey grpname=Instrument \
        keyword=SpacecraftClockStartCount value="$clk" >/dev/null 2>&1
    fi
  done
  echo "  cubes now: $(ls "$look"/*.cub 2>/dev/null | wc -l | tr -d ' ')/$nd"
done
echo "CASSIS_INGEST_CUBES_DONE $SITEDATA total_cub=$(find "$SITEDATA" -name '*.cub' | wc -l | tr -d ' ')"
