#!/bin/bash
# cassis_match_check.sh - screen the left-right dense match files before the bundle adjustment.
# Each L-R match file is triangulated with the start cameras (bundle_adjust, zero iterations), and
# its median height minus refDem is compared with the median over all L-R files. A file departing by
# more than maxDz m is a wrong correlation lock and is dropped; the rest (and all same-look files) are
# copied to <outDir>/matches. Prints the new match prefix on its last line.
# Usage: cassis_match_check.sh <imgList> <camList> <matchpfx> <Llook> <Rlook> <refDem> <maxDz> <outDir>
imgList=${1:?imgList}; camList=${2:?camList}; matchpfx=${3:?matchpfx}; Llook=${4:?Llook}; Rlook=${5:?Rlook}
refDem=${6:?refDem}; maxDz=${7:?maxDz}; out=${8:?outDir}
selfBin=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
mkdir -p "$out/pairs" "$out/matches"
nproc=${matchCheckProcs:-$(nproc 2>/dev/null || echo 4)}
# One task per L-R match file: the two images and cameras from the lists, by framelet stem.
: > "$out/tasks.txt"
sed 's#.*/##; s/\.cub$//' "$imgList" > "$out/stems.txt"
for f in "$matchpfx"-*.match; do
  [ -e "$f" ] || continue
  b=$(basename "$f" .match); b=${b#$(basename "$matchpfx")-}
  # Image stems can themselves contain "__", so split at the stem that starts the name.
  a=""; while read -r s; do case "$b" in "${s}__"*) a=$s; break ;; esac; done < "$out/stems.txt"
  [ -n "$a" ] || { echo "  skip $b (left image not in list)"; continue; }
  c=${b#"${a}__"}
  case "$a$c" in *-PAN-$Llook-*-PAN-$Rlook-*|*-PAN-$Rlook-*-PAN-$Llook-*) ;; *) continue ;; esac
  ia=$(grep -- "/$a.cub" "$imgList"); ic=$(grep -- "/$c.cub" "$imgList")
  ca=$(paste -d' ' "$imgList" "$camList" | grep -- "/$a.cub " | cut -d' ' -f2)
  cc=$(paste -d' ' "$imgList" "$camList" | grep -- "/$c.cub " | cut -d' ' -f2)
  [ -n "$ia" ] && [ -n "$ic" ] && [ -n "$ca" ] && [ -n "$cc" ] || { echo "  skip $b (image or camera not in lists)"; continue; }
  echo "$b $ia $ic $ca $cc" >> "$out/tasks.txt"
done
echo "  L-R match files to check: $(wc -l < "$out/tasks.txt")"
while read -r b ia ic ca cc; do
  echo "bundle_adjust $ia $ic $ca $cc --match-files-prefix $matchpfx --num-iterations 0 --threads 1 --min-triangulation-angle 1e-10 --forced-triangulation-distance 392000 --max-pairwise-matches 5000 -o $out/pairs/$b/run"
done < "$out/tasks.txt" | xargs -P "$nproc" -I{} sh -c '{} > /dev/null 2>&1'
python3 "$selfBin/cassis_match_check.py" "$out/pairs" "$refDem" "$maxDz" "$out/drop.txt" | tee "$out/summary.txt"
n=0
for f in "$matchpfx"-*.match; do
  b=$(basename "$f" .match); b=${b#$(basename "$matchpfx")-}
  grep -qx -- "$b" "$out/drop.txt" && continue
  cp "$f" "$out/matches/run-disp-$b.match"; n=$((n+1))
done
echo "  kept $n match files, dropped $(grep -c . "$out/drop.txt")"
echo "$out/matches/run-disp"
