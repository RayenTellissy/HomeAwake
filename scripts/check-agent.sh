#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
agent=${1:-build/HomeAwake.app/Contents/MacOS/homeawake-agent}

home=$(mktemp -d)
support="$home/Library/Application Support/HomeAwake"
mkdir -p "$support"
pid=
trap '[ -z "$pid" ] || kill -TERM $pid 2>/dev/null || true; rm -rf "$home"' EXIT
assertions() { pmset -g assertions | grep -c "pid $pid(homeawake-agent).*PreventUserIdleSystemSleep" || true; }
expect() { [ "$2" = "$3" ] && echo "ok: $1" || { echo "FAIL: $1 (got $2, want $3)"; exit 1; }; }
prefs() { printf '%s' "$1" > "$support/prefs.json"; notifyutil -p dev.homeawake.prefs; sleep 0.5; }
sleep_disabled() { pmset -g | awk '/SleepDisabled/ {print $2}'; }
real_status() { stat -f %m "$HOME/Library/Application Support/HomeAwake/status.json" 2>/dev/null || echo absent; }
start() { CFFIXED_USER_HOME="$home" scripts/sandboxed.sh "$agent" 2>> "$home/stderr" & pid=$!; sleep 1; }
stop() { kill -TERM $pid; wait $pid && status=0 || status=$?; }
owns() { grep -c '"ownsSleepSwitch" : true' "$support/status.json" || true; }
claim() { printf '{"ownsSleepSwitch": true, "snapshot": {"power": "ac", "lidClosed": false}}' > "$support/status.json"; }
tried_sudo() {
    sleep 1
    log show --last 2m --style compact \
        --predicate "process == \"kernel\" AND eventMessage CONTAINS \"homeawake-agent($pid) deny(1) process-exec* /usr/bin/sudo\"" |
        grep -q 'deny(1)' && echo yes || echo no
}

router=$(scutil <<< 'show State:/Network/Global/IPv4' | awk '/Router/ {print $3}')
mac=$(arp -n "$router" | awk '{print $4}')
at_home="{\"enabled\": true, \"homes\": [\"$mac\"]}"
paused='{"enabled": false, "homes": []}'
before=$(sleep_disabled)
real_before=$(real_status)

printf '%s' "$at_home" > "$support/prefs.json"
start
expect "status.json names this network" "$(grep -c '"network"' "$support/status.json")" 1
expect "home network on AC holds one assertion" "$(assertions)" 1

prefs "$paused"
expect "pause releases it" "$(assertions)" 0

prefs "$at_home"
expect "resume takes it again" "$(assertions)" 1
notifyutil -p dev.homeawake.prefs; notifyutil -p dev.homeawake.prefs; sleep 0.5
expect "repeated reconciles keep exactly one" "$(assertions)" 1

stop
expect "SIGTERM exits 0" "$status" 0
expect "and the assertion is gone" "$(pmset -g assertions | grep -c "pid $pid(" || true)" 0

if [ "$before" = 0 ]; then
    expect "staying awake with the switch off checks the sudo rule" "$(tried_sudo)" yes
    expect "staying awake without a usable rule takes no ownership" "$(owns)" 0

    claim
    printf '%s' "$paused" > "$support/prefs.json"
    start
    expect "allowSleep with an owned switch already off drops ownership" "$(owns)" 0
    expect "and spawns no sudo" "$(tried_sudo)" no
    expect "and keeps running" "$(kill -0 $pid && echo yes)" yes
    stop

    claim
    printf '%s' "$at_home" > "$support/prefs.json"
    start
    expect "staying awake without a usable rule keeps ownership read from status.json" "$(owns)" 1
    expect "and still holds the assertion" "$(assertions)" 1
    stop
    expect "SIGTERM exits 0" "$status" 0
    expect "SIGTERM with the switch off writes ownership off" "$(owns)" 0
else
    echo "skip: ownership rows need SleepDisabled 0, and it is $before"
fi

expect "the real home's status.json is untouched" "$(real_status)" "$real_before"
expect "SleepDisabled unchanged" "$(sleep_disabled)" "$before"
expect "agent logged nothing, so it attempted no write" "$(wc -c < "$home/stderr" | tr -d ' ')" 0
