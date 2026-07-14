#!/bin/bash
# CaSSIS GCP STAGE: dem2gcp tying our DEM to CTX via the warped-to-ref disparity.
# Fixed stage; only paths change per run. Uses --match-files-prefix (our matches are
# run-disp-*.match, NOT *-clean.match) - this is why the sfs dem2gcp.sh (which uses
# --clean-match-files-prefix) is NOT reused. Replicates the validated dem2gcp_v7 call.
# UNIVERSAL GCP: dem2gcp tying a DEM to CTX via the warped-to-ref disparity. ALL args REQUIRED, NO
# silent defaults. Runs on the compute node (packaged ASP). Usage:
#   gen_gcp.sh <warped_dem> <ref_dem> <disparity> <image_list> <camera_list> \
#              <match_prefix> <max_disp> <gcp_out> <gcp_sigma> <max_gcp>
umask 022
set -e
warped=${1:?warped_dem}; ref=${2:?ref_dem}; disp=${3:?disparity}; img=${4:?image_list}
cams=${5:?camera_list}; mprefix=${6:?match_prefix}; maxdisp=${7:?max_disp}; gcp=${8:?gcp_out}
sigma=${9:?gcp_sigma}; maxgcp=${10:?max_gcp}
ASP=$HOME/projects/BinaryBuilder/StereoPipeline
export PATH=$ASP/bin:$PATH PROJ_DATA=$ASP/share/proj PROJ_LIB=$ASP/share/proj
mkdir -p "$(dirname "$gcp")"
echo "dem2gcp: $(which dem2gcp)"
dem2gcp \
  --warped-dem "$warped" \
  --ref-dem "$ref" \
  --warped-to-ref-disparity "$disp" \
  --image-list "$img" \
  --camera-list "$cams" \
  --match-files-prefix "$mprefix" \
  --max-pairwise-matches "$maxgcp" \
  --max-num-gcp "$maxgcp" \
  --gcp-sigma "$sigma" \
  --max-disp "$maxdisp" \
  --output-gcp "$gcp"
echo "GCP_STAGE_DONE -> $gcp ($(grep -vc '^#' "$gcp" 2>/dev/null) gcp points, sigma $sigma maxgcp $maxgcp)"
