# Sourced from the repository root by check-agent.sh and measure-agent.sh. The agent runs only through sandboxed.sh,
# with a scratch CFFIXED_USER_HOME, so it never reads or writes the real Application Support folder.
agent=${1:-build/HomeAwake.app/Contents/MacOS/homeawake-agent}
home=$(mktemp -d)
support="$home/Library/Application Support/HomeAwake"
mkdir -p "$support"
pid=
started=0
trap '[ -z "$pid" ] || kill -TERM $pid 2>/dev/null || true; rm -rf "$home"' EXIT

# Arguments go before the agent's path, for example /usr/bin/env DYLD_INSERT_LIBRARIES=<dylib>.
start() {
    started=$((started + 1))
    CFFIXED_USER_HOME="$home" scripts/sandboxed.sh "$@" "$agent" 2> "$home/stderr.$started" & pid=$!
    sleep 1
}
stop() { kill -TERM $pid; wait $pid || { echo "FAIL: agent exited $? on SIGTERM"; exit 1; }; stopped=$pid pid=; }
reconcile() { notifyutil -p dev.homeawake.reconcile; sleep 0.5; }
status_field() { plutil -extract "$1" raw -o - "$support/status.json" 2>/dev/null || echo absent; }
