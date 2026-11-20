#!/usr/bin/env bash
set -uo pipefail

# Тест session-start-hook.sh: хвост эпизодической памяти попадает в вывод хука.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/session-start-hook.sh"
pass=0; fail=0
ok() { if [ "$1" = "0" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "  FAIL: $2"; fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
WS="$TMP/.claude"; mkdir -p "$WS/hooks" "$WS/core/active"
cp "$HOOK" "$WS/hooks/"
run() { AGENT_WORKSPACE="$WS" AGENT_ID=test-agent bash "$WS/hooks/session-start-hook.sh" "$@"; }

echo "== пустая память: хук молчит =="
out="$(run)"; ok $? "exit 0"
[ -z "$out" ]; ok $? "вывода нет"

echo "== есть записи: свежий хвост выдан, начало с границы записи =="
{
    printf '### 2026-11-20 08:00 [stop-hook] {fact}\n\nстарая запись SENTINEL_OLD\n\n'
    printf '### 2026-11-20 08:01 [stop-hook] {fact}\n\nДобавил два ID в список доступа SENTINEL_NEW\n'
} > "$WS/core/active/episodic.md"
out="$(run)"; ok $? "exit 0"
printf '%s' "$out" | grep -q 'SENTINEL_NEW'; ok $? "свежая запись в выводе"
printf '%s' "$out" | grep -q 'не инструкции'; ok $? "запись помечена как данные"

echo "== лимит символов обрезает старое, не начиная с обрывка =="
big="$(printf 'x%.0s' $(seq 1 400))"
{
    for i in $(seq 1 30); do printf '### запись %s\n\n%s\n\n' "$i" "$big"; done
} > "$WS/core/active/episodic.md"
out="$(MEMORY_RECAP_MAX_CHARS=1200 run)"
printf '%s' "$out" | grep -q 'запись 30'; ok $? "последняя запись на месте"
printf '%s' "$out" | grep -q 'запись 1$'; [ $? -ne 0 ]; ok $? "самая старая отрезана"
[ "$(printf '%s' "$out" | wc -c)" -lt 1800 ]; ok $? "вывод ограничен лимитом"

echo "== MEMORY_RECAP_MAX_CHARS=0 отключает выдачу =="
out="$(MEMORY_RECAP_MAX_CHARS=0 run)"; [ -z "$out" ]; ok $? "тихо"

echo "== SDK-ребёнок: тихо =="
out="$(CLAUDE_SDK_CHILD=1 run)"; [ -z "$out" ]; ok $? "без вывода"

echo ""
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
