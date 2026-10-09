#!/bin/sh
# Runs the automated prototype checks against a private daemon instance.
# Usage: Checks/run.sh [--with-agents]   (agents opens Claude Code and Codex, without sending prompts)
set -eu
cd "$(dirname "$0")/.."
root="$(cd ../.. && pwd)"
socket="${TMPDIR:-/tmp/}hubagent-proto-checks.sock"

swift build -c release >/dev/null
.build/release/proto-daemon --socket "$socket" 2>/dev/null &
daemon=$!
trap 'kill "$daemon" 2>/dev/null; rm -f "$socket"' EXIT
sleep 1

status=0
for script in Checks/0*.script; do
    echo "== $script"
    sed "s#@ROOT@#$root#g" "$script" | .build/release/proto-probe --socket "$socket" \
        | grep -E '^(SAME|DIFF|OK|FAIL|RESULT|STATS|THROUGHPUT|EVENT)' || status=1
done
if [ "${1:-}" = "--with-agents" ]; then
    echo "== Checks/agents-claude-codex.script"
    sed "s#@ROOT@#$root#g" Checks/agents-claude-codex.script | .build/release/proto-probe --socket "$socket" \
        | grep -E '^(SAME|DIFF|OK|FAIL|RESULT|STATS|EVENT)' || status=1
fi
exit "$status"
