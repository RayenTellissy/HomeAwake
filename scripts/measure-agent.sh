#!/bin/bash
# Runs the sandboxed agent several times under a scratch HOME with no prefs, so it decides allowSleep and changes
# nothing. Each run prints phys_footprint at 10 s and idle wakeups and CPU time over the next 60 s, then the script
# prints the median and range. top's idlew is a running total, so a run's wakeups are its last sample minus its first.
set -euo pipefail
cd "$(dirname "$0")/.."
agent=${1:-build/HomeAwake.app/Contents/MacOS/homeawake-agent}
runs=${2:-5}

pid=
home=
trap '[ -z "$pid" ] || kill -TERM $pid 2>/dev/null || true; [ -z "$home" ] || rm -rf "$home"' EXIT
summary() { sort -n | awk '{v[NR] = $1} END {printf "median %s, range %s to %s, %d runs\n", v[int((NR + 1) / 2)], v[1], v[NR], NR}'; }

footprints=() wakeups=()
for run in $(seq "$runs"); do
    home=$(mktemp -d)
    HOME="$home" scripts/sandboxed.sh "$agent" & pid=$!
    sleep 10
    kb=$(( $(footprint -f bytes -p $pid | sed -n 's/.*Footprint: \([0-9]*\) B.*/\1/p') / 1024 ))
    rss=$(ps -o rss= -p $pid | tr -d ' ')
    samples=$(top -l 3 -s 30 -stats pid,command,cpu,idlew,power,time -pid $pid | awk -v pid=$pid '$1 == pid')
    idlew=$(( $(tail -1 <<< "$samples" | awk '{print $4}' | tr -dc 0-9) - $(head -1 <<< "$samples" | awk '{print $4}' | tr -dc 0-9) ))
    cpu=$(tail -1 <<< "$samples" | awk '{print $6}')
    kill -TERM $pid; wait $pid || { echo "FAIL: agent exited $? on SIGTERM"; exit 1; }
    pid=
    rm -rf "$home"
    home=
    echo "run $run: phys_footprint ${kb} KB, rss ${rss} KB, idle wakeups over 60 s: $idlew, cpu time: $cpu"
    footprints+=("$kb") wakeups+=("$idlew")
done
echo "phys_footprint KB: $(printf '%s\n' "${footprints[@]}" | summary)"
echo "idle wakeups per 60 s: $(printf '%s\n' "${wakeups[@]}" | summary)"
