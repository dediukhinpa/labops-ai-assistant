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

echo "== побудка просит тишину =="
# Без этой фразы воркер роя превращал консолидацию в отчёт владельцу в чат.
printf '%s' "$OUT" | grep -q 'do NOT message the owner'
ok $? "тело побудки запрещает писать владельцу"

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

echo "== кулдаун по умолчанию -- час, а не две минуты =="
# С 2026-09-02 каждая побудка порождает headless-запуск через webhook-listener,
# так что дешёвый дефолт 120 с превратился бы в несколько запусков в час.
grep -q 'MEMORY_NUDGE_COOLDOWN:-3600' "$NUDGE"; ok $? "дефолт 3600 с в коде"
WS3="$TMP/default-cd/.claude"; mkdir -p "$WS3/core/active" "$WS3/logs"
AGENT_WORKSPACE="$WS3" AGENT_ID=nova AGENT_BEARER="" bash "$NUDGE" --reason idle
n1=$(wc -l < "$WS3/core/active/consolidate.request")
AGENT_WORKSPACE="$WS3" AGENT_ID=nova AGENT_BEARER="" bash "$NUDGE" --reason idle
n2=$(wc -l < "$WS3/core/active/consolidate.request")
[ "$n1" = "$n2" ] && ok 0 "" || ok 1 "без переменной кулдаун не сработал"

echo "== bearer читается из pretty-printed .mcp.json =="
# Живой .mcp.json разложен по строкам: между именем сервера и Authorization
# лежат "type", "url", "headers". Старый `grep -A3` их не переживал, токен
# терялся, и побудка молча уходила в файловый маркер вместо agent_router.
WS2="$TMP/pretty/.claude"; mkdir -p "$WS2/core/active" "$WS2/logs"
cat > "$WS2/.mcp.json" <<'JSON'
{
  "mcpServers": {
    "second_brain-agent_router": {
      "type": "http",
      "url": "http://127.0.0.1:5000/mcp",
      "headers": {
        "Authorization": "Bearer test-token-123"
      }
    }
  }
}
JSON
# Роутер заведомо недоступен: важно отличить "токен нашёлся, сеть не ответила"
# от "токена нет" -- это разные ветки лога.
AGENT_WORKSPACE="$WS2" AGENT_ID=nova SECOND_BRAIN_AGENT_ROUTER_URL="http://127.0.0.1:1/mcp" \
    bash "$NUDGE" --reason checkpoint
ok $? "exit 0 при недоступном роутере"
if grep -q 'no bearer' "$WS2/logs/hooks.log"; then
    ok 1 "токен не найден в pretty-printed .mcp.json"
else
    ok 0 ""
fi
grep -q 'notify failed' "$WS2/logs/hooks.log"; ok $? "дошли до отправки"
# Причина в маркере должна отличать «нет токена» от «роутер не ответил».
grep -q 'notify rejected by agent_router' "$WS2/logs/hooks.log"; ok $? "причина маркера записана"

echo "== пропуск побудки, если в дневнике нет нового с прошлого разбора =="
# Разбор оставляет в дневнике запись о себе, и без этой проверки побудки шли
# цепочкой: каждая находила "новым" отчёт о предыдущей (rodriguez: 4 подряд).
# Токена нет намеренно: "слать" заканчивается маркером consolidate.request, а
# "пропустить" его не трогает -- по маркеру и по логу видно, какая ветка сработала.
mk_ws() {  # mk_ws <имя> -> путь к .claude с пустым дневником
    local w="$TMP/$1/.claude"; mkdir -p "$w/core/active" "$w/core/passive" "$w/logs"
    printf '%s\n' "$w"
}
run_nudge() {  # run_nudge <ws>
    AGENT_WORKSPACE="$1" AGENT_ID=nova AGENT_BEARER="" bash "$NUDGE" --reason idle
}
WM="2026-11-14T19:01:21Z"

# 1. нет записей новее отметки -> пропуск
W1="$(mk_ws skip-none)"; printf '%s' "$WM" > "$W1/core/passive/.consolidated-at"
printf '### 2026-11-14 17:57 [stop-hook] {fact}\n\nстарая запись\n' > "$W1/core/active/episodic.md"
run_nudge "$W1"; ok $? "exit 0 при пропуске"
grep -q "skip: nothing new since $WM" "$W1/logs/hooks.log"; ok $? "пропуск записан в лог с отметкой"
test ! -e "$W1/core/active/consolidate.request"; ok $? "при пропуске маркер не падает"
test ! -e "$W1/core/active/.last-nudge"; ok $? "при пропуске стамп кулдауна не обновляется"

# 2. есть новая обычная запись -> шлём (без токена -- файловый маркер)
W2="$(mk_ws send-new)"; printf '%s' "$WM" > "$W2/core/passive/.consolidated-at"
printf '### 2026-11-14 19:30 [stop-hook] {decision}\n\nРешили выкатить сайт в пятницу\n' \
    > "$W2/core/active/episodic.md"
run_nudge "$W2"
test -f "$W2/core/active/consolidate.request"; ok $? "новая обычная запись -> побудка идёт"
test -f "$W2/core/active/.last-nudge"; ok $? "при отправке стамп кулдауна обновлён"

# 3. новые только записи-разборы -> пропуск (метка и старый свободный текст)
W3="$(mk_ws skip-maint)"; printf '%s' "$WM" > "$W3/core/passive/.consolidated-at"
{
    printf '### 2026-11-14 17:57 [stop-hook] {fact}\n\nобычная старая запись\n\n'
    printf '### 2026-11-14 19:05 [stop-hook] {fact}\n\n[maintenance] consolidation done\n\n'
    printf '### 2026-11-14 19:40 [stop-hook] {fact}\n\nКонсолидацию памяти выполнила: одна запись\n\n'
    printf '### 2026-11-14 20:12 [stop-hook] {fact}\n\nЧетвёртый разбор памяти подряд, нового нет\n'
} > "$W3/core/active/episodic.md"
run_nudge "$W3"
grep -q 'skip: nothing new' "$W3/logs/hooks.log"; ok $? "только записи-разборы -> пропуск"
test ! -e "$W3/core/active/consolidate.request"; ok $? "записи-разборы: маркер не падает"

# 3b. разбор + настоящая запись после него -> шлём
printf '### 2026-11-14 20:30 [stop-hook] {fact}\n\nДиана попросила новый баннер\n' \
    >> "$W3/core/active/episodic.md"
run_nudge "$W3"
test -f "$W3/core/active/consolidate.request"; ok $? "после разбора появилась настоящая запись -> шлём"

# 4. нет отметки -> всё новое, шлём
W4="$(mk_ws no-watermark)"
printf '### 2026-11-14 17:57 [stop-hook] {fact}\n\nстарая запись\n' > "$W4/core/active/episodic.md"
run_nudge "$W4"
test -f "$W4/core/active/consolidate.request"; ok $? "нет отметки -> побудка идёт"

# 5. битая отметка -> fail-open, причина в логе
W5="$(mk_ws bad-watermark)"; printf 'вчера вечером' > "$W5/core/passive/.consolidated-at"
printf '### 2026-11-14 17:57 [stop-hook] {fact}\n\nстарая запись\n' > "$W5/core/active/episodic.md"
run_nudge "$W5"
test -f "$W5/core/active/consolidate.request"; ok $? "битая отметка -> fail-open, побудка идёт"
grep -q 'unparseable watermark' "$W5/logs/hooks.log"; ok $? "причина fail-open записана в лог"

# 6. режим проверки без побочных эффектов
W6="$(mk_ws check-mode)"; printf '%s' "$WM" > "$W6/core/passive/.consolidated-at"
printf '### 2026-11-14 17:57 [stop-hook] {fact}\n\nстарая запись\n' > "$W6/core/active/episodic.md"
OUT6="$(AGENT_WORKSPACE="$W6" AGENT_ID=nova MEMORY_NUDGE_CHECK=1 bash "$NUDGE" --reason idle)"
[ "$OUT6" = "skip: $WM" ]; ok $? "MEMORY_NUDGE_CHECK печатает решение: $OUT6"
test ! -e "$W6/logs/hooks.log" -a ! -e "$W6/core/active/.last-nudge"; ok $? "CHECK без побочных эффектов"

echo ""
echo "reflect-nudge.test.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
