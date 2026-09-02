#!/usr/bin/env bash
set -euo pipefail

# Tests for reflect-nudge.sh (payload validity, graceful degrade, cooldown).
#
# Побудка на консолидацию памяти (L2 -> L3) не срабатывала ни разу за 45 дней:
# payload шёл без "jsonrpc"/"id" и с методом "agent_router.notify" вместо
# "tools/call", сервер отвечал "-32602 Validation error: 9 validation errors
# for JSONRPC", а скрипт молча дописывал строку в consolidate.request -- файл,
# который никто не читает. 235 попыток на двух агентах, ноль успехов.
# Прежняя версия этого теста утверждала именно сломанную форму, поэтому баг
# и прожил так долго: проверка была, но проверяла не то.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NUDGE="$SCRIPT_DIR/reflect-nudge.sh"

pass=0; fail=0
ok() { if [ "$1" = "0" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "  FAIL: $2"; fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "== dry-run emits a valid JSON-RPC tools/call =="
OUT="$(AGENT_ID=nova MEMORY_NUDGE_DRYRUN=1 bash "$NUDGE" --reason checkpoint)"
printf '%s' "$OUT" | python3 -c '
import json, sys

msg = json.load(sys.stdin)
assert msg["jsonrpc"] == "2.0", msg.get("jsonrpc")
assert "id" in msg, "нет id -- сервер отвергнет как невалидный JSON-RPC"
assert msg["method"] == "tools/call", msg["method"]
params = msg["params"]
assert params["name"] == "notify", params.get("name")
a = params["arguments"]
assert a["to_agent"] == "nova", a
assert a["payload"]["instruction_type"] == "memory_consolidate", a
assert a["payload"]["reason"] == "checkpoint", a
'
ok $? "dry-run JSON shape"

echo "== the old malformed shape is gone =="
# Комментарии не считаем: там старое имя упомянуто как объяснение бага.
if grep -vE '^[[:space:]]*#' "$NUDGE" | grep -q 'agent_router\.notify'; then
    ok 1 "метод agent_router.notify всё ещё в коде"
else
    ok 0 ""
fi

echo "== graceful degrade: no bearer -> marker + exit 0 =="
WS="$TMP/.claude"; mkdir -p "$WS/core/active"
# no AGENT_BEARER, no .mcp.json -> bearer empty -> marker path
AGENT_WORKSPACE="$WS" AGENT_ID=nova AGENT_BEARER="" bash "$NUDGE" --reason idle
ok $? "exit 0 on degrade"
test -f "$WS/core/active/consolidate.request"; ok $? "marker written"
grep -q 'idle' "$WS/core/active/consolidate.request"; ok $? "marker records reason"

echo "== cooldown blocks a second immediate nudge =="
before=$(wc -l < "$WS/core/active/consolidate.request")
AGENT_WORKSPACE="$WS" AGENT_ID=nova AGENT_BEARER="" MEMORY_NUDGE_COOLDOWN=9999 \
    bash "$NUDGE" --reason idle
after=$(wc -l < "$WS/core/active/consolidate.request")
[ "$before" = "$after" ] && ok 0 "cooldown suppressed 2nd marker" || ok 1 "cooldown suppressed 2nd marker"

echo ""
echo "reflect-nudge.test.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
