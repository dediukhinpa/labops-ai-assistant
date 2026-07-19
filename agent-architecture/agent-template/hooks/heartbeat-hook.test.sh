#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/heartbeat-hook.sh"
pass=0; fail=0
ok() { if [ "$1" = "0" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "  FAIL: $2"; fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
WS="$TMP/.claude"; mkdir -p "$WS/hooks"
cp "$HOOK" "$WS/hooks/"
HK="$WS/hooks/heartbeat-hook.sh"
HB="$WS/state/heartbeat"

echo "== writes a fresh epoch heartbeat on a normal event =="
NOW=$(date +%s)
printf '{"hook":"PreToolUse"}' | AGENT_WORKSPACE="$WS" bash "$HK"; ok $? "exit 0"
test -f "$HB"; ok $? "heartbeat file created"
VAL=$(cat "$HB" 2>/dev/null || echo x)
printf '%s' "$VAL" | grep -qE '^[0-9]+$'; ok $? "heartbeat is a numeric epoch ($VAL)"
[ "$VAL" -ge "$NOW" ]; ok $? "heartbeat >= test start ($VAL >= $NOW)"

echo "== empty stdin is a safe no-op write =="
printf '' | AGENT_WORKSPACE="$WS" bash "$HK"; ok $? "empty exit 0"

echo "== heartbeat advances on a later tick =="
OLD=$(cat "$HB"); sleep 1
printf '{}' | AGENT_WORKSPACE="$WS" bash "$HK"; ok $? "second tick exit 0"
NEW=$(cat "$HB"); [ "$NEW" -ge "$OLD" ]; ok $? "advanced ($NEW >= $OLD)"

echo "== sdk-guard skips the write (no heartbeat mutation) =="
rm -f "$HB"
printf '{}' | CLAUDE_SDK_CHILD=1 AGENT_WORKSPACE="$WS" bash "$HK"; ok $? "sdk-child exit 0"
test ! -f "$HB"; ok $? "no heartbeat written for sdk child"

echo "== no stray tmp files left behind =="
STRAY=$(find "$WS/state" -name 'heartbeat.tmp.*' 2>/dev/null | wc -l)
[ "$STRAY" -eq 0 ]; ok $? "no heartbeat.tmp.* leftovers"

echo ""
echo "heartbeat-hook.test.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
