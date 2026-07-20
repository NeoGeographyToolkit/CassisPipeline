#!/bin/bash

# jitter_solve.sh - joint jitter solve for the CTX (linescan) + CaSSIS (frame)
# cameras. It uses the clean match files from parallel_bundle_adjust.sh, pulls the
# triangulated heights to the CTX DEM (--heights-from-dem), and stabilizes the
# orientation with anchor points on the bigger HRSC DEM (--anchor-dem). The input
# cameras are the already-aligned ones (same as bundle); their poses are refined for
# jitter. Mars. Single node, threaded. Runs via qsub.
#
# Recommended params (a good working set for a joint CTX + CaSSIS solve, from the
# 002920 Olympus Mons study). The one that matters is the camera-position-uncertainty:
# giving the poses room (500,500 m) lets the two sensors reconcile as far as they can.
# Tighter values do not help, and tightening the height constraint slightly hurts.
# The other three are safe defaults. All four are env-overridable (same style as
# blunderTolM in cassis_stereo.sh), but the defaults below are the recommended values.
#   camPos   = 500,500  --camera-position-uncertainty   (the important one)
#   htUnc    = 20        --heights-from-dem-uncertainty
#   anchUnc  = 50        --anchor-dem-uncertainty
#   anchTile = 10        --num-anchor-points-per-tile
#
# Args:
#   imageList    one image (cub) per line (same as bundle)
#   cameraList   matching CSM camera (json) per line, same order (same as bundle)
#   matchPrefix  clean-match-files prefix produced by parallel_bundle_adjust.sh
#   dem          CTX reference DEM, for --heights-from-dem
#   anchorDem    HRSC DEM (bigger), for --anchor-dem
#   outPrefix    jitter_solve output prefix
#   currDir      work dir, LAST; all the paths above are relative to it

if [ "$#" -ne 7 ]; then
    echo "Usage: $0 imageList cameraList matchPrefix dem anchorDem outPrefix currDir"
    exit 1
fi
imageList=$1; shift
cameraList=$1; shift
matchPrefix=$1; shift
dem=$1; shift
anchorDem=$1; shift
outPrefix=$1; shift
currDir=$1; shift
cd $currDir

echo imageList=$imageList
echo cameraList=$cameraList
echo matchPrefix=$matchPrefix
echo dem=$dem
echo anchorDem=$anchorDem
echo outPrefix=$outPrefix
echo currDir=$currDir

# Recommended params (env-overridable; defaults are the good working values above).
htUnc=${HTUNC:-20}          # --heights-from-dem-uncertainty
anchUnc=${ANCHUNC:-50}      # --anchor-dem-uncertainty
camPos=${CAMPOS:-500,500}   # --camera-position-uncertainty (the important one)
anchTile=${ANCHTILE:-10}    # --num-anchor-points-per-tile

# Set up the paths
s=StereoPipeline
export ISISROOT=$HOME/projects/BinaryBuilder/$s
export ISISDATA=$HOME/projects/isis3data
export ALESPICEROOT=$ISISDATA
export PROJ_DATA=$ISISROOT/share/proj
export PATH=$ISISROOT/bin:$PATH
umask 022

mkdir -p $(dirname $outPrefix)
out=output_jitter_$(basename $(dirname $outPrefix)).txt
echo Will write the output to $out
/bin/rm -fv $out
exec >> "$out" 2>&1

echo "START $(date) host=$(uname -n)"

jitter_solve \
  --image-list $imageList \
  --camera-list $cameraList \
  --clean-match-files-prefix $matchPrefix \
  --heights-from-dem $dem \
  --heights-from-dem-uncertainty $htUnc \
  --anchor-dem $anchorDem \
  --num-anchor-points-per-tile $anchTile \
  --anchor-dem-uncertainty $anchUnc \
  --camera-position-uncertainty $camPos \
  --num-lines-per-position 500 \
  --num-lines-per-orientation 250 \
  --max-pairwise-matches 20000 \
  --min-matches 1 \
  --min-triangulation-angle 1e-10 \
  --max-initial-reprojection-error 50 \
  --parameter-tolerance 1e-12 \
  --robust-threshold 0.5 \
  --num-passes 2 \
  --num-iterations 50 \
  --threads 8 \
  -o $outPrefix

echo "DONE $(date) rc=$?"
