#!/bin/bash
# cassis_fetch_pair.sh - GENERIC per-pair CaSSIS calibrated PAN framelet fetch from the ESA PSA archive.
# Args:
#   $1 orbit    (e.g. 4756)              $2 acq1 (L/STEREO1 sid)   $3 acq2 (R/STEREO2 sid)
#   $4 destDir  (e.g. data/MY34_004756_354_1 - a CLEAN root, NOT the legacy data/jezero misnomer)
# Downloads .dat/.xml PAN framelets (skips sti) into $destDir/L1_$acq1/ and L2_$acq2/. Resumable.
# Runs anywhere with outside access (prefer l1 - bandwidth). PSA is slow (~0.5-1 file/s).
set -u
orbit="$1"; a1="$2"; a2="$3"; DEST="$4"
[ -n "$DEST" ] || { echo "usage: cassis_fetch_pair.sh orbit acq1 acq2 destDir"; exit 1; }
UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/120 Safari/537.36"
lo=$(( (orbit/100)*100 )); hi=$(( lo + 99 ))
B="https://archives.esac.esa.int/psa/ftp/ExoMars2016/em16_tgo_cas/data_calibrated/Science_Phase/Orbit_Range_${lo}_${hi}/Orbit_${orbit}/Science"
n=1
for acq in "$a1" "$a2"; do
  out="$DEST/L${n}_$acq"; mkdir -p "$out"
  echo "=== L$n orbit $orbit acq $acq -> $out ($(date)) ==="
  files=$(curl -sL --max-time 90 -A "$UA" "$B/$acq/PAN/" 2>/dev/null \
    | grep -ioE 'href="cas_cal[^"]*"' | sed 's/href="//;s/"//' \
    | grep -vi sti | grep -iE '\.(dat|xml)$' | sort -u)
  cnt=$(echo "$files" | grep -c .)
  echo "  $cnt files listed"
  for f in $files; do
    [ -s "$out/$f" ] && continue
    curl -sL --max-time 120 -A "$UA" "$B/$acq/PAN/$f" -o "$out/$f"
  done
  echo "  got $(ls "$out"/*.dat 2>/dev/null | wc -l) .dat framelets in $out"
  n=$((n+1))
done
echo "CASSIS_FETCH_PAIR_DONE $(date)"
