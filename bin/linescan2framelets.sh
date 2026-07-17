#!/bin/bash
# Decompose the bundle-adjusted, CTX-aligned linescan states into per-framelet aligned FRAME
# cameras (the aligned_framelets). Each aligned framelet = the framelet cube's FRAME CSM state
# (correct CASSIS optics + distortion, from a 0-iteration bundle_adjust) with its pose REPLACED
# by the aligned linescan node for that framelet. So the framelets inherit the tie bundle
# adjustment and the CTX alignment; the per-framelet bundle starts already on CTX.
#
# Config-driven: reads pairDir + Llook/Rlook, derives the aligned-state path and the data dir,
# and does both looks in one call.
# Usage: linescan2framelets.sh <site.conf> <workdir>
set -e
umask 022
# ASP/ISIS tools on PATH and the environment are set up by the caller. See the README.
cfg=${1:?usage: linescan2framelets.sh <site.conf> <workdir>}
B=${2:?workdir}
cd "$B" || { echo "ERROR cannot cd $B"; exit 1; }
[ -s "$B/cassis_common.conf" ] && source "$B/cassis_common.conf"
[ -s "$B/$cfg" ] || { echo "ERROR missing site config $cfg"; exit 1; }
source "$B/$cfg"
data=data/$pairDir

for entry in "L $Llook" "R $Rlook"; do
  set -- $entry; look=$1; sid=$2
  out=$pairDir/frame/aligned_framelets/$sid
  state=$pairDir/linescan/linescan_dem/cams_aligned/run-run-${sid}_linescan.adjusted_state.json
  # Idempotent: if the aligned framelet states already exist, there is nothing to do.
  if ls "$out"/aligned-*.json >/dev/null 2>&1; then
    echo "aligned framelets exist, skipping: $out"; continue
  fi
  [ -s "$state" ] || { echo "ERROR: missing aligned linescan state $state"; exit 1; }
  mkdir -p "$out"

  # framelet cubes + ISDs, in framelet-index (=time) order
  cubes=$(ls $PWD/$data/L*_$sid/*-$sid-*-0__4_0.cub | sort -t- -k$(echo "$data/L*_$sid" | awk -F/ '{print NF+3}') 2>/dev/null || ls $PWD/$data/L*_$sid/*-$sid-*-0__4_0.cub)
  nc=$(echo "$cubes" | grep -c .)
  isds=$(for c in $cubes; do echo ${c%.cub}.json; done)
  echo "=== [aligned_framelets $look $sid] $nc framelet cubes ==="

  echo "=== [aligned_framelets] 0-iter BA: framelet cubes -> raw frame CSM states ==="
  bundle_adjust $cubes $isds --inline-adjustments --num-iterations 0 \
    --overlap-limit 1 --min-matches 0 --ip-per-image 500 -o $out/raw \
    > $out/ba0_log.txt 2>&1 || { echo "0-iter BA failed; see $out/ba0_log.txt"; tail -5 $out/ba0_log.txt; exit 1; }

  echo "=== [aligned_framelets] pose-swap raw frame states with aligned linescan nodes ==="
  python3 - "$state" "$out" "$sid" <<'PY'
import json, glob, re, sys
state_file, out, sid = sys.argv[1], sys.argv[2], sys.argv[3]
def load(f):
    t=open(f).read()
    try: return json.loads(t), False
    except: return json.loads(t.split('\n',1)[1]), True
ln,_ = load(state_file)
pos = ln['m_positions']; quat = ln['m_quaternions']   # node k <-> framelet k
nnodes = len(pos)//3
n = 0
for raw in sorted(glob.glob(f'{out}/raw-*-{sid}-*-0__4_0.adjusted_state.json')):
    k = int(re.search(rf'-{sid}-(\d+)-0__4_0', raw).group(1))
    if k >= nnodes:
        print(f"  WARN framelet {k} >= {nnodes} nodes, skip"); continue
    st, hashdr = load(raw)
    # frame param = [x,y,z, q0,q1,q2,q3]; replace with aligned linescan node k
    st['m_currentParameterValue'][0:3] = pos[3*k:3*k+3]
    st['m_currentParameterValue'][3:7] = quat[4*k:4*k+4]
    aligned = raw.replace('/raw-', '/aligned-')
    with open(aligned,'w') as f:
        if hashdr: f.write(st['m_modelName']+'\n')
        json.dump(st, f)
    n += 1
print(f"  wrote {n} aligned framelet states for {sid} (of {nnodes} nodes)")
PY
  echo "=== aligned framelet states: $(ls $out/aligned-*.json 2>/dev/null | wc -l | tr -d ' ') ==="
done
echo "ALIGNED_FRAMELETS_DONE $pairDir"
