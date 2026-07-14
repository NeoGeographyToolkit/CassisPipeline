#!/bin/bash
# Decompose a BA-tied + CTX-ALIGNED LINESCAN strip into per-framelet "baby" FRAME
# cameras. Adapted from the equivalent pushframe-state decomposition; the ONLY change is the pose source is
# the aligned LINESCAN adjusted_state.json instead of a pushframe state. Both store
# the per-framelet poses as m_positions (3*N) / m_quaternions (4*N) with node k <->
# framelet k (time-sorted, so reversal-safe; verified for the pushframe, and the
# linescan table was copied verbatim from it by pushframe2linescan.py). Each baby =
# the framelet cube's FRAME CSM state (correct CASSIS optics + distortion type 9,
# from a 0-iter ISD->state bundle_adjust) with its pose REPLACED by the aligned
# linescan node for that framelet. So babies inherit the tie BA + CTX-align
# registration -> the per-framelet bundle (S8) starts already on CTX.
# SHORT names (sl/L<k>, sl/R<k>) are applied LATER by the dense-match/bundle step to
# dodge the .match hash trap; here we keep the framelet-index naming.
# Usage: linescan2babyframes.sh <pairDir> <dataDir> <sid> <aligned_linescan_state> <look L|R>
#   pairDir  e.g. oxia_planum/MY34_003806_019
#   dataDir  e.g. data/oxia_planum/MY34_003806_019   (has L*_<sid>/)
#   sid      e.g. 276230221
#   state    e.g. <pairDir>/align_ctx/cams_aligned/run-run-276230221_linescan.adjusted_state.json
#   look     L or R (just for the output dir label)
set -e
CONDA=$HOME/anaconda3; [ -x "$HOME/miniconda3/bin/conda" ] && CONDA=$HOME/miniconda3
eval "$("$CONDA/bin/conda" shell.bash hook)"; conda activate asp_deps
export ISISROOT=$CONDA/envs/asp_deps ISISDATA=$HOME/projects/isis3data
export ALESPICEROOT=$HOME/projects/isis3data
export PATH=$HOME/projects/StereoPipeline/install/bin:$CONDA/envs/asp_deps/bin:$ISISROOT/bin:$PATH
cd ~/projects/cassis_asp

pairDir=$1; data=$2; sid=$3; state=$4; look=$5
[ -s "$state" ] || { echo "ERROR: missing aligned linescan state $state"; exit 1; }
out=$pairDir/frame/babies/$sid; mkdir -p "$out"

# framelet cubes + ISDs, in framelet-index (=time) order
cubes=$(ls $PWD/$data/L*_$sid/*-$sid-*-0__4_0.cub | sort -t- -k$(echo "$data/L*_$sid" | awk -F/ '{print NF+3}') 2>/dev/null || ls $PWD/$data/L*_$sid/*-$sid-*-0__4_0.cub)
nc=$(echo "$cubes" | grep -c .)
isds=$(for c in $cubes; do echo ${c%.cub}.json; done)
echo "=== [babies $look $sid] $nc framelet cubes ==="

echo "=== [babies] 0-iter BA: framelet cubes -> raw frame CSM states ==="
bundle_adjust $cubes $isds --inline-adjustments --num-iterations 0 \
  --overlap-limit 1 --min-matches 0 --ip-per-image 500 -o $out/raw \
  > $out/ba0_log.txt 2>&1 || { echo "0-iter BA failed; see $out/ba0_log.txt"; tail -5 $out/ba0_log.txt; exit 1; }

echo "=== [babies] pose-swap raw frame states with aligned linescan nodes ==="
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
    baby = raw.replace('/raw-', '/baby-')
    with open(baby,'w') as f:
        if hashdr: f.write(st['m_modelName']+'\n')
        json.dump(st, f)
    n += 1
print(f"  wrote {n} baby frame states for {sid} (of {nnodes} nodes)")
PY
echo "=== baby states: $(ls $out/baby-*.json 2>/dev/null | wc -l | tr -d ' ') ==="
echo "BABIES_DONE $sid $look"
