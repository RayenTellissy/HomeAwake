#!/bin/bash
set -euo pipefail
profile='(version 1)(allow default)(deny process-exec (literal "/usr/bin/sudo") (literal "/usr/bin/pmset"))'
if sandbox-exec -p "$profile" /usr/bin/pmset -g > /dev/null 2>&1; then
    echo "FAIL: the sandbox does not block exec" >&2
    exit 1
fi
exec sandbox-exec -p "$profile" "$@"
