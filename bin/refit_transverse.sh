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
mkdir -p "$out_dir"
summary="$out_dir/camtest_summary.txt"
: > "$summary"
echo "name  center_diff_m  dir_diff_rad  pix_diff_median" | tee -a "$summary"
# Accept either the Jezero run-<X>.adjusted_state.json naming OR the short Oxia
# sl/<X>.json baby frames. name = bare stem either way; img = img_dir/<name>.cub.
shopt -s nullglob
# accept baby-<stem> (CTX-aligned frame babies), run-<X> (Jezero), or bare sl/<X>.json (Oxia)
cams=( "$cam_dir"/baby-*.adjusted_state.json )
[ ${#cams[@]} -eq 0 ] && cams=( "$cam_dir"/run-*.adjusted_state.json )
[ ${#cams[@]} -eq 0 ] && cams=( "$cam_dir"/*.json )
for cam in "${cams[@]}"; do
  name=$(basename "$cam"); name=${name%.json}; name=${name%.adjusted_state}; name=${name#run-}; name=${name#baby-}
  img="$img_dir/$name.cub"
  out="$out_dir/$name.json"
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
