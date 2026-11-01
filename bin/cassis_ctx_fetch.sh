#!/bin/bash
# cassis_ctx_fetch.sh <ctxDir> <footprintDEM> <clat> <clon> - fetch the controlled CTX DTMs for a site.
#
# All CTX-reference work is two steps: FETCH then PROCESS. This is the FETCH step and must run on a machine
# with network access (on pfe that is the HEAD NODE): it computes the box from the footprint, queries the
# USGS STAC for the controlled CTX DTMs intersecting that box, and downloads them. It is light (a tiny warp
# plus network), no heavy compute. The PROCESS step (warp, cull, feather, blur5) is cassis_ctx_blend.sh and
# belongs on a compute node (qsub). The two share <ctxDir>.
#
# Writes under <ctxDir>:
#   box_te.txt     one line "xmin ymin xmax ymax" (projected meters) = the BOX_FACTOR x footprint crop box.
#   ctx_list.txt   the selected DTMs, one "id<TAB>href" per line (cached - skips the STAC query if present).
#   dl/<id>_dem.tif  each downloaded controlled-CTX DTM (the 'dem' = sphere/ellipsoid asset, not the areoid).
#
# BOX_FACTOR (env, default 3): the box is this multiple of the footprint. The measured CaSSIS-to-CTX pointing
# offset is ~8-15 km, so 3x covers it several times over; larger just downloads unused far-margin tiles.
# CTX_MAXDTM (env, default 400): cap on the number of DTMs (nearest-to-center first). The STAC bbox query is
# overlap-complete, so every DTM intersecting the box is a candidate; never cap by name (that can drop the
# very strips over the footprint and fake a data gap).
#
# The <footprint> argument is EITHER a DEM file (the vendor or linescan DEM) OR, when there is no such DEM
# yet, a bounding box written as  bbox:minLon,minLat,maxLon,maxLat  (east longitudes, degrees). The bbox
# form is for a new site processed from scratch: the linescan DEM cannot be built before the CTX exists (it
# needs the CTX grid), and there may be no prior vendor DEM, so the footprint is seeded from the observation
# footprint published by ODE. A tiny constant stand-in raster is synthesized over that bbox and used exactly
# as a DEM file would be (only its extent matters). The coordinates come from the stereo-pair record (ODE /
# the pair inventory); bbox and clat/clon describe the same footprint.
#
# gdalwarp/gdalinfo/gdal_create and python3 (urllib) must be on PATH, with curl for the downloads. The caller
# sets up the environment; this script hardcodes no paths.
set -e; umask 022
ctxDir=${1:?ctxDir (output dir)}
footprint=${2:?footprintDEM file OR bbox:minLon,minLat,maxLon,maxLat (defines the box)}
clat=${3:?clat (site center latitude)}
clon=${4:?clon (site center longitude)}
mkdir -p "$ctxDir/dl"
PROJ="+proj=stere +lat_0=$clat +lon_0=$clon +k=1 +x_0=0 +y_0=0 +R=3396190 +units=m +no_defs"
TRC=18

# Vendor-free footprint: synthesize a constant stand-in raster over the given lon/lat bbox (Mars geographic)
# and use it as the footprint DEM. Only the extent is read downstream, so a 1-valued raster is sufficient.
case "$footprint" in
  bbox:*)
    IFS=, read -r MINLON MINLAT MAXLON MAXLAT <<<"${footprint#bbox:}"
    [ -n "$MAXLAT" ] || { echo "FATAL: bbox must be bbox:minLon,minLat,maxLon,maxLat"; exit 1; }
    standin="$ctxDir/_footprint_standin.tif"
    gdal_create -q -outsize 120 300 -a_srs "+proj=longlat +R=3396190 +no_defs" \
      -a_ullr "$MINLON" "$MAXLAT" "$MAXLON" "$MINLAT" -burn 1 -ot Float32 "$standin"
    echo "[fetch] vendor-free footprint stand-in over bbox [$MINLON,$MINLAT,$MAXLON,$MAXLAT] -> $standin"
    footprint="$standin"
    ;;
esac
[ -s "$footprint" ] || { echo "FATAL: footprint not found: $footprint"; exit 1; }

echo "[fetch 0] ${BOX_FACTOR:-3}x snapped box from the footprint ($(date))"
gdalwarp -q -overwrite -t_srs "$PROJ" -tr $TRC $TRC -r near "$footprint" "$ctxDir/_footprint_localgrid.tif" >/dev/null 2>&1
read TE0 TE1 TE2 TE3 BXW BXE BYS BYN <<<"$(python3 - "$ctxDir/_footprint_localgrid.tif" "$clat" "$clon" <<'PY'
import subprocess,re,sys,math,os
t=subprocess.check_output(["gdalinfo",sys.argv[1]]).decode()
ll=re.search(r"Lower Left\s+\(\s*([-\d.]+),\s*([-\d.]+)",t); ur=re.search(r"Upper Right\s+\(\s*([-\d.]+),\s*([-\d.]+)",t)
xmin,ymin=float(ll.group(1)),float(ll.group(2)); xmax,ymax=float(ur.group(1)),float(ur.group(2))
cx,cy=(xmin+xmax)/2,(ymin+ymax)/2
bf=float(os.environ.get('BOX_FACTOR','3')); hx,hy=(xmax-xmin)/2*bf,(ymax-ymin)/2*bf
snap9=lambda v:int(18*round((v-9)/18)+9)
bx0,bx1=snap9(cx-hx),snap9(cx+hx); by0,by1=snap9(cy-hy),snap9(cy+hy)
R=3396190.0; lat0=float(sys.argv[2]); lon0=float(sys.argv[3]); cosl=math.cos(math.radians(lat0))
lonW=lon0+bx0/(R*cosl)*180/math.pi; lonE=lon0+bx1/(R*cosl)*180/math.pi
print(bx0,by0,bx1,by1, round(lonW,4),round(lonE,4), round(lat0+by0/R*180/math.pi,4), round(lat0+by1/R*180/math.pi,4))
PY
)"
[ -n "$TE3" ] || { echo "FATAL: box computation failed"; exit 1; }
printf '%s %s %s %s\n' "$TE0" "$TE1" "$TE2" "$TE3" > "$ctxDir/box_te.txt"
echo "  box -te $TE0 $TE1 $TE2 $TE3  ($(( (TE2-TE0)/1000 )) x $(( (TE3-TE1)/1000 )) km)  STAC bbox [$BXW,$BYS,$BXE,$BYN]"

echo "[fetch 1] STAC select controlled-CTX 'dem' assets over the box (cap CTX_MAXDTM=${CTX_MAXDTM:-400}) ($(date))"
if [ -s "$ctxDir/ctx_list.txt" ]; then echo "  using cached ctx_list.txt (skip STAC query)"; else
python3 - "$ctxDir/ctx_list.txt" "$BXW" "$BYS" "$BXE" "$BYN" "$clon" "$clat" <<'PY'
import urllib.request,json,sys,os,time
out=sys.argv[1]; w,s,e,n=map(float,sys.argv[2:6]); lon0=float(sys.argv[6]); lat0=float(sys.argv[7])
cap=int(os.environ.get('CTX_MAXDTM','400'))
STAC="https://stac.astrogeology.usgs.gov/api/search"; coll="mro_ctx_controlled_usgs_dtms"
wrap=lambda l: l-360 if l>180 else l
# PAGINATE the STAC search. A single big limit:1000 bbox query 502s over very dense controlled-CTX regions
# (the gateway times out gathering the result), while a small page size always returns fast. So fetch in
# pages of STAC_PAGE (default 250), following the pgstac `next` link token, until no next page, no new
# features, or a page budget. Each page retries on a transient network blip. This keeps the query
# overlap-complete without ever asking the gateway for more than it can serialize at once.
page=int(os.environ.get('STAC_PAGE','250')); maxpages=int(os.environ.get('STAC_MAXPAGES','40'))
def post(url,body):
    req=urllib.request.Request(url,data=json.dumps(body).encode(),headers={"Content-Type":"application/json"})
    for attempt in range(1,7):
        try: return json.load(urllib.request.urlopen(req,timeout=120))
        except Exception as ex:
            if attempt==6: raise
            print("  STAC page attempt %d failed (%s); retrying in %ds"%(attempt,ex,5*attempt)); sys.stdout.flush()
            time.sleep(5*attempt)
url=STAC; body={"collections":[coll],"bbox":[wrap(w),s,wrap(e),n],"limit":page}; feats=[]
for pg in range(maxpages):
    d=post(url,body); got=d.get("features",[]); feats+=got
    nxt=next((l for l in d.get("links",[]) if l.get("rel")=="next"),None)
    if not got or not nxt: break
    url=nxt.get("href",STAC); body=nxt.get("body",body)   # follow the pgstac token page
else:
    print("  NOTE: hit STAC_MAXPAGES=%d page budget; selection may be truncated"%maxpages); sys.stdout.flush()
best={}
for f in feats:
    fid=f["id"]; a=f.get("assets",{}); href=None
    for k in ("dem","geoid_adjusted_dem","dtm"):   # prefer the sphere/ellipsoid 'dem' asset
        if k in a: href=a[k]["href"]; break
    if not href: continue
    bb=f.get("bbox",[0,0,0,0]); cx=(bb[0]+bb[2])/2.0; cy=(bb[1]+bb[3])/2.0
    best[fid]=((cx-lon0)**2+(cy-lat0)**2, href)   # proximity to center, used only for the cap
rows=sorted(((d,fid,href) for fid,(d,href) in best.items()))[:cap]
open(out,"w").write("".join(f"{fid}\t{href}\n" for _,fid,href in rows))
print("  available unique DTMs: %d ; selected %d (overlap-complete, nearest-first to the cap)"%(len(best),len(rows)))
PY
fi
NSEL=$(wc -l < "$ctxDir/ctx_list.txt"); echo "  selected: $NSEL DTMs"

echo "[fetch 2] download the raw DTMs ($(date))"
n=0; ok=0
while IFS=$'\t' read -r fid href; do
  [ -n "$href" ] || continue; n=$((n+1)); dst="$ctxDir/dl/${fid}_dem.tif"
  if [ -s "$dst" ] && gdalinfo "$dst" >/dev/null 2>&1; then ok=$((ok+1)); continue; fi
  # download to a .part, validate, then move into place, so dl/ only ever holds complete valid DTMs and no
  # rm of a variable path is needed (a failed .part is simply overwritten on the next run).
  # `|| true`: under set -e a transient non-zero curl (a blip, a timeout) must NOT abort the whole loop -
  # the gdalinfo check below decides success, and a failed DTM is simply reported and skipped.
  curl -s --max-time 900 --retry 4 --retry-delay 3 "$href" -o "$dst.part" || true
  if [ -s "$dst.part" ] && gdalinfo "$dst.part" >/dev/null 2>&1; then mv -f "$dst.part" "$dst"; ok=$((ok+1)); else echo "  FAIL $fid"; fi
done < "$ctxDir/ctx_list.txt"
echo "[fetch] DONE: have $ok / $n raw DTMs in $ctxDir/dl/  (next: cassis_ctx_blend.sh $ctxDir <tag> $clat $clon on a compute node)"
