#!/bin/bash
# cassis_ctx_build.sh - GENERAL CaSSIS CTX reference-DEM builder.
# Encodes the projection/datum/grid policy, the CTX stack formation logic, and the critical
# coverage gate. Two policy points: (i) pull the CTX "dem" asset (SPHERE/ellipsoid), NOT geoid_adjusted_dem
# (areoid); (ii) snap the -te to ODD multiples of 9 so the CTX grid matches the point2dem phase.
# Runs on L1 (bandwidth + storage + direct outside access). NEVER on the Mac (home line, tight disk).
#
# Args (all site-varying values explicit; algorithm constants are internal):
#   $1 VENDOR_DTM  path to the vendor CaSSIS CAS-DTM .tif (defines the footprint + box)
#   $2 LAT0        projection center latitude  (= vendor DEM center lat, from CAS-XML)
#   $3 LON0        projection center longitude (= vendor DEM center lonE)
#   $4 OUTDIR      output dir (e.g. ref/<site>_ctx)
#   $5 TAG         product name stem (e.g. the site short handle)
set +e; umask 022
VENDOR="$1"; LAT0="$2"; LON0="$3"; OUTDIR="$4"; TAG="$5"
[ -n "$TAG" ] || { echo "usage: cassis_ctx_build.sh VENDOR_DTM LAT0 LON0 OUTDIR TAG"; exit 1; }
# ASP/ISIS tools on PATH and environment are set up by the caller.
# Run this from your work directory. See the repository README.
W=$PWD
[ -s "$VENDOR" ] || { echo "FATAL: vendor DTM not found: $VENDOR"; exit 1; }
mkdir -p "$OUTDIR/dl"
log=$W/output_ctx_build_${TAG}.txt; exec > "$log" 2>&1
echo "=== [cassis_ctx_build $TAG] START $(date) host=$(uname -n) ==="

PROJ="+proj=stere +lat_0=$LAT0 +lon_0=$LON0 +k=1 +x_0=0 +y_0=0 +R=3396190 +units=m +no_defs"
TRC=18; KPERBIN=5      # 18 m grid only; CTX native ~20m -> 18m in ONE hop, NEVER down to 4.59 m
THRESH_STD=12; THRESH_MEAN=12; GROSS_STD=40; GROSS_MEAN=30; MIN_OVL_PCT=8; FLOOR=8

echo "--- [0] 6x snapped box from vendor footprint ($(date)) ---"
gdalwarp -q -overwrite -t_srs "$PROJ" -tr $TRC $TRC -r near "$VENDOR" "$OUTDIR/_vendor_localgrid.tif" >/dev/null 2>&1
read TE0 TE1 TE2 TE3 TSX TSY BXW BXE BYS BYN <<<"$(python3 - "$OUTDIR/_vendor_localgrid.tif" "$LAT0" "$LON0" <<'PY'
import subprocess,re,sys,math
t=subprocess.check_output(["gdalinfo",sys.argv[1]]).decode()
ll=re.search(r"Lower Left\s+\(\s*([-\d.]+),\s*([-\d.]+)",t); ur=re.search(r"Upper Right\s+\(\s*([-\d.]+),\s*([-\d.]+)",t)
xmin,ymin=float(ll.group(1)),float(ll.group(2)); xmax,ymax=float(ur.group(1)),float(ur.group(2))
cx,cy=(xmin+xmax)/2,(ymin+ymax)/2; hx,hy=(xmax-xmin)/2*6,(ymax-ymin)/2*6
snap9=lambda v:int(18*round((v-9)/18)+9)
bx0,bx1=snap9(cx-hx),snap9(cx+hx); by0,by1=snap9(cy-hy),snap9(cy+hy)
R=3396190.0; lat0=float(sys.argv[2]); lon0=float(sys.argv[3])
dlatS=by0/R*180/math.pi; dlatN=by1/R*180/math.pi
cosl=math.cos(math.radians(lat0))
lonW=lon0+bx0/(R*cosl)*180/math.pi; lonE=lon0+bx1/(R*cosl)*180/math.pi
print(bx0,by0,bx1,by1,(bx1-bx0)//18,(by1-by0)//18,round(lonW,4),round(lonE,4),round(lat0+dlatS,4),round(lat0+dlatN,4))
PY
)"
echo "  snapped -te: $TE0 $TE1 $TE2 $TE3   TS: $TSX x $TSY   ($(( (TE2-TE0)/1000 )) x $(( (TE3-TE1)/1000 )) km)"
echo "  STAC lon/lat bbox: [$BXW, $BYS, $BXE, $BYN]"
[ -n "$TE3" ] || { echo "FATAL: box computation failed"; exit 1; }

echo "--- [1] STAC select CTX 'dem' assets over box (K=$KPERBIN per 0.1-deg lat bin) ($(date)) ---"
python3 - "$OUTDIR/ctx_list.txt" "$KPERBIN" "$BXW" "$BYS" "$BXE" "$BYN" <<'PY'
import urllib.request,json,sys
from collections import defaultdict
out,K=sys.argv[1],int(sys.argv[2]); w,s,e,n=map(float,sys.argv[3:7])
STAC="https://stac.astrogeology.usgs.gov/api/search"; coll="mro_ctx_controlled_usgs_dtms"
wrap=lambda l: l-360 if l>180 else l
body={"collections":[coll],"bbox":[wrap(w),s,wrap(e),n],"limit":900}
req=urllib.request.Request(STAC,data=json.dumps(body).encode(),headers={"Content-Type":"application/json"})
feats=json.load(urllib.request.urlopen(req,timeout=120)).get("features",[])
best={}
for f in feats:
    fid=f["id"]; a=f.get("assets",{}); href=None
    for k in ("dem","geoid_adjusted_dem","dtm"):   # PREFER ellipsoid 'dem' (policy A1 fix)
        if k in a: href=a[k]["href"]; break
    bb=f.get("bbox",[None,None,None,None]); clat=(bb[1]+bb[3])/2 if bb[1] is not None else 0
    if href: best[fid]=(clat,href)
bins=defaultdict(list)
for fid,(clat,href) in best.items(): bins[round(clat*10)/10].append((fid,href))
sel=[]
for b in sorted(bins):
    for fid,href in sorted(bins[b])[:K]: sel.append((fid,href))
open(out,"w").write("".join(f"{fid}\t{href}\n" for fid,href in sel))
print("  available unique DTMs: %d ; selected %d across %d lat bins"%(len(best),len(sel),len(bins)))
PY
NSEL=$(wc -l < "$OUTDIR/ctx_list.txt"); echo "  selected: $NSEL DTMs"

echo "--- [2] download missing raw 'dem' DTMs ($(date)) ---"
n=0; ok=0
while IFS=$'\t' read -r fid href; do
  [ -n "$href" ] || continue; n=$((n+1)); dst="$OUTDIR/dl/${fid}_dem.tif"
  if [ -s "$dst" ] && gdalinfo "$dst" >/dev/null 2>&1; then ok=$((ok+1)); continue; fi
  curl -s --max-time 900 "$href" -o "$dst"
  if [ -s "$dst" ] && gdalinfo "$dst" >/dev/null 2>&1; then ok=$((ok+1)); else echo "  FAIL $fid"; rm -f "$dst"; fi
done < "$OUTDIR/ctx_list.txt"
echo "  have $ok / $n raw DTMs"

echo "--- [3] warp ALL raw DTMs to $TRC m (cheap, for curation) ($(date)) ---"
declare -A RAW; keepC=()
while IFS=$'\t' read -r fid href; do
  raw="$OUTDIR/dl/${fid}_dem.tif"; [ -s "$raw" ] || continue
  c="$OUTDIR/dl/${fid}_warpC.tif"
  [ -s "$c" ] || gdalwarp -q -overwrite -t_srs "$PROJ" -te $TE0 $TE1 $TE2 $TE3 -tr $TRC $TRC -r cubicspline "$raw" "$c" >/dev/null 2>&1
  [ -s "$c" ] && { keepC+=( "$c" ); RAW["$c"]="$raw"; }
done < "$OUTDIR/ctx_list.txt"
echo "  coarse-warped inputs: ${#keepC[@]}"
[ ${#keepC[@]} -ge 2 ] || { echo "FATAL: <2 inputs"; exit 1; }
NCAND=${#keepC[@]}

gd_stats () {
  local a="$1" cons="$2" gd info mn sd vp
  rm -f "$OUTDIR"/_bg_gd*.tif
  geodiff "$a" "$cons" -o "$OUTDIR/_bg_gd" >/dev/null 2>&1
  gd=$(ls "$OUTDIR"/_bg_gd*.tif 2>/dev/null | head -1); [ -n "$gd" ] || { echo "0 0 0"; return; }
  info=$(gdalinfo -stats "$gd" 2>/dev/null)
  mn=$(echo "$info" | sed -n 's/.*STATISTICS_MEAN=//p'   | head -1)
  sd=$(echo "$info" | sed -n 's/.*STATISTICS_STDDEV=//p' | head -1)
  vp=$(echo "$info" | sed -n 's/.*STATISTICS_VALID_PERCENT=//p' | head -1)
  rm -f "$gd" "$gd.aux.xml"; echo "${mn:-0} ${sd:-0} ${vp:-0}"
}

echo "--- pre-pass: drop ALL gross outliers (|mean|>$GROSS_MEAN or std>$GROSS_STD) ($(date)) ---"
rm -f "$OUTDIR"/_cons*.tif; dem_mosaic "${keepC[@]}" -o "$OUTDIR/_cons" >/dev/null 2>&1
cons="$(ls "$OUTDIR"/_cons*.tif | head -1)"; newC=()
for c in "${keepC[@]}"; do
  read mn sd vp <<<"$(gd_stats "$c" "$cons")"
  gross=$(python3 -c "m=abs(float('${mn:-0}' or 0)); s=float('${sd:-0}' or 0); print(1 if (m>$GROSS_MEAN or s>$GROSS_STD) else 0)")
  if [ "$gross" = 1 ]; then echo "  GROSS-DROP $(basename "$c") mean=$mn std=$sd ovl%=$vp"; else newC+=( "$c" ); fi
done
keepC=( "${newC[@]}" ); echo "  after gross pre-pass: ${#keepC[@]} (from $NCAND)"

round=0
while : ; do
  round=$((round+1)); echo "--- curate round $round: ${#keepC[@]} inputs ($(date)) ---"
  rm -f "$OUTDIR"/_cons*.tif; dem_mosaic "${keepC[@]}" -o "$OUTDIR/_cons" >/dev/null 2>&1
  cons="$(ls "$OUTDIR"/_cons*.tif | head -1)"; [ -n "$cons" ] || { echo "FATAL: consensus failed"; exit 1; }
  worst=""; worst_score=-1; worst_line=""; worst_gross=0
  for c in "${keepC[@]}"; do
    read mn sd vp <<<"$(gd_stats "$c" "$cons")"
    read gross drop score <<<"$(python3 -c "
m=abs(float('${mn:-0}' or 0)); s=float('${sd:-0}' or 0); v=float('${vp:-0}' or 0)
gross=1 if (m>$GROSS_MEAN or s>$GROSS_STD) else 0
mild =1 if (m>$THRESH_MEAN or s>$THRESH_STD) else 0
drop =1 if (gross or (mild and v>=$MIN_OVL_PCT)) else 0
print(gross, drop, (s+m) if drop else -1)")"
    printf "    %-60s mean=%8.3f std=%8.3f ovl%%=%6.2f %s\n" "$(basename "$c")" "${mn:-0}" "${sd:-0}" "${vp:-0}" "$([ "$gross" = 1 ] && echo '[GROSS]' || { [ "$drop" = 1 ] && echo '[mild-drop]' || echo '[ok]'; })"
    isworse=$(python3 -c "print(1 if $score > $worst_score else 0)")
    [ "$isworse" = 1 ] && { worst_score=$score; worst="$c"; worst_line="mean=$mn std=$sd ovl%=$vp"; worst_gross=$gross; }
  done
  if python3 -c "exit(0 if $worst_score>0 else 1)" && { [ ${#keepC[@]} -gt $FLOOR ] || [ "$worst_gross" = 1 ]; }; then
    lbl='mild'; [ "$worst_gross" = 1 ] && lbl='GROSS'
    echo "  DROP ($lbl) $(basename "$worst")  $worst_line"
    new=(); for c in "${keepC[@]}"; do [ "$c" = "$worst" ] || new+=( "$c" ); done; keepC=( "${new[@]}" )
  else
    echo "  CLEAN: nothing droppable (floor $FLOOR). Kept ${#keepC[@]}."; break
  fi
done

echo "=== final kept set (${#keepC[@]} of $NCAND) ==="
for c in "${keepC[@]}"; do echo "  $(basename "${RAW[$c]}")"; done

# [4] Build the stack DIRECTLY at 18 m. The kept curation warps (keepC = *_warpC.tif) were already
# regridded native ~20 m -> 18 m in step [3], so we just mean-mosaic THEM. We do NOT go to 4.59 m:
# CTX native GSD is ~20 m, so 4.59 m is pure interpolation, and going FINER then back to 18 m forces
# per-coarse-pixel averaging on the way down (lossy, undesirable) - Oleg 2026-07-11. One hop: 20->18.
echo "--- [4] mean-mosaic the kept 18 m curation warps -> clean 18 m stack (native ~20m -> 18m, NO 4.59m) ($(date)) ---"
rm -f "$OUTDIR"/_c18*.tif
dem_mosaic "${keepC[@]}" -o "$OUTDIR/_c18" >/dev/null 2>&1
mv "$(ls "$OUTDIR"/_c18*.tif | head -1)" "$OUTDIR/${TAG}_ctx_18m.tif"
dem_mosaic --dem-blur-sigma 5 "$OUTDIR/${TAG}_ctx_18m.tif" -o "$OUTDIR/_cb18" >/dev/null 2>&1
mv "$(ls "$OUTDIR"/_cb18*.tif | head -1)" "$OUTDIR/${TAG}_ctx_18m_blur5.tif"
gdaldem hillshade -multidirectional -compute_edges "$OUTDIR/${TAG}_ctx_18m.tif" "$OUTDIR/${TAG}_ctx_18m_hillshade.tif" >/dev/null 2>&1

echo "--- [D8] CRITICAL COVERAGE GATE: does the stack cover the vendor footprint? ($(date)) ---"
# Margin note (Oleg): CaSSIS vs CTX can be misaligned a few hundred m up to ~1 km. The 6x box puts the
# vendor deep inside, so the real test is a HOLE in the stack over the vendor area, not exact overlap.
# Coverage = valid% where BOTH vendor and stack are valid, divided by vendor's own valid% (no osgeo:
# geodiff is valid only where both inputs are valid, so its VALID_PERCENT gives the intersection).
gdalwarp -q -overwrite -t_srs "$PROJ" -te $TE0 $TE1 $TE2 $TE3 -tr $TRC $TRC -r near "$VENDOR" "$OUTDIR/_vendor_on_stackgrid.tif" >/dev/null 2>&1
vp_v=$(gdalinfo -stats "$OUTDIR/_vendor_on_stackgrid.tif" 2>/dev/null | sed -n 's/.*STATISTICS_VALID_PERCENT=//p' | head -1)
rm -f "$OUTDIR"/_d8gd*.tif
geodiff "$OUTDIR/_vendor_on_stackgrid.tif" "$OUTDIR/${TAG}_ctx_18m.tif" -o "$OUTDIR/_d8gd" >/dev/null 2>&1
d8=$(ls "$OUTDIR"/_d8gd*.tif 2>/dev/null | head -1)
vp_b=$(gdalinfo -stats "$d8" 2>/dev/null | sed -n 's/.*STATISTICS_VALID_PERCENT=//p' | head -1)
rm -f "$OUTDIR"/_d8gd*.tif "$OUTDIR"/_d8gd*.tif.aux.xml
python3 -c "
vv=float('${vp_v:-0}' or 0); vb=float('${vp_b:-0}' or 0)
cov=100.0*vb/vv if vv>0 else 0.0
print('  vendor valid%%=%.3f  both-valid%%=%.3f  ->  COVERAGE = %.3f%% of vendor footprint'%(vv,vb,cov))
print('  *** D8 GATE: %s ***' % ('PASS (>=99%% - vendor sits inside the stack)' if cov>=99.0 else ('MARGINAL (%.2f%% - inspect the hole location)'%cov if cov>=95.0 else 'FAIL - real HOLE over vendor footprint; abandon site, go to next')))
"

echo "--- [5] final stats ($(date)) ---"
for f in ${TAG}_ctx_18m.tif ${TAG}_ctx_18m_blur5.tif; do
  echo "  $f:"; gdalinfo -stats "$OUTDIR/$f" 2>/dev/null | grep -aE "Size is|VALID_PERCENT|STATISTICS_(MEAN|STDDEV|MIN|MAX)" | sed 's/^/     /'
done
echo "=== [cassis_ctx_build $TAG] DONE $(date) ==="
echo "CASSIS_CTX_BUILD_DONE"
