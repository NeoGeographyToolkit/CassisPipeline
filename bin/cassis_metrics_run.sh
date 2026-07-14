#!/bin/bash
# cassis_metrics_run.sh - run cassis_process.sh with per-stage metrics. Starts a background node
# sampler (load, RAM, cpupercent every 30s) alongside the pipeline, so utilization can be sliced by
# stage using cassis_process's own stage START/DONE timestamps. Dumps final qstat resources at the end.
# Args (B LAST): <cfg> <fromStage> <toStage> <tagBase> <B>
set +e; umask 022
cfg=${1:?cfg}; from=${2:?fromStage}; to=${3:?toStage}; tagBase=${4:?tagBase}; B=${5:?B (LAST)}
# The ASP and ISIS tools must be on PATH and the environment set up beforehand.
# See the repository README, Environment section.
cd "$B" || { echo "ERROR cannot cd $B"; exit 1; }
nick=$(basename "$cfg" .conf | sed 's/^cassis_site_//')
mdir=$B/metrics_${nick}; mkdir -p "$mdir"
samp=$mdir/sampler.log; : > "$samp"
mlog=$mdir/run.log; exec > "$mlog" 2>&1
echo "=== metrics run START $(date) host=$(uname -n) nick=$nick stages $from..$to job=$PBS_JOBID ==="

# background node sampler: epoch, time, load, mem used/total, job cpupercent (cores busy = /100)
( while true; do
    ts=$(date +%s); dt=$(date '+%H:%M:%S')
    la=$(uptime 2>/dev/null | sed 's/.*age[s]*: *//' | cut -d, -f1 | tr -d ' ')
    mem=$(free -m 2>/dev/null | awk '/Mem:/{printf "%s/%sMB", $3, $2}')
    cpu=$(/PBS/bin/qstat -f "$PBS_JOBID" 2>/dev/null | sed -n 's/.*resources_used.cpupercent = //p' | head -1)
    echo "$ts $dt load=${la:-NA} mem=${mem:-NA} cpupercent=${cpu:-NA}" >> "$samp"
    sleep 30
  done ) &
SPID=$!

t0=$(date +%s)
bash cassis_process.sh "$cfg" "$from" "$to" "$tagBase" "$B"
rc=$?
kill "$SPID" 2>/dev/null
echo "=== metrics run DONE rc=$rc $(date) total=$(( $(date +%s) - t0 ))s ==="
echo "--- final qstat resources_used ---"
/PBS/bin/qstat -f "$PBS_JOBID" 2>/dev/null | grep -aE "resources_used" | tee "$mdir/qstat_final.txt"
echo "--- per-stage elapsed (from cassis_process log) ---"
grep -aE "STAGE .* (START|DONE)" "$B"/output_${nick}_process_${from}_${to}.txt 2>/dev/null
echo "METRICS_RUN_DONE $nick rc=$rc"
