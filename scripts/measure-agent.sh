#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/scratch-agent.sh
runs=${2:-5}

summary() { sort -n | awk '{v[NR] = $1} END {printf "median %s, range %s to %s, %d runs\n", v[int((NR + 1) / 2)], v[1], v[NR], NR}'; }

footprints=() wakeups=()
for run in $(seq "$runs"); do
    rm -rf "$support"
    start
    sleep 9
    kb=$(( $(footprint -f bytes -p $pid | sed -n 's/.*Footprint: \([0-9]*\) B.*/\1/p') / 1024 ))
    rss=$(ps -o rss= -p $pid | tr -d ' ')
    samples=$(top -l 3 -s 30 -stats pid,command,cpu,idlew,power,time -pid $pid | awk -v pid=$pid '$1 == pid')
    idlew=$(( $(tail -1 <<< "$samples" | awk '{print $4}' | tr -dc 0-9) - $(head -1 <<< "$samples" | awk '{print $4}' | tr -dc 0-9) ))
    cpu=$(tail -1 <<< "$samples" | awk '{print $6}')
    stop
    echo "run $run: phys_footprint ${kb} KB, rss ${rss} KB, idle wakeups over 60 s: $idlew, cpu time: $cpu"
    footprints+=("$kb") wakeups+=("$idlew")
done
echo "phys_footprint KB: $(printf '%s\n' "${footprints[@]}" | summary)"
echo "idle wakeups per 60 s: $(printf '%s\n' "${wakeups[@]}" | summary)"
