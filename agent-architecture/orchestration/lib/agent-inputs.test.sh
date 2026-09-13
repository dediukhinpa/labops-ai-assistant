#!/usr/bin/env bash
# Unit tests for lib/agent-inputs.sh — ответы new-agent.sh без живого ввода.
# Главное: забытый allowlist при заданном токене бота и забытое имя агента
# останавливают скрипт до создания чего-либо, а не превращаются в бота,
# отвечающего всем, или в повторного Developer.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
NA="$HERE/../../skills/create-agent/new-agent.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1091
source "$HERE/agent-inputs.sh"

fail() { echo "FAIL: $1"; exit 1; }

# 1. Формат allowlist.
for v in 124546645 -1001234567890 '124546645,308749463'; do
  valid_allowlist "$v" || fail "отверг допустимый allowlist: $v"
done
for v in "" " 124" "12a" "124," "124 308" "@user"; do
  valid_allowlist "$v" && fail "принял недопустимый allowlist: '$v'"
done

# guard <env...> — код возврата и вывод require_unattended_inputs под env.
guard() {
  RC=0
  OUT="$(env -u AGENT_NAME -u TELEGRAM_BOT_TOKEN -u TELEGRAM_ALLOWED_USER_IDS "$@" bash -c '
    source "'"$HERE"'/agent-inputs.sh"
    require_unattended_inputs
    echo PASSED' </dev/null 2>&1)" || RC=$?
}

# 2. Без живого ввода: имя и allowlist при токене обязательны.
guard NONINTERACTIVE=1 AGENT_NAME=Commerce TELEGRAM_BOT_TOKEN=1:x
[ "$RC" -ne 0 ] || fail "токен без allowlist пропущен"
echo "$OUT" | grep -q 'TELEGRAM_ALLOWED_USER_IDS' || fail "не назван TELEGRAM_ALLOWED_USER_IDS: $OUT"
echo "$OUT" | grep -q 'PASSED' && fail "после отказа скрипт продолжился"
echo "$OUT" | grep -q '1:x' && fail "токен попал в вывод"

guard NONINTERACTIVE=1 AGENT_NAME=Commerce TELEGRAM_BOT_TOKEN=1:x TELEGRAM_ALLOWED_USER_IDS=abc
[ "$RC" -ne 0 ] || fail "мусорный allowlist пропущен"

guard NONINTERACTIVE=1 TELEGRAM_BOT_TOKEN=1:x TELEGRAM_ALLOWED_USER_IDS=124546645
[ "$RC" -ne 0 ] || fail "без AGENT_NAME пропущено"
echo "$OUT" | grep -q 'AGENT_NAME' || fail "не назван AGENT_NAME: $OUT"

# 3. stdin не терминал (так скрипт запускает агент) — то же, что NONINTERACTIVE.
guard NONINTERACTIVE=0 AGENT_NAME=Commerce TELEGRAM_BOT_TOKEN=1:x
[ "$RC" -ne 0 ] || fail "stdin не терминал: токен без allowlist пропущен"

# 4. Всё передано — проходит; без токена allowlist не нужен (канал не заводится).
guard NONINTERACTIVE=1 AGENT_NAME=Commerce TELEGRAM_BOT_TOKEN=1:x TELEGRAM_ALLOWED_USER_IDS=124546645
[ "$RC" -eq 0 ] && echo "$OUT" | grep -q PASSED || fail "полный набор отвергнут: $OUT"
guard NONINTERACTIVE=1 AGENT_NAME=Commerce
[ "$RC" -eq 0 ] || fail "без токена потребован allowlist: $OUT"

# 5. new-agent.sh проверяет ответы до первого действия: до выдачи токена в
#    памяти, скаффолдинга и канала.
guard_line="$(grep -n '^require_unattended_inputs' "$NA" | head -1 | cut -d: -f1)"
[ -n "$guard_line" ] || fail "new-agent.sh не вызывает require_unattended_inputs"
for anchor in '^ask AGENT_NAME' '^say "2\.' '^say "3\.' '^say "4\.'; do
  l="$(grep -n "$anchor" "$NA" | head -1 | cut -d: -f1)"
  [ -n "$l" ] || fail "нет якоря $anchor в new-agent.sh"
  [ "$guard_line" -lt "$l" ] || fail "проверка ответов стоит после $anchor"
done
grep -q 'DEGRADED+=("allowlist пуст' "$NA" && fail "пустой allowlist снова только строка в сводке"

# 6. Настоящий запуск new-agent.sh так, как его запускает агент: без stdin и без
#    AGENT_NAME — остановка, и воркспейс не создан.
RC=0
env -u AGENT_NAME -u TELEGRAM_BOT_TOKEN -u TELEGRAM_ALLOWED_USER_IDS \
  HOME="$TMP/home" CLAUDE_LAB="$TMP/lab" TG_PLUGIN_DIR="$TMP/none" SECOND_BRAIN_DIR="$TMP/none" \
  bash "$NA" </dev/null >"$TMP/out" 2>&1 || RC=$?
[ "$RC" -ne 0 ] || fail "new-agent.sh без AGENT_NAME и stdin отработал: $(tail -5 "$TMP/out")"
grep -q 'AGENT_NAME' "$TMP/out" || fail "new-agent.sh не назвал AGENT_NAME: $(tail -5 "$TMP/out")"
[ ! -e "$TMP/lab/developer" ] || fail "new-agent.sh успел создать воркспейс"

echo "agent-inputs: ok"
