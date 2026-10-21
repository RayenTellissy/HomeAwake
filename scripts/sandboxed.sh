#!/bin/bash
# Runs a command that cannot exec sudo or pmset, so a test run of the agent cannot change SleepDisabled even on a Mac
# where a sudoers rule allows it. exec keeps the pid, so callers can watch the command by $!.
set -euo pipefail
profile='(version 1)(allow default)(deny process-exec (literal "/usr/bin/sudo") (literal "/usr/bin/pmset"))'
if sandbox-exec -p "$profile" /usr/bin/pmset -g > /dev/null 2>&1; then
    echo "FAIL: the sandbox does not block exec" >&2
    exit 1
fi
exec sandbox-exec -p "$profile" "$@"
