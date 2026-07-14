#!/bin/bash
# Align OUR linescan-tie CaSSIS DEM (S3 output) to the 21-CTX curated blend, and
# carry the alignment transform onto the linescan cameras (S4 + S5). Recipe reused
# from oxia_ctx_align_dense.sh (the vendor-DEM version) + pc_align.rst ba_pc_align:
#   coarse-match 18 m (CTX-native, textures match) dense correlate hillshades ->
#   rigid transform -> APPLY at fine 4.59 m -> point2dem aligned DEM. The FINAL
#   (fine) runf-transform.txt INCORPORATES the coarse one (pc_align chaining rule),
#   so it is the cumulative OURS->CTX transform. Apply it to the tie cameras with
#   bundle_adjust --apply-initial-transform-only --inline-adjustments.
#   pc_align is called REF-first, OURS-second -> our DEM is the 2nd cloud -> use the
#   FORWARD runf-transform.txt for cameras (pc_align.rst L758-768).
# Judge ONLY by the red/green hillshade overlay (Claude-has-eyes); geodiff std is
# BLIND to horizontal shift on this flat plain. --max-displacement -1 handles the
# ~8 km uncontrolled-SPICE vertical offset.
# Usage: align_ls_to_ctx.sh <pairDir> <L_strip> <L_tiestate> <R_strip> <R_tiestate> [tag]
#   pairDir e.g. oxia_planum/MY34_003806_019 ; tag default "cs"
set -e
eval "$($HOME/anaconda3/bin/conda shell.bash hook)"; conda activate asp_deps
export ISISROOT=$HOME/anaconda3/envs/asp_deps ISISDATA=$HOME/projects/isis3data
export PATH=$HOME/projects/StereoPipeline/install/bin:$HOME/anaconda3/envs/asp_deps/bin:$ISISROOT/bin:$PATH
cd ~/projects/cassis_asp

pairDir=$1; Ls=$2; Lstate=$3; Rs=$4; Rstate=$5; tag=${6:-cs}
dem=$pairDir/ls_tied/stereo/dem-DEM.tif
[ -s "$dem" ] || { echo "ERROR: missing tie DEM $dem"; exit 1; }

PROJ='+proj=eqc +lat_ts=0 +lat_0=0 +lon_0=0 +x_0=0 +y_0=0 +R=3396190 +units=m +no_defs'
TE="-1457283.690 1066963.860 -1434599.910 1110463.290"; TSF="4942 9477"
FTR=4.59; CTR=18.36
BF=ref/oxia_planum_ctx/blend/oxia_ctx_blend_curated_4p59m_crop.tif
BC=ref/oxia_planum_ctx/blend/oxia_ctx_blend_curated_18m_crop.tif
[ -f "$BC" ] || gdalwarp -q -overwrite -t_srs "$PROJ" -te $TE -tr $CTR $CTR -r cubicspline "$BF" "$BC"
BCH=${BC%.tif}_hill10.tif; [ -f "$BCH" ] || gdaldem hillshade -alt 10 -compute_edges "$BC" "$BCH" >/dev/null 2>&1

out=$pairDir/align_ctx; mkdir -p "$out"; rm -rf "$out/run"*
# warp OUR DEM to the blend grid: fine (full res) + coarse (18 m), hillshade coarse
demf=$out/ls_tie_onblendgrid.tif; demc=$out/ls_tie_onblendgrid_18m.tif; cch=${demc%.tif}_hill10.tif
gdalwarp -q -overwrite -t_srs "$PROJ" -te $TE -ts $TSF -r cubicspline "$dem" "$demf"
gdalwarp -q -overwrite -t_srs "$PROJ" -te $TE -tr $CTR $CTR -r cubicspline "$dem" "$demc"
gdaldem hillshade -alt 10 -compute_edges "$demc" "$cch" >/dev/null 2>&1

echo "=== [$tag] dense correlate hillshades @18 m (CTX=ref, ours=src) ==="
PS="parallel_stereo --correlator-mode --stereo-algorithm asp_mgm --corr-kernel 9 9 --ip-per-tile 400 --subpixel-mode 9 --processes 2 --threads-multiprocess 2 --num-matches-from-disparity 40000"
EXTRA=""; [ "$tag" = cs ] && EXTRA="--corr-search -120 -120 120 120"   # wider: our DEM may be more off than vendor
$PS $EXTRA "$BCH" "$cch" "$out/run" > "$out/corr.log" 2>&1 || { echo "CORR FAILED"; grep -aiE "ERROR|RANSAC|less than" "$out/corr.log"|tail -3; exit 1; }
mf=$(ls "$out"/run-disp*.match 2>/dev/null | head -1); [ -z "$mf" ] && { echo "no match file"; exit 1; }
echo "  matches: $mf"

echo "=== [$tag] pc_align coarse (rigid from hillshade matches) ==="
pc_align --max-displacement -1 --num-iterations 0 --max-num-reference-points 1000000 \
  --match-file "$mf" --initial-transform-from-hillshading rigid --initial-transform-ransac-params 1000 3 \
  --save-transformed-source-points "$BC" "$demc" -o "$out/run2" > "$out/pc_align.log" 2>&1
grep -aE "Translation vector \(North|magnitude of translation" "$out/pc_align.log" | sed 's/^/  /'

echo "=== [$tag] apply at fine 4.59 m (transform CHAINS coarse) ==="
pc_align --max-displacement -1 --initial-transform "$out/run2-transform.txt" --num-iterations 0 \
  --save-transformed-source-points "$BF" "$demf" -o "$out/runf" > "$out/pc_align_fine.log" 2>&1
aln=$pairDir/ls_tied/stereo/dem-DEM_ctxaligned_$tag
point2dem --errorimage --t_srs "$PROJ" --tr $FTR --search-radius-factor 1.45 "$out/runf-trans_source.tif" -o "$aln" > "$out/point2dem.log" 2>&1
mv "${aln}-DEM.tif" "${aln}.tif" 2>/dev/null || true
gdaldem hillshade -alt 25 -az 300 -compute_edges "${aln}.tif" "${aln}_hs.tif" >/dev/null 2>&1
geodiff "${aln}.tif" "$BF" -o "${aln}_ctxdiff" >/dev/null 2>&1 || true
echo "  geodiff std (VERTICAL only, NOT a registration metric): $(gdalinfo -stats ${aln}_ctxdiff-diff.tif 2>/dev/null | grep STATISTICS_STDDEV | sed 's/.*=//')"
echo "  cumulative transform: $out/runf-transform.txt -> aligned DEM ${aln}.tif"

echo "=== [$tag] S5: carry transform to the tie cameras (CTX-aligned linescan states) ==="
bap=$out/cams_aligned/run; mkdir -p "$out/cams_aligned"
bundle_adjust "$Ls" "$Rs" "$Lstate" "$Rstate" \
  --initial-transform "$out/runf-transform.txt" --apply-initial-transform-only \
  --inline-adjustments -o "$bap" > "$out/ba_apply.log" 2>&1 || { echo "BA-apply FAILED"; tail -5 "$out/ba_apply.log"; exit 1; }
ls "$bap"-*.adjusted_state.json | sed 's/^/  aligned cam: /'
echo "ALIGN_LS_DONE $pairDir $tag"
