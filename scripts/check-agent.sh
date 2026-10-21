#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/scratch-agent.sh

assertions() { pmset -g assertions | grep -c "pid $pid(homeawake-agent).*PreventUserIdleSystemSleep" || true; }
expect() { [ "$2" = "$3" ] && echo "ok: $1" || { echo "FAIL: $1 (got $2, want $3)"; exit 1; }; }
prefs() { printf '%s' "$1" > "$support/prefs.json"; reconcile; }
sleep_disabled() { pmset -g | awk '/SleepDisabled/ {print $2}'; }
real_status() { stat -f %m "$HOME/Library/Application Support/HomeAwake/status.json" 2>/dev/null || echo absent; }
claim() { printf '{"ownsSleepSwitch": true, "snapshot": {"power": "ac"}}' > "$support/status.json"; }
tried_sudo() { grep -q 'posix_spawn /usr/bin/sudo failed' "$home/stderr.$started" && echo yes || echo no; }
spawns() { grep -c "^spawn $1\$" "$home/stderr.$started" || true; }
power_event() { notifyutil -p dev.homeawake.check.power; sleep 0.5; }

router=$(scutil <<< 'show State:/Network/Global/IPv4' | awk '/Router/ {print $3}')
IFS=: read -ra octets <<< "$(arp -n "$router" | awk '{print $4}')"
mac=$(printf '%02x:%02x:%02x:%02x:%02x:%02x' "${octets[@]/#/0x}")
at_home="{\"enabled\": true, \"homes\": [\"$mac\"]}"
paused='{"enabled": false, "homes": []}'
before=$(sleep_disabled)
real_before=$(real_status)

printf '%s' "$at_home" > "$support/prefs.json"
start
expect "status.json names this network" "$(status_field snapshot.network)" "$mac"
expect "home network on AC holds one assertion" "$(assertions)" 1

prefs "$paused"
expect "pause releases it" "$(assertions)" 0

prefs "$at_home"
expect "resume takes it again" "$(assertions)" 1
reconcile; reconcile
expect "repeated reconciles keep exactly one" "$(assertions)" 1

stop
expect "SIGTERM releases the assertion" "$(pmset -g assertions | grep -c "pid $stopped(" || true)" 0

if [ "$before" = 0 ]; then
    expect "staying awake with the switch off checks the sudo rule" "$(tried_sudo)" yes
    expect "staying awake without a usable rule takes no ownership" "$(status_field ownsSleepSwitch)" false

    claim
    printf '%s' "$paused" > "$support/prefs.json"
    start
    expect "allowSleep with an owned switch already off drops ownership" "$(status_field ownsSleepSwitch)" false
    expect "and spawns no sudo" "$(tried_sudo)" no
    expect "and keeps running" "$(kill -0 $pid && echo yes)" yes
    stop

    claim
    printf '%s' "$at_home" > "$support/prefs.json"
    start
    expect "staying awake without a usable rule keeps ownership read from status.json" \
        "$(status_field ownsSleepSwitch)" true
    expect "and still holds the assertion" "$(assertions)" 1
    stop
    expect "SIGTERM with the switch off writes ownership off" "$(status_field ownsSleepSwitch)" false
else
    echo "skip: ownership rows need SleepDisabled 0, and it is $before"
fi

clang -dynamiclib -framework CoreFoundation -framework SystemConfiguration -o "$home/hooks.dylib" scripts/check-hooks.c
printf '%s' "$at_home" > "$support/prefs.json"
start /usr/bin/env DYLD_INSERT_LIBRARIES="$home/hooks.dylib"
expect "at home with the check hooks loaded, the agent holds one assertion" "$(assertions)" 1

if [ "$before" = 0 ]; then
    expect "staying awake with the switch off asked sudo once" "$(spawns /usr/bin/sudo)" 1
    power_event
    expect "a power event after sudo denied the rule asks sudo nothing" "$(spawns /usr/bin/sudo)" 1
    reconcile
    expect "a reconcile request asks sudo again" "$(spawns /usr/bin/sudo)" 2
fi

echo 192.0.2.1 > "$home/router"; reconcile
expect "with a router that has no ARP entry, status.json has no network" "$(status_field snapshot.network)" absent
expect "and the agent keeps its assertion" "$(assertions)" 1
arp_before=$(spawns /usr/sbin/arp)
sleep 2
expect "and retries the lookup 2 s later" "$(spawns /usr/sbin/arp)" $((arp_before + 1))
rm "$home/router"; reconcile
expect "the router resolving keeps exactly one" "$(assertions)" 1
sleep 4.5
expect "and cancels the pending retry" "$(spawns /usr/sbin/arp)" $((arp_before + 2))

: > "$home/router"; reconcile
expect "with no router, status.json has no network" "$(status_field snapshot.network)" absent
expect "and the agent keeps its assertion" "$(assertions)" 1
prefs "$paused"
expect "pausing with no router still releases it" "$(assertions)" 0
prefs "$at_home"
expect "resuming with no router does not take it" "$(assertions)" 0
rm "$home/router"; reconcile
expect "the router coming back takes it again" "$(assertions)" 1
arp_before=$(spawns /usr/sbin/arp)
prefs "$paused"
expect "paused, a reconcile runs no arp" "$(spawns /usr/sbin/arp)" "$arp_before"
stop

expect "the real home's status.json is untouched" "$(real_status)" "$real_before"
expect "SleepDisabled unchanged" "$(sleep_disabled)" "$before"
expect "the agent attempted no pmset write" "$(cat "$home"/stderr.* | grep -c pmset || true)" 0
