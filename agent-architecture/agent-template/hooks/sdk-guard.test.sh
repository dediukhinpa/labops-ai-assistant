#!/usr/bin/env bash
set -uo pipefail

# sdk-guard.test.sh -- защита от рекурсии в хуках agent-template.
#
# Каждый хук обязан выйти НЕМЕДЛЕННО и без побочных эффектов, когда его вызвал
# не живой TUI-агент, а порождённый Agent SDK ребёнок. Иначе хук пишет в память
# за ребёнка, ребёнок снова дёргает хук, и рой уходит в самоподдерживающийся
# цикл. Признаков два:
#   - переменная окружения CLAUDE_SDK_CHILD=1  (все хуки);
#   - поле entrypoint=sdk-ts в JSON на stdin   (только stop-hook).
#
# Тест жил в labops-second-brain/tests/test_sdk_guard_hooks.py и был там мёртв:
# он искал хуки по пути <second-brain>/agent-template/hooks/, которого в том
# репозитории никогда не существовало -- все 8 случаев падали с кодом 127, а CI
# там только gitleaks, поэтому красноту никто не видел. Заодно тот тест ещё
# проверял раскладку core/hot/recent.md, которой нет с переезда на core/active/.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Намеренно без `-e`: под ним первая же непройденная проверка убивала бы тест
# на месте, и оператор видел бы одну строку вместо полного списка провалов.
pass=0; fail=0
ok() { if [ "$1" = "0" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "  FAIL: $2"; fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Рабочее пространство собирается заново на каждый случай: хуки дописывают в
# память, и общий каталог склеил бы результаты соседних проверок.
make_ws() {
    local ws="$TMP/ws-$1"
    mkdir -p "$ws/core/active" "$ws/core/passive" "$ws/logs" "$ws/hooks" "$ws/scripts" "$ws/state"
    cp "$SCRIPT_DIR"/*.sh "$ws/hooks/"
    cp "$SCRIPT_DIR"/../scripts/*.sh "$ws/scripts/" 2>/dev/null || true
    printf '%s' "$ws"
}

# Уборку глушим: без маркера last-housekeeping stop-hook считает, что она не
# запускалась никогда, и уводит decay-sweep + archive-roll в фон -- посторонние
# записи в тех же файлах, которые проверяет тест.
# Stdin подаём ФАЙЛОМ, а не каналом. Через `printf ... | bash hook` тест мигал
# примерно раз на восемь прогонов: хук с сработавшей защитой выходит ДО чтения
# stdin, printf упирается в закрытый канал, получает SIGPIPE и возвращает 141, а
# `set -o pipefail` объявляет это провалом самого хука. Гонка чистая: короткая
# нагрузка обычно успевает лечь в буфер канала, но не обязана.
run_hook() {
    local hook="$1" ws="$2" stdin="$3"; shift 3
    local in="$TMP/stdin.$$"
    printf '%s' "$stdin" > "$in"
    env "$@" \
        AGENT_WORKSPACE="$ws" AGENT_ID=test-agent \
        MEMORY_HOUSEKEEPING_INTERVAL_SEC=0 \
        bash "$ws/hooks/$hook" < "$in"
}

echo "== CLAUDE_SDK_CHILD=1: stop-hook не трогает память =="
WS="$(make_ws stop-env)"
run_hook stop-hook.sh "$WS" '{"assistant_response":"should not be recorded"}' CLAUDE_SDK_CHILD=1
ok $? "exit 0"
[ ! -s "$WS/core/active/episodic.md" ]; ok $? "episodic.md не появился и не наполнен"
[ "$(find "$WS/logs" -name 'verbose-*.jsonl' | wc -l)" -eq 0 ]; ok $? "подробный журнал не заведён"

echo "== CLAUDE_SDK_CHILD=1: stop-hook не портит уже накопленное =="
WS="$(make_ws stop-env-existing)"
printf 'PREEXISTING\n' > "$WS/core/active/episodic.md"
run_hook stop-hook.sh "$WS" '{"assistant_response":"x"}' CLAUDE_SDK_CHILD=1
ok $? "exit 0"
[ "$(cat "$WS/core/active/episodic.md")" = "PREEXISTING" ]; ok $? "episodic.md не изменён"

echo "== CLAUDE_SDK_CHILD=1: session-start-hook молчит =="
WS="$(make_ws session-env)"
run_hook session-start-hook.sh "$WS" '' CLAUDE_SDK_CHILD=1
ok $? "exit 0"
[ ! -s "$WS/logs/hooks.log" ]; ok $? "hooks.log не заведён"

echo "== CLAUDE_SDK_CHILD=1: precompact-hook не снимает снимок =="
WS="$(make_ws precompact-env)"
printf 'data\n' > "$WS/core/active/episodic.md"
run_hook precompact-hook.sh "$WS" '' CLAUDE_SDK_CHILD=1
ok $? "exit 0"
[ "$(find "$WS/core/active/pre-compact" -name 'recent-*.md' 2>/dev/null | wc -l)" -eq 0 ]
ok $? "каталог снимков пуст"

echo "== stdin entrypoint=sdk-ts: stop-hook срабатывает на полезной нагрузке =="
WS="$(make_ws stop-payload-sdk)"
run_hook stop-hook.sh "$WS" '{"entrypoint":"sdk-ts","assistant_response":"hi"}'
ok $? "exit 0"
# Файл создаётся раньше разбора stdin (mkdir+touch), поэтому проверяем не
# наличие, а отсутствие записи.
! grep -q '\[stop-hook\]' "$WS/core/active/episodic.md" 2>/dev/null
ok $? "эпизодическая запись не добавлена"
grep -q 'sdk-guard: entrypoint=sdk-ts' "$WS/logs/hooks.log"; ok $? "причина пропуска в журнале"

echo "== stdin entrypoint=cli: обычный ход проходит насквозь =="
WS="$(make_ws stop-payload-cli)"
run_hook stop-hook.sh "$WS" '{"entrypoint":"cli","assistant_response":"normal flow"}'
ok $? "exit 0"
grep -q '\[stop-hook\]' "$WS/core/active/episodic.md"; ok $? "эпизодическая запись добавлена"
grep -q 'normal flow' "$WS/core/active/episodic.md"; ok $? "текст хода сохранён"

echo "== пустой stdin: не ошибка, а объяснённый выход =="
WS="$(make_ws stop-empty)"
run_hook stop-hook.sh "$WS" ''
ok $? "exit 0"
grep -q 'no stdin payload' "$WS/logs/hooks.log"; ok $? "причина записана в журнал"

echo "== битый JSON: не считается признаком SDK-ребёнка =="
WS="$(make_ws stop-badjson)"
run_hook stop-hook.sh "$WS" '{not valid json'
ok $? "exit 0"
grep -q '\[stop-hook\]' "$WS/core/active/episodic.md"; ok $? "ход записан как обычный текст"

echo ""
echo "sdk-guard.test.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
