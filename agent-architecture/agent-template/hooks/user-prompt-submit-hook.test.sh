#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/user-prompt-submit-hook.sh"
pass=0; fail=0
ok() { if [ "$1" = "0" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "  FAIL: $2"; fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
WS="$TMP/.claude"; mkdir -p "$WS/core/active" "$WS/core/passive" "$WS/scripts" "$WS/hooks"
# make the hook resolve WS-relative scripts: copy real scripts + hook into WS layout
cp "$SCRIPT_DIR/user-prompt-submit-hook.sh" "$WS/hooks/"
cp "$SCRIPT_DIR/../scripts/active-writer.sh" "$SCRIPT_DIR/../scripts/working-set-build.sh" "$WS/scripts/"
HK="$WS/hooks/user-prompt-submit-hook.sh"
LOG="$WS/logs/hooks.log"

echo "== ephemeral prompt is gated out =="
printf '{"prompt":"ок"}' | AGENT_WORKSPACE="$WS" AGENT_ID=nova bash "$HK"; ok $? "exit 0"
grep -q 'ephemeral); skip' "$LOG"; ok $? "logged skip for ack"
test ! -f "$WS/core/active/working-set.md"; ok $? "no working-set built for ack"

echo "== substantive prompt triggers recall =="
printf '{"prompt":"how did we set up the pgvector recall router ranking?"}' \
  | AGENT_WORKSPACE="$WS" AGENT_ID=nova bash "$HK"; ok $? "exit 0"
grep -q 'refreshing working-set' "$LOG"; ok $? "logged recall for substantive prompt"

echo "== empty payload is a safe no-op =="
printf '' | AGENT_WORKSPACE="$WS" AGENT_ID=nova bash "$HK"; ok $? "empty exit 0"

echo ""
echo "user-prompt-submit-hook.test.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
