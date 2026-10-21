#!/bin/bash
# Drives the agent's prefs, notification, and assertion path under a scratch HOME. It holds a sleep assertion for a
# few seconds. The agent runs through scripts/sandboxed.sh, so it cannot change SleepDisabled.
set -euo pipefail
cd "$(dirname "$0")/.."
agent=${1:-build/HomeAwake.app/Contents/MacOS/homeawake-agent}

home=$(mktemp -d)
support="$home/Library/Application Support/HomeAwake"
mkdir -p "$support"
trap 'kill -TERM $pid 2>/dev/null || true; rm -rf "$home"' EXIT
assertions() { pmset -g assertions | grep -c "pid $pid(homeawake-agent).*PreventUserIdleSystemSleep" || true; }
expect() { [ "$2" = "$3" ] && echo "ok: $1" || { echo "FAIL: $1 (got $2, want $3)"; exit 1; }; }
prefs() { printf '%s' "$1" > "$support/prefs.json"; notifyutil -p dev.homeawake.prefs; sleep 0.5; }
sleep_disabled() { pmset -g | awk '/SleepDisabled/ {print $2}'; }

router=$(scutil <<< 'show State:/Network/Global/IPv4' | awk '/Router/ {print $3}')
mac=$(arp -n "$router" | awk '{print $4}')
printf '{"enabled": true, "homes": ["%s"]}' "$mac" > "$support/prefs.json"
before=$(sleep_disabled)

HOME="$home" scripts/sandboxed.sh "$agent" 2> "$home/stderr" & pid=$!
sleep 1
expect "status.json names this network" "$(grep -c '"network"' "$support/status.json")" 1
expect "home network on AC holds one assertion" "$(assertions)" 1

prefs '{"enabled": false, "homes": []}'
expect "pause releases it" "$(assertions)" 0

prefs "{\"enabled\": true, \"homes\": [\"$mac\"]}"
expect "resume takes it again" "$(assertions)" 1
notifyutil -p dev.homeawake.prefs; notifyutil -p dev.homeawake.prefs; sleep 0.5
expect "repeated reconciles keep exactly one" "$(assertions)" 1

kill -TERM $pid; wait $pid && status=0 || status=$?
expect "SIGTERM exits 0" "$status" 0
expect "and the assertion is gone" "$(pmset -g assertions | grep -c "pid $pid(" || true)" 0
expect "SleepDisabled unchanged" "$(sleep_disabled)" "$before"
expect "agent logged nothing (no sudo attempt)" "$(wc -c < "$home/stderr" | tr -d ' ')" 0
