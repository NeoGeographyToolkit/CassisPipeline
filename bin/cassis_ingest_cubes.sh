#!/bin/bash
# cassis_ingest_cubes.sh - GENERIC CaSSIS framelet -> ISIS cube ingest (NO kernels).
# Canonical, parametrized replacement for the per-site ingest_jezero.sh / oxia_ingest.sh. Portable
# conda (Mac anaconda3 / l1 miniconda3). For each look dir under the site data root whose .dat count
# == .xml count: tgocassis2isis on each calibrated framelet .xml -> .cub, then inject
# SpacecraftClockStartCount from the XML hex-ASCII exposuretimestamp (PSA-export framelets lack the
# clock keyword camera init needs; OBSOLETED by ISIS PR 6079 once that reaches the build). Idempotent
# (skips framelets that already have a .cub). spiceinit + CSM ISD json are done SEPARATELY (cassis_
# isd_l1.sh, kernel-gated, ale_cassis env). NO `set -u` (conda hooks use unbound vars).
#   Arg: $1 = site data root (default data/MY34_004756_354_1); looks are its L*_* subdirs.
SITEDATA=${1:-data/MY34_004756_354_1}
LOCK=/tmp/cassis_ingest_$(echo "$SITEDATA" | tr '/' '_').lock
mkdir "$LOCK" 2>/dev/null || { echo "another ingest running (lock $LOCK); exit"; exit 0; }
trap 'rmdir "$LOCK" 2>/dev/null' EXIT
CONDA=$HOME/anaconda3; [ -x "$HOME/miniconda3/bin/conda" ] && CONDA=$HOME/miniconda3
eval "$("$CONDA/bin/conda" shell.bash hook)"; conda activate asp_deps
export ISISROOT=$CONDA/envs/asp_deps
export ISISDATA=$HOME/projects/isis3data
export PATH=$HOME/projects/StereoPipeline/install/bin:$ISISROOT/bin:$PATH
cd "$HOME/projects/cassis_asp" || exit 1
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
