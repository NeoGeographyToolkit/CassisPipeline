#!/bin/bash
# refit_transverse.sh - refit every CaSSIS framelet's distortion from native CASSIS (USGSCSM
# type 9) to CSM TRANSVERSE, keeping each framelet's EXACT pose+intrinsics (the patched cam_gen
# --csm-refit-distortion), then cam_test each refit vs its original CASSIS camera. Runs both
# looks in one call, into the shared registered_cassis_cams directory.
# NOTE (2026-07-01): per-framelet refit is FINE. --refine-intrinsics distortion PRESERVES
# all non-distortion intrinsics (focal, ccd center, pixel pitch, iTransS/L - verified
# identical to the CASSIS input), and since it is one physical lens the fitted transverse
# distortion comes out IDENTICAL across framelets - so it equals borrowing one shared
# distortion (the BA's --intrinsics-to-share all is then just a no-op copy of that value).
#
# Config-driven: reads inputCassisDir + Llook/Rlook (input) and writes the refit cams under outDir.
# The datum defaults to the refitDatum constant (D_MARS).
# Usage: refit_transverse.sh <site.conf> <outDir> <workdir>
set -e
umask 022
# ASP/ISIS tools on PATH and the environment are set up by the caller. See the README.
cfg=${1:?usage: refit_transverse.sh <site.conf> <outDir> <workdir>}
outDir=${2:?outDir (output dir, relative to workdir or absolute)}
B=${3:?workdir}
cd "$B" || { echo "ERROR cannot cd $B"; exit 1; }
[ -s "$B/cassis_common.conf" ] && source "$B/cassis_common.conf"
[ -s "$B/$cfg" ] || { echo "ERROR missing site config $cfg"; exit 1; }
source "$B/$cfg"
source cassis_env_check.sh
cassis_require cam_gen cam_test
datum=${refitDatum:-D_MARS}
out_dir=$outDir/frame/registered_cassis_cams

# Idempotent: if the refit output cameras already exist, there is nothing to do.
nout=$(ls "$out_dir"/*.json 2>/dev/null | wc -l | tr -d ' ')
if [ "${nout:-0}" -ge 2 ]; then
  echo "refit cameras exist ($nout), skipping: $out_dir"
  exit 0
fi
mkdir -p "$out_dir"
summary="$out_dir/camtest_summary.txt"
echo "name  center_diff_m  dir_diff_rad  pix_diff_median" > "$summary"
shopt -s nullglob

# Loop both looks into the shared output directory. Look 1 = Llook, look 2 = Rlook; the input
# cameras are the aligned framelets, and each framelet's cub is found in inputCassisDir by its stem.
n=1
for sid in "$Llook" "$Rlook"; do
  cam_dir=$outDir/frame/aligned_framelets/$sid
  echo "=== refit look $n (sid $sid): $cam_dir -> $out_dir ==="
  # accept aligned-<stem> (CTX-aligned framelets), run-<X>, or bare <stem>.json
  cams=( "$cam_dir"/aligned-*.adjusted_state.json )
  [ ${#cams[@]} -eq 0 ] && cams=( "$cam_dir"/run-*.adjusted_state.json )
  [ ${#cams[@]} -eq 0 ] && cams=( "$cam_dir"/*.json )
  for cam in "${cams[@]}"; do
    name=$(basename "$cam"); name=${name%.json}; name=${name%.adjusted_state}; name=${name#run-}; name=${name#aligned-}
    img=$(cassis_cub_for_stem "$inputCassisDir" "$name")
    out="$out_dir/$name.json"
    [ -s "$out" ] && { echo "$name exists, skipping"; continue; }
    if [ ! -f "$img" ]; then echo "$name MISSING_IMAGE $img" | tee -a "$summary"; continue; fi
    # Refit transverse, exact pose, distortion only.
    cam_gen "$img" \
      --input-camera "$cam" \
      --csm-refit-distortion \
      --distortion-type transverse \
      --refine-intrinsics distortion \
      --datum "$datum" \
      --num-pixel-samples 4000 \
      -o "$out" > "$out_dir/$name-camgen.log" 2>&1
    # cam_test refit vs original.
    cam_test --image "$img" --cam1 "$cam" --cam2 "$out" --sample-rate 50 \
      > "$out_dir/$name-camtest.log" 2>&1 || true
    ctr=$(grep -A3 'camera center diff'  "$out_dir/$name-camtest.log" | grep -m1 Median | awk '{print $2}')
    dir=$(grep -A3 'camera direction diff' "$out_dir/$name-camtest.log" | grep -m1 Median | awk '{print $2}')
    pix=$(grep -A3 'cam1 to cam2 pixel diff' "$out_dir/$name-camtest.log" | grep -m1 Median | awk '{print $2}')
    echo "$name  ${ctr:-NA}  ${dir:-NA}  ${pix:-NA}" | tee -a "$summary"
  done
  n=$((n+1))
done
echo "REFIT_DONE -> $out_dir (summary: $summary)"
