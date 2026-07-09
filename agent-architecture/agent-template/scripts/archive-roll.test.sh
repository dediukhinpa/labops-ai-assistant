#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROLL="$SCRIPT_DIR/archive-roll.sh"
pass=0; fail=0
ok() { if [ "$1" = "0" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "  FAIL: $2"; fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
WS="$TMP/.claude"; mkdir -p "$WS/core/active"
EP="$WS/core/active/episodic.md"

# header + many entries; ~4KB total so it exceeds a 1KB roll threshold
printf '# Episodic memory -- raw journal\n' > "$EP"
for i in $(seq 1 60); do
    printf '\n### 2026-07-09 12:%02d [stop-hook] {fact}\n\nEntry number %s with some padding text to add bytes to the diary file.\n' "$((i%60))" "$i" >> "$EP"
done
BEFORE=$(wc -c < "$EP")

echo "== roll when over threshold =="
EPISODIC_ROLL_KB=1 AGENT_WORKSPACE="$WS" bash "$ROLL"; ok $? "exit 0"
AFTER=$(wc -c < "$EP")
[ "$AFTER" -lt "$BEFORE" ]; ok $? "episodic shrank ($BEFORE -> $AFTER)"
MONTH="$(date -u +%Y-%m)"
test -f "$WS/core/archived/episodic/$MONTH.md"; ok $? "archive file created"
grep -q '^# Episodic memory' "$EP"; ok $? "header preserved"
grep -q 'Entry number 60' "$EP"; ok $? "most recent entry kept in episodic"
grep -q 'Entry number 1 ' "$WS/core/archived/episodic/$MONTH.md"; ok $? "oldest entry rolled to archive"

echo "== no-op when under threshold =="
printf '# small\n\n### t [x] {fact}\n\ntiny\n' > "$EP"
BEFORE2=$(wc -c < "$EP")
EPISODIC_ROLL_KB=40 AGENT_WORKSPACE="$WS" bash "$ROLL"
[ "$(wc -c < "$EP")" = "$BEFORE2" ]; ok $? "under-threshold file untouched"

echo ""
echo "archive-roll.test.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
