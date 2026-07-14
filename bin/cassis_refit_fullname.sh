#!/usr/bin/env bash
# cassis_refit_fullname.sh - regenerate the pristine CASSIS->TRANSVERSE refit from the ORIGINAL
# aligned baby framelets, on the Mac, emitting FULL-NAME output cams (so they match images_data.txt
# and the monster GCP - no short-name sl/ indirection downstream). Doubles as a reproducibility
# sanity check: c0 should match frame/sl_refit (~0.0009, shared across framelets).
#
# Per framelet: input = sl/Lk.json (CASSIS type 9, a symlink to the full-name baby- cam) + sl/Lk.cub;
# resolve the full stem from the symlink target; cam_gen --csm-refit-distortion (exact pose, distortion
# only) -> <site>/frame/sl_refit_full/<fullstem>.json. Mac dev build (loads CASSIS type 9; pfe cannot).  [2026-07-09: OBSOLETE - pfe NOW loads CASSIS type 9]
set +e; umask 022
source "$(ls -d $HOME/*conda3/etc/profile.d/conda.sh 2>/dev/null|head -1)" 2>/dev/null
# ASP/ISIS tools on PATH and environment (ISIS kernels) are set up by the caller.
# Run this from your work directory. See the repository README.
W=$PWD
log=$W/output_refit_fullname.txt; exec > "$log" 2>&1
echo "=== [refit_fullname] START $(date) host=$(uname -n) ==="

sites="jezero/MY36_016378_162 oxia_planum/MY34_003806_019 oxia_planum/MY34_004172_162"
total=0; fail=0
for D in $sites; do
  out=$D/frame/sl_refit_full; mkdir -p "$out"
  echo "--- site $D -> $out ($(date)) ---"
  for cam in "$D"/frame/sl/*.json; do
    [ -e "$cam" ] || continue
    short=$(basename "$cam" .json)                 # e.g. L14
    tgt=$(readlink "$cam"); full=$(basename "$tgt") # baby-<stem>.adjusted_state.json
    full=${full#baby-}; full=${full%.adjusted_state.json}
    cub="$D/frame/sl/$short.cub"
    [ -e "$cub" ] || { echo "  MISSING CUB $cub"; fail=$((fail+1)); continue; }
    o="$out/$full.json"
    cam_gen "$cub" --input-camera "$cam" \
      --csm-refit-distortion --distortion-type transverse \
      --refine-intrinsics distortion --datum D_MARS \
      --num-pixel-samples 4000 -o "$o" > "$out/$short-camgen.log" 2>&1
    if [ -s "$o" ]; then total=$((total+1)); else echo "  FAIL $short -> $full"; fail=$((fail+1)); fi
  done
  echo "  site done: $(ls "$out"/*.json 2>/dev/null | wc -l) cams"
done
echo "=== [refit_fullname] DONE $(date) total=$total fail=$fail ==="

# SANITY: c0 shared across framelets/sites (~0.0009 = sl_refit)?
echo "--- sanity: c0 of one full-name refit per site ---"
for D in $sites; do
  f=$(ls "$D"/frame/sl_refit_full/*.json 2>/dev/null | head -1)
  [ -s "$f" ] && tail -n +2 "$f" | python3 -c "import sys,json;d=json.load(sys.stdin);c=d.get('m_opticalDistCoeffs',[]);print('  $D  type=%s c0=%.5f c1=%.5f'%(d.get('m_distortionType'),c[0],c[1]))"
done
