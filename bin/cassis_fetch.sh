#!/bin/bash
# cassis_fetch.sh <site.conf> <workdir> - the FETCH tier, in one command.
#
# This is the whole network side of a site, for a machine with outside access (on a cluster, the
# FRONT-END / head node). It does no heavy compute. It reads the site config and runs, in order:
#   1. discover the two stereo look ids for the orbit, if the config does not already give them
#      (cassis_find_looks.sh);
#   2. download the calibrated PAN framelets for both looks from the ESA PSA (cassis_fetch_pair.sh);
#   3. download the controlled CTX DTMs that cover the site, for the CTX reference (cassis_ctx_fetch.sh).
# Everything after this - ingest, cameras, CTX blend, and the numbered stages - is pure compute with no
# network, and belongs on a compute node (see the README "Processing a new site from scratch").
#
# The site config (sourced as shell variables) must provide:
#   orbit            orbit number (the middle field of the observation id, e.g. 4041 for MY34_004041_196)
#   inputCassisDir   where the framelet cubs go
#   refDem           CTX reference path; its directory is the CTX work dir (dl/, box_te.txt land there)
#   clat, clon       site center latitude, east longitude (for the CTX local-stereographic grid)
# and EITHER
#   footprintBbox    minLon,minLat,maxLon,maxLat (east lon) of the observation footprint - used to size the
#                    CTX box when there is no prior DEM (vendor-free); OR
#   footprintDem     a path to a DEM (prior vendor or linescan) that defines the footprint instead.
# Optional:
#   Llook, Rlook     the look ids; if absent they are discovered from the orbit listing.
#
# Usage: cassis_fetch.sh <site.conf> <workdir>
set -e; umask 022
cfg=${1:?usage: cassis_fetch.sh <site.conf> <workdir>}
B=${2:?workdir}
cd "$B" || { echo "ERROR cannot cd $B"; exit 1; }
# Make the sibling fetch tools resolvable whether this was called by path or by bare name on PATH.
BIN=$(cd "$(dirname "$0")" 2>/dev/null && pwd); case "$0" in */*) : ;; *) BIN=$(cd "$(dirname "$(command -v "$0")")" 2>/dev/null && pwd) ;; esac
export PATH="$BIN:$PATH"
[ -s "$B/cassis_common.conf" ] && source "$B/cassis_common.conf"
[ -s "$B/$cfg" ] || { echo "ERROR missing site config $cfg"; exit 1; }
source "$B/$cfg"
: "${orbit:?config must set orbit}" "${inputCassisDir:?config must set inputCassisDir}"
: "${refDem:?config must set refDem}" "${clat:?config must set clat}" "${clon:?config must set clon}"

# 1. Look ids: discover if the config does not pin them.
if [ -z "${Llook:-}" ] || [ -z "${Rlook:-}" ]; then
  echo "[fetch] discovering look ids for orbit $orbit"
  read Llook Rlook < <(cassis_find_looks.sh "$orbit") || { echo "ERROR could not discover looks for orbit $orbit"; exit 1; }
  echo "[fetch] looks: L=$Llook R=$Rlook"
fi

# 2. Framelets for both looks.
echo "[fetch] framelets -> $inputCassisDir"
cassis_fetch_pair.sh "$orbit" "$Llook" "$Rlook" "$inputCassisDir"

# 3. Controlled CTX DTMs. The footprint is a prior DEM if given, else the observation bbox stand-in.
ctxDir=$(dirname "$refDem")
if [ -n "${footprintDem:-}" ]; then fp="$footprintDem"; else
  : "${footprintBbox:?config must set footprintBbox (minLon,minLat,maxLon,maxLat) or footprintDem}"
  fp="bbox:$footprintBbox"
fi
echo "[fetch] CTX DTMs over $fp -> $ctxDir"
cassis_ctx_fetch.sh "$ctxDir" "$fp" "$clat" "$clon"

echo "CASSIS_FETCH_DONE orbit=$orbit looks=$Llook/$Rlook data=$inputCassisDir ctx=$ctxDir $(date)"
