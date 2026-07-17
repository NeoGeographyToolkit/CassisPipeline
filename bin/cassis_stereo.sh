#!/bin/bash
# cassis_stereo.sh - UNIVERSAL pairwise framelet stereo, DUAL-MODE. The mapproject + per-pair stereo
# harness is shared; num_matches_from_disp selects the mode:
#   * num_matches_from_disp == 0  -> DEM MODE: cross-look L-R pairs from the existing dense match files,
#       per-pair stereo + point2dem + dem_mosaic to the frame DEM on the CTX grid (+ hillshade, tri-err
#       mosaic, dz geodiff). geounc=0 here (cameras are BA-refined; a 0 collar avoids seams).
#   * num_matches_from_disp >  0  -> DENSE MODE: compute the pairing from the mapprojected
#       footprints (best-overlap R per L), run L-R (mapprojected) + same-look L-L/R-R (raw
#       affineepipolar) stereo with --num-matches-from-disparity, and EMIT the matches to
#       <matchPrefix>-<a>__<b>.match (no DEM). geounc here is a pre-BA search COLLAR (> 0): the cameras
#       are not yet refined, so real IPs carry disparity that a 0 collar would filter out.
# Cameras come from imgList/camList either way (a BA stage's frozen cams for DEM, the transverse refit
# cams for dense). FULLY PARAMETERIZED, NO site/obsID/env-default:
#   - images to mapproject come from the BA's OWN run-image_list.txt (that stage's framelets), not a glob.
#   - cameras come from the BA's run-camera_list.txt (1-1 with the images).
#   - cross-look pairs = L stems (contain <Llook>) x R stems (contain <Rlook>), a pair exists iff its dense
#     match file <matchPrefix>-<Lstem>__<Rstem>.match exists. Llook/Rlook/matchPrefix are ARGS.
#   - mapprojDem (BLURRED CTX) is what we mapproject onto; refDem (SHARP high-res CTX = htdem) sets the output
#     grid/proj + the dz geodiff. TWO DISTINCT CTX inputs, both ARGS - do NOT conflate them.
# Recipe (fixed, same every stage): --ip-match-radius 20, --min-matches 5 + --ip-per-tile 2000, asp_mgm
#   subpixel 9, alignment none, point2dem --errorimage --max-valid-triangulation-error 8,
#   +/-500 m per-pair blunder filter, max tri-error mosaic.
# Self-contained under qsub (own cd/umask/log). Resume-safe (skip a pair whose dem-DEM.tif is valid).
# TWO GRIDS (do NOT conflate - the CLAUDE.md stereo-res rule): res = the MAPPROJECT/correlation grid,
# ALWAYS NATIVE ~4.59 m (mapproj at a coarse grid blurs the framelets before correlation = a blocky
# junk DEM). demRes = the point2dem/DEM/mosaic/tri-err grid (e.g. 18 m). Correlation native, DEM coarse.
# Args (B LAST): <pairDir> <tag> <imgList> <camList> <geounc> <mapprojDem> <refDem> <res> <demRes>
#   <matchPrefix> <Llook> <Rlook> <num_matches_from_disp> <B>
set +e
umask 022
pairDir=${1:?pairDir required}
tag=${2:?tag required (names the output dir <pairDir>/frame/<tag>_stereo)}
imgList=${3:?imgList required (INPUT arg: BA run-image_list.txt, 1-1 with camList)}
camList=${4:?camList required (INPUT arg: BA run-camera_list.txt)}
geounc=${5:?geounc required (mapproj-geolocation-uncertainty px)}
mapprojDem=${6:?mapprojDem required (BLURRED CTX to mapproject onto)}
refDem=${7:?refDem required (SHARP high-res CTX = htdem; grid/proj + dz geodiff)}
res=${8:?res required (MAPPROJECT/correlation grid m, NATIVE ~4.59 - never coarse)}
demRes=${9:?demRes required (point2dem/DEM/mosaic grid m, e.g. 18)}
matchPrefix=${10:?matchPrefix required (dense match prefix, e.g. .../dense/matches/run-disp)}
Llook=${11:?Llook required (token identifying L-look framelets, e.g. an obsID)}
Rlook=${12:?Rlook required (token identifying R-look framelets)}
num_matches_from_disp=${13:?num_matches_from_disp required (0 = DEM mode: build the DEM from existing
  match files; >0 = DENSE mode: compute the pairing and EMIT that many matches per pair, no DEM)}
B=${14:?B required (work base, cd target, LAST)}
# ASP/ISIS tools on PATH and environment are set up by the caller. See the README.
cd "$B" || { echo "ERROR cannot cd $B"; exit 1; }
out=$pairDir/frame/${tag}_stereo; mkdir -p "$out/stereo" "$out/maps"
log=$B/output_${tag}_stereo.txt; exec > "$log" 2>&1
echo "=== [cassis_stereo] START $(date) host=$(uname -n) tag=$tag geounc=$geounc mapprojRes=$res demRes=$demRes ==="
echo "  mapprojDem=$mapprojDem refDem=$refDem matchPrefix=$matchPrefix Llook=$Llook Rlook=$Rlook num_matches_from_disp=$num_matches_from_disp"

# geounc <-> mode guard (fail fast). DEM mode (num_matches_from_disp==0, runs point2dem) MUST have
# geounc=0: a nonzero collar there grows the mask into one-image ground and causes SEAMS. DENSE mode
# (num_matches_from_disp>0, pre-BA, also does L-L/R-R) MUST have a collar > 0: a 0 collar filters out
# the disparity-bearing IPs (fails "19 IPs < 20") and every pair dies. These are the two correct regimes.
if [ "${num_matches_from_disp:-0}" -eq 0 ] 2>/dev/null; then
  [ "$geounc" = 0 ] || { echo "ERROR DEM/stereo mode (num_matches_from_disp=0 -> point2dem) requires geounc=0 - a nonzero collar causes seams; got geounc=$geounc"; exit 1; }
else
  [ "$geounc" = 0 ] && { echo "ERROR DENSE mode (num_matches_from_disp>0) requires a geounc COLLAR > 0 - a 0 collar filters pre-BA IPs and every pair fails; got geounc=0"; exit 1; }
fi

# image-list + camera-list are INPUT ARGS (fed from the BA output), 1-1 by count.
[ -s "$imgList" ] && [ -s "$camList" ] || { echo "ERROR missing lists $imgList / $camList"; exit 1; }
nI=$(wc -l < "$imgList"); nC=$(wc -l < "$camList")
[ "$nI" = "$nC" ] || { echo "ERROR image/camera count $nI != $nC"; exit 1; }
[ -s "$mapprojDem" ]  || { echo "ERROR missing mapprojDem $mapprojDem"; exit 1; }
[ -s "$refDem" ] || { echo "ERROR missing refDem $refDem"; exit 1; }

# PROJ + extent from the sharp refDem (do NOT hardcode - read from the DEM).
PROJ=$(gdalsrsinfo -o proj4 "$refDem" 2>/dev/null | tr -d '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
[ -n "$PROJ" ] || { echo "ERROR no PROJ from refDem"; exit 1; }
TE=$(gdalinfo "$refDem" 2>/dev/null | awk '/Upper Left/{gsub(/[(),]/," ");ulx=$3;uly=$4}/Lower Right/{gsub(/[(),]/," ");lrx=$3;lry=$4}END{print ulx,lry,lrx,uly}')

# BA-adjusted camera for a framelet stem, looked up from the BA's own 1-1 lists (robust to run- prefix).
cam_of(){
  local i
  i=$(awk -v n="$1" '{b=$0; sub(/.*\//,"",b); sub(/\.[^.]*$/,"",b); if(b==n){print NR; exit}}' "$imgList" 2>/dev/null)
  [ -n "$i" ] && sed -n "${i}p" "$camList" 2>/dev/null
}

# --- 1. mapproject each framelet (from the BA image list) with its BA cam onto the mapprojDem (parallel pool) ---
THR=$(nproc 2>/dev/null || echo 8); [ "$THR" -gt 128 ] && THR=128
MK=$(( THR > 8 ? 8 : THR )); [ "$MK" -lt 1 ] && MK=1; MT=$(( THR / MK )); [ "$MT" -lt 1 ] && MT=1; [ "$MT" -gt 8 ] && MT=8
map_one(){
  local c=$1 nm cam
  nm=$(basename "${c%.cub}"); cam=$(cam_of "$nm")
  [ -s "$cam" ] || { echo "  no BA cam for $nm"; return 0; }
  [ -s "$out/maps/$nm.tif" ] && return 0
  mapproject --threads $MT --tr $res "$mapprojDem" "$c" "$cam" "$out/maps/$nm.tif" >/dev/null 2>&1 \
    || echo "  mapproj FAIL $nm"
  return 0
}
echo "=== [1] mapproject $(wc -l < "$imgList") framelets with BA cams (MK=$MK x MT=$MT threads) ==="
mrun=0
while read -r c; do
  [ -e "$c" ] || continue
  map_one "$c" &
  mrun=$((mrun+1)); [ "$mrun" -ge "$MK" ] && { wait -n 2>/dev/null || true; mrun=$((mrun-1)); }
done < "$imgList"
wait
echo "  mapped: $(ls $out/maps/*.tif 2>/dev/null | wc -l) framelets"

# img (cub) path for a framelet stem, from the input image list (1-1 with camList) - dense same-look needs it.
img_of(){ awk -v n="$1" '{b=$0; sub(/.*\//,"",b); sub(/\.[^.]*$/,"",b); if(b==n){print; exit}}' "$imgList" 2>/dev/null; }

# write the fixed-param env file that each cassis_stereo_pair.sh worker sources (GNU parallel carries
# nothing itself; the worker sets its own ASP env and reads these).
write_pair_env(){
  local T=${1:-2}
  cat > "$out/pair.env" <<ENV
out='$out'
geounc='$geounc'
mapprojDem='$mapprojDem'
nmd='$num_matches_from_disp'
PROJ='$PROJ'
demRes='$demRes'
matchPrefix='$matchPrefix'
imgList='$imgList'
camList='$camList'
T='$T'
ENV
}

# ============================ DENSE MODE (num_matches_from_disp > 0): emit matches, no DEM ============
if [ "${num_matches_from_disp:-0}" -gt 0 ] 2>/dev/null; then
  echo "=== DENSE MODE: num_matches_from_disp=$num_matches_from_disp geounc(collar)=$geounc (emit matches) ==="
  mkdir -p "$(dirname "$matchPrefix")"
  # pairing from the mapprojected footprints (ordered by along-strip footprint centroid, naming-
  # agnostic). LR = cross-look: for each L keep its best-overlap R (top-6 by overlap fraction + top-3
  # regardless, for thin-overlap survival). same-look = adjacent by along-strip order.
  python3 - "$out/maps" "$Llook" "$Rlook" "$out/pairs_lr.txt" "$out/pairs_same.txt" <<'PY'
import sys, glob, os
from osgeo import gdal
gdal.UseExceptions()
mapd, Ltok, Rtok, pf_lr, pf_same = sys.argv[1:6]
def ext(f):
    d=gdal.Open(f); g=d.GetGeoTransform(); X,Y=d.RasterXSize,d.RasterYSize
    x0,x1=g[0],g[0]+g[1]*X; y0,y1=g[3],g[3]+g[5]*Y
    return (min(x0,x1),min(y0,y1),max(x0,x1),max(y0,y1))
fs={os.path.basename(f)[:-4]:ext(f) for f in glob.glob(mapd+'/*.tif')}
def cy(n): b=fs[n]; return (b[1]+b[3])/2.0    # along-strip position = footprint centroid Y
L=sorted([n for n in fs if Ltok in n], key=cy); R=sorted([n for n in fs if Rtok in n], key=cy)
def frac(a,b):
    ix=max(0,min(a[2],b[2])-max(a[0],b[0])); iy=max(0,min(a[3],b[3])-max(a[1],b[1]))
    ia=ix*iy; aa=(a[2]-a[0])*(a[3]-a[1]); bb=(b[2]-b[0])*(b[3]-b[1])
    return ia/max(1e-9,min(aa,bb))
same=[]
for grp in (L,R):
    for i in range(len(grp)-1): same.append((grp[i],grp[i+1]))
lr=[]
for li in L:                                      # each L vs ALL R, keep the best-overlap ones
    ov=sorted(((frac(fs[li],fs[rj]),rj) for rj in R),reverse=True)
    keep=[rj for f,rj in ov if f>0.04][:6]        # up to 6 with real overlap
    for f,rj in ov[:3]:                           # plus top-3 regardless (thin-overlap survival)
        if rj not in keep: keep.append(rj)
    for rj in keep: lr.append((li,rj))
def dd(ps):
    s=set(); u=[]
    for a,b in ps:
        k=tuple(sorted((a,b)))
        if k not in s: s.add(k); u.append((a,b))
    return u
same=dd(same); lr=dd(lr)
open(pf_lr,'w').write('\n'.join('%s %s'%p for p in lr)+('\n' if lr else ''))
open(pf_same,'w').write('\n'.join('%s %s'%p for p in same)+('\n' if same else ''))
print("  pairs: LR %d  same-look %d (LL+RR)"%(len(lr),len(same)))
PY
  Td=2; cores=$(nproc 2>/dev/null || echo 4)
  [ -n "$PBS_JOBID" ] && [ -r "$PBS_NODEFILE" ] && cores=$(wc -l < "$PBS_NODEFILE")
  case "$cores" in ''|*[!0-9]*) cores=28 ;; esac
  Kd=$(( cores / Td )); [ "$Kd" -lt 1 ] && Kd=1; [ "$Kd" -gt 128 ] && Kd=128
  # per-pair worker + GNU parallel (single node -> local; the worker is self-contained so parallel
  # carries nothing). The env file holds the fixed params; --joblog records per-pair time + exit.
  write_pair_env "$Td"
  echo "  dense stereo via GNU parallel: -j $Kd (T=$Td) using $(command -v parallel)"
  echo "  [LR phase]"
  parallel -j "$Kd" --colsep ' ' --joblog "$out/joblog_lr.txt" \
    bash cassis_stereo_pair.sh lr {1} {2} "$out/pair.env" < "$out/pairs_lr.txt"
  echo "  [same-look phase]"
  parallel -j "$Kd" --colsep ' ' --joblog "$out/joblog_same.txt" \
    bash cassis_stereo_pair.sh same {1} {2} "$out/pair.env" < "$out/pairs_same.txt"
  echo "  dense matches emitted: $(ls ${matchPrefix}-*.match 2>/dev/null | wc -l)"
  echo "CASSIS_STEREO_DONE (dense) $pairDir $tag $(date)"
  exit 0
fi

# ============================ DEM MODE (num_matches_from_disp == 0): the original validated path ======
# --- 2. cross-look (L-R) pairs: L stems (contain Llook) x R stems (contain Rlook); a pair exists iff the
#     dense match file <matchPrefix>-<Lstem>__<Rstem>.match exists. No stem parsing, no obsID hardcode. ---
stems=$(awk '{b=$0;sub(/.*\//,"",b);sub(/\.[^.]*$/,"",b);print b}' "$imgList")
Lstems=$(echo "$stems" | grep -F "$Llook")
Rstems=$(echo "$stems" | grep -F "$Rlook")
pf=$out/pairs_long.txt; : > "$pf"
for L in $Lstems; do
  for R in $Rstems; do
    [ -s "${matchPrefix}-${L}__${R}.match" ] && echo "$L $R" >> "$pf"
  done
done
nx=$(wc -l < "$pf")
echo "=== [2] $nx cross-look L-R pairs (match-file-verified) ==="
[ "$nx" -ge 1 ] || { echo "ERROR no LR pairs derived"; exit 1; }

# --- 3. per-pair stereo (mapprojected, alignment none) + point2dem --errorimage ---
T=2
if [ -n "$PBS_JOBID" ]; then
  cores=$( { [ -r "$PBS_NODEFILE" ] && wc -l < "$PBS_NODEFILE"; } 2>/dev/null || nproc 2>/dev/null )
  case "$cores" in ''|*[!0-9]*) cores=28 ;; esac
  K=$(( cores / T ))
else
  cores=$(nproc 2>/dev/null || echo 4); K=$(( cores / T ))
fi
[ "$K" -lt 1 ] && K=1; [ "$K" -gt 128 ] && K=128
# per-pair worker (cassis_stereo_pair.sh mode=dem: parallel_stereo + point2dem, args as recipe) run
# via GNU parallel. --min-matches 5 + --ip-per-tile 2000 + --ip-match-radius 20 + max-valid-tri-err 8
# live in the worker. --joblog records per-pair time + exit for the metrics.
echo "=== [3] stereo via GNU parallel: -j $K (T=$T, cores=$cores) using $(command -v parallel) ==="
write_pair_env "$T"
parallel -j "$K" --colsep ' ' --joblog "$out/joblog_dem.txt" \
  bash cassis_stereo_pair.sh dem {1} {2} "$out/pair.env" < "$pf"

# --- 4. blunder filter (mean elev within +/-500 m of median) + dem_mosaic -> frame DEM ---
dems=$(python3 -c "
import subprocess,re,statistics,sys
# explicit per-pair DEM paths from the pairs list - NO glob
items=[]
for line in open('$pf'):
    p=line.split()
    if len(p)!=2: continue
    d='$out/stereo/%s__%s/dem-DEM.tif'%(p[0],p[1])
    o=subprocess.run(['gdalinfo','-stats',d],capture_output=True,text=True).stdout
    m=re.search(r'STATISTICS_MEAN=(-?[0-9.]+)',o)
    if m: items.append((float(m.group(1)),d))
if items:
    med=statistics.median([v for v,_ in items])
    keep=[d for v,d in items if abs(v-med)<=500]
    drop=[d.split('/')[-2] for v,d in items if abs(v-med)>500]
    import sys; sys.stderr.write(f'  blunder filter: kept {len(keep)}/{len(items)}, dropped {len(drop)}\n')
    print(' '.join(keep))
")
nd=$(echo "$dems" | wc -w | tr -d ' ')
echo "=== [4] dem_mosaic $nd per-pair DEMs (blunders filtered) -> frame DEM ==="
[ "$nd" -gt 0 ] || { echo "ERROR no per-pair DEMs to mosaic"; exit 1; }
mos=$out/cassis_dem
dem_mosaic $dems --t_srs "$PROJ" --tr $demRes -o ${mos}.tif > $out/mosaic.log 2>&1 \
  || { echo "MOSAIC FAILED"; tail -5 $out/mosaic.log; exit 1; }
# ALWAYS -r cubicspline, never the gdalwarp default nearest-neighbor (nearest snaps/misregisters
# a continuous DEM by up to half a pixel). CLAUDE.md rule.
gdalwarp -q -overwrite -t_srs "$PROJ" -te $TE -tr $demRes $demRes -r cubicspline ${mos}.tif ${mos}_on_ctx.tif \
  || echo "  WARN on_ctx regrid failed (set PROJ_LIB, redo by hand)"
gdaldem hillshade -az 300 -alt 25 -compute_edges ${mos}_on_ctx.tif ${mos}_on_ctx_hs.tif >/dev/null 2>&1 || true
geodiff ${mos}_on_ctx.tif "$refDem" -o ${mos}_ctxdiff >/dev/null 2>&1 || true

# --- 5. max tri-error mosaic (ray self-consistency; same blunder-filtered pairs) ---
errmos=$out/max_tri_err
errs=$(echo "$dems" | sed 's/dem-DEM\.tif/dem-IntersectionErr.tif/g')
dem_mosaic --threads $THR --max $errs --t_srs "$PROJ" --tr $demRes -o ${errmos}.tif >> $out/mosaic.log 2>&1 \
  && gdalwarp -q -overwrite -t_srs "$PROJ" -te $TE -tr $demRes $demRes -r cubicspline ${errmos}.tif ${errmos}_on_ctx.tif >/dev/null 2>&1 \
  && echo "  max tri-error mosaic: ${errmos}_on_ctx.tif" \
  || echo "  WARN max_tri_err mosaic skipped"

echo "  frame DEM: ${mos}_on_ctx.tif"
echo "  geodiff std vs CTX (vertical, m): $(gdalinfo -stats ${mos}_ctxdiff-diff.tif 2>/dev/null | grep STATISTICS_STDDEV | sed 's/.*=//')"
echo "CASSIS_STEREO_DONE $pairDir $tag $(date)"
