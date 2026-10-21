#!/bin/bash
# Runs the agent for 70 s under a scratch HOME with no prefs (so it decides allowSleep and changes nothing), then
# prints phys_footprint at 10 s and idle wakeups and CPU over the next 60 s. top's idlew is a running total, so the
# window's wakeups are the last sample minus the first.
set -euo pipefail
cd "$(dirname "$0")/.."
agent=${1:-build/HomeAwake.app/Contents/MacOS/homeawake-agent}
[ ! -e /etc/sudoers.d/homeawake ] || { echo "refusing: /etc/sudoers.d/homeawake exists"; exit 1; }

home=$(mktemp -d)
HOME="$home" "$agent" & pid=$!
trap 'kill -TERM $pid 2>/dev/null || true; rm -rf "$home"' EXIT
python3 -c "import time; time.sleep(10)"

footprint=$(footprint -p $pid | sed -n 's/.*Footprint: \([0-9]* [KMG]B\).*/\1/p')
rss=$(ps -o rss= -p $pid | tr -d ' ')
samples=$(top -l 3 -s 30 -stats pid,command,cpu,idlew,power,time -pid $pid | awk -v pid=$pid '$1 == pid')
echo "pid=$pid phys_footprint=$footprint rss_kb=$rss"
echo "top samples (pid command cpu idlew power time), first has no interval:"
echo "$samples"
