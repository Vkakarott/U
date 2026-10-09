#!/bin/sh
# Manual test of the prototype window. Usage: ./manual-test.sh [stop]
# Starts the prototype daemon in the background (if needed) and opens the window.
# The daemon keeps running after the window closes; "./manual-test.sh stop" ends it.
set -eu
cd "$(dirname "$0")"
root="$(cd ../.. && pwd)"
socket="${TMPDIR:-/tmp/}hubagent-proto-manual.sock"
pidfile="${TMPDIR:-/tmp/}hubagent-proto-manual.pid"

if [ "${1:-}" = "stop" ]; then
    [ -f "$pidfile" ] && kill "$(cat "$pidfile")" 2>/dev/null || true
    rm -f "$pidfile" "$socket"
    echo "Daemon do protótipo encerrado."
    exit 0
fi

swift build -c release
if ! { [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; }; then
    nohup .build/release/proto-daemon --socket "$socket" >/dev/null 2>&1 &
    echo $! > "$pidfile"
    sleep 1
fi
exec .build/release/proto-app --socket "$socket" --cwd "$root"
