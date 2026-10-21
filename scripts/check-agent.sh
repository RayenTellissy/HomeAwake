#!/bin/bash
# Drives the agent's prefs, notification, and assertion path under a scratch HOME. It holds a sleep assertion for a
# few seconds. The agent runs in a sandbox that cannot exec sudo or pmset, so it cannot change SleepDisabled even on
# a Mac where some sudoers rule allows it.
set -euo pipefail
cd "$(dirname "$0")/.."
agent=${1:-build/HomeAwake.app/Contents/MacOS/homeawake-agent}

no_exec() { printf '(version 1)(allow default)'; for p in "$@"; do printf '(deny process-exec (literal "%s"))' "$p"; done; }
sandbox-exec -p "$(no_exec /usr/bin/true)" /usr/bin/true 2>/dev/null && { echo "FAIL: sandbox does not block exec"; exit 1; }

home=$(mktemp -d)
support="$home/Library/Application Support/HomeAwake"
mkdir -p "$support"
trap 'kill -TERM $pid 2>/dev/null || true; rm -rf "$home"' EXIT
pause() { python3 -c "import time; time.sleep($1)"; }
assertions() { pmset -g assertions | grep -c "pid $pid(homeawake-agent).*PreventUserIdleSystemSleep" || true; }
expect() { [ "$2" = "$3" ] && echo "ok: $1" || { echo "FAIL: $1 (got $2, want $3)"; exit 1; }; }
prefs() { printf '%s' "$1" > "$support/prefs.json"; notifyutil -p dev.homeawake.prefs; pause 0.5; }
sleep_disabled() { pmset -g | awk '/SleepDisabled/ {print $2}'; }

router=$(scutil <<< 'show State:/Network/Global/IPv4' | awk '/Router/ {print $3}')
mac=$(arp -n "$router" | awk '{print $4}')
printf '{"enabled": true, "homes": ["%s"]}' "$mac" > "$support/prefs.json"
before=$(sleep_disabled)

HOME="$home" sandbox-exec -p "$(no_exec /usr/bin/sudo /usr/bin/pmset)" "$agent" 2> "$home/stderr" & pid=$!
pause 1
expect "status.json names this network" "$(grep -c '"network"' "$support/status.json")" 1
expect "home network on AC holds one assertion" "$(assertions)" 1

prefs '{"enabled": false, "homes": []}'
expect "pause releases it" "$(assertions)" 0

prefs "{\"enabled\": true, \"homes\": [\"$mac\"]}"
expect "resume takes it again" "$(assertions)" 1
notifyutil -p dev.homeawake.prefs; notifyutil -p dev.homeawake.prefs; pause 0.5
expect "repeated reconciles keep exactly one" "$(assertions)" 1

kill -TERM $pid; wait $pid && status=0 || status=$?
expect "SIGTERM exits 0" "$status" 0
expect "and the assertion is gone" "$(pmset -g assertions | grep -c "pid $pid(" || true)" 0
expect "SleepDisabled unchanged" "$(sleep_disabled)" "$before"
expect "agent logged nothing (no sudo attempt)" "$(wc -c < "$home/stderr" | tr -d ' ')" 0
