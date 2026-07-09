#!/usr/bin/env bash
set -euo pipefail

# Tests for reflect-nudge.sh (payload validity, graceful degrade, cooldown).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NUDGE="$SCRIPT_DIR/reflect-nudge.sh"

pass=0; fail=0
ok() { if [ "$1" = "0" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "  FAIL: $2"; fi; }

echo "== dry-run emits valid agent_router.notify JSON =="
OUT="$(AGENT_ID=nova MEMORY_NUDGE_DRYRUN=1 bash "$NUDGE" --reason checkpoint)"
printf '%s' "$OUT" | python3 -c '
import json,sys
d=json.load(sys.stdin)
assert d["method"]=="agent_router.notify", d
a=d["params"]["arguments"]
assert a["to_agent"]=="nova", a
assert a["payload"]["instruction_type"]=="memory_consolidate", a
assert a["payload"]["reason"]=="checkpoint", a
'
ok $? "dry-run JSON shape"

echo "== graceful degrade: no bearer -> marker + exit 0 =="
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
WS="$TMP/.claude"; mkdir -p "$WS/core/active"
# no AGENT_BEARER, no .mcp.json -> bearer empty -> marker path
AGENT_WORKSPACE="$WS" AGENT_ID=nova AGENT_BEARER="" bash "$NUDGE" --reason idle
ok $? "exit 0 on degrade"
test -f "$WS/core/active/consolidate.request"; ok $? "marker written"
grep -q 'idle' "$WS/core/active/consolidate.request"; ok $? "marker records reason"

echo "== cooldown blocks a second immediate nudge =="
# .last-nudge is now fresh; a second call within cooldown must not append a 2nd marker line
before=$(wc -l < "$WS/core/active/consolidate.request")
AGENT_WORKSPACE="$WS" AGENT_ID=nova AGENT_BEARER="" MEMORY_NUDGE_COOLDOWN=9999 bash "$NUDGE" --reason idle
after=$(wc -l < "$WS/core/active/consolidate.request")
[ "$before" = "$after" ] && ok 0 "cooldown suppressed 2nd marker" || ok 1 "cooldown suppressed 2nd marker"

echo ""
echo "reflect-nudge.test.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
