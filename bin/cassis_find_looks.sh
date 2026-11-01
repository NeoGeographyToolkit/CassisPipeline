#!/bin/bash
# cassis_find_looks.sh <orbit> - discover the two stereo look (acquisition) ids for a
# CaSSIS orbit from the ESA PSA archive listing.
#
# A CaSSIS stereo observation is two looks taken seconds apart with the telescope
# rotated 180 degrees. In the PSA "Science" directory for an orbit they appear as a pair
# of acquisition-id subdirectories whose ids are CONSECUTIVE (differ by 1); the smaller
# is the left look, the larger the right. An orbit may list other, unrelated acquisitions
# too, so this picks the first consecutive pair.
#
# Network only (light): runs on a machine with outside access (on pfe, the head node).
# Prints one line "Llook Rlook" on success, nothing (exit 1) if no consecutive pair.
#
# Usage: cassis_find_looks.sh <orbit>
set -u
orbit=${1:?usage: cassis_find_looks.sh <orbit>}
UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/120 Safari/537.36"
lo=$(( (orbit/100)*100 )); hi=$(( lo + 99 ))
B="https://archives.esac.esa.int/psa/ftp/ExoMars2016/em16_tgo_cas/data_calibrated/Science_Phase/Orbit_Range_${lo}_${hi}/Orbit_${orbit}/Science"
# List the acquisition-id subdirectories (9-digit ids), sorted ascending.
ids=$(curl -sL --max-time 90 -A "$UA" "$B/" 2>/dev/null \
  | grep -ioE 'href="[0-9]{9}/"' | sed 's/href="//; s#/"##' | sort -un)
[ -n "$ids" ] || { echo "no acquisition ids listed for orbit $orbit under $B/" >&2; exit 1; }
# Find the first consecutive pair (ids differ by exactly 1).
prev=""
for id in $ids; do
  if [ -n "$prev" ] && [ "$id" -eq "$((prev + 1))" ]; then
    echo "$prev $id"; exit 0
  fi
  prev="$id"
done
echo "no consecutive look pair among: $ids" >&2
exit 1
