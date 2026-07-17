#!/bin/bash
# Refit every CaSSIS framelet's distortion from native CASSIS (USGSCSM type 9) to
# CSM TRANSVERSE, keeping each framelet's EXACT pose+intrinsics (the patched cam_gen
# --csm-refit-distortion), then cam_test each refit vs its original CASSIS camera.
# NOTE (2026-07-01): per-framelet refit is FINE. --refine-intrinsics distortion PRESERVES
# all non-distortion intrinsics (focal, ccd center, pixel pitch, iTransS/L - verified
# identical to the CASSIS input), and since it is one physical lens the fitted transverse
# distortion comes out IDENTICAL across framelets - so it equals borrowing one shared
# distortion (the BA's --intrinsics-to-share all is then just a no-op copy of that value).
# Generic: inputs are the camera dir (run-*.adjusted_state.json), the framelet image
# dir, the output dir, and the datum. No specifics hardcoded.
# Usage: refit_transverse.sh <cam_dir> <img_dir> <out_dir> [datum]
set -e
# ASP/ISIS tools on PATH and environment (ISIS kernels) are set up by the caller.
# Run this from your work directory. See the repository README.
cam_dir=$1; img_dir=$2; out_dir=$3; datum=${4:-D_MARS}
# Idempotent: if the refit output cameras already exist, there is nothing to do.
nout=$(ls "$out_dir"/*.json 2>/dev/null | wc -l | tr -d ' ')
if [ "${nout:-0}" -ge 2 ]; then
  echo "refit cameras exist ($nout), skipping: $out_dir"
  exit 0
fi
mkdir -p "$out_dir"
summary="$out_dir/camtest_summary.txt"
# Shared out_dir across per-look calls: append, do not truncate, so BOTH looks' rows
# survive (this script is invoked once per look with the same out_dir).
[ -s "$summary" ] || echo "name  center_diff_m  dir_diff_rad  pix_diff_median" > "$summary"
echo "=== refit $cam_dir -> $out_dir ==="
# Cameras are the aligned framelets (aligned-<stem>.adjusted_state.json) or
# run-<X>.adjusted_state.json. name = bare stem either way; img = img_dir/<name>.cub.
shopt -s nullglob
# accept aligned-<stem> (CTX-aligned framelets), run-<X>, or bare <stem>.json
cams=( "$cam_dir"/aligned-*.adjusted_state.json )
[ ${#cams[@]} -eq 0 ] && cams=( "$cam_dir"/run-*.adjusted_state.json )
[ ${#cams[@]} -eq 0 ] && cams=( "$cam_dir"/*.json )
for cam in "${cams[@]}"; do
  name=$(basename "$cam"); name=${name%.json}; name=${name%.adjusted_state}; name=${name#run-}; name=${name#aligned-}
  img="$img_dir/$name.cub"
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
echo "REFIT_DONE -> $out_dir (summary: $summary)"
