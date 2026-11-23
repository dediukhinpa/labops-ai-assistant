#!/usr/bin/env bash
# Юнит-тест lib/pii-replay.sh: прокси упал посреди хода — ход прерывается, claude
# перезапускается напрямую, последнее входящее повторяется ровно один раз и только если ход на
# него не ответил. tmux — функция-заглушка (живой tmux не трогается), рестарт — заглушка.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export CLAUDE_LAB="$TMP/lab"
AGENT="alpha"
SESSION="labops-$AGENT"
WS="$CLAUDE_LAB/$AGENT/.claude"
export TELEGRAM_STATE_DIR="$CLAUDE_LAB/shared/state/$AGENT/telegram"
mkdir -p "$WS/logs" "$WS/state" "$TELEGRAM_STATE_DIR"
# shellcheck disable=SC1091
source "$HERE/pane.sh"
# shellcheck disable=SC1091
source "$HERE/pii.sh"
# shellcheck disable=SC1091
source "$HERE/pii-replay.sh"
export PII_REPLAY_POLL_SEC=0 PII_REPLAY_SUBMIT_DELAY=0 PII_INTERRUPT_SETTLE_SEC=0
export PII_REPLAY_PROMPT_WAIT_SEC=1

fail() { echo "FAIL: $1"; exit 1; }
eq() { [ "$1" = "$2" ] || fail "$3: ожидали '$2', получили '$1'"; }

# Заглушки окружения watchdog.
KEYS="$TMP/keys.log"; EVENTS="$TMP/events.log"
PANE_IDLE=$'  done\n❯\xc2\xa0\n  ⏵⏵ bypass permissions on'
PANE_NOW="$PANE_IDLE"
tmux() {
  case "$1" in
    capture-pane) printf '%s' "$PANE_NOW" ;;
    send-keys)
      local a; for a in "$@"; do printf '%s\n' "$a"; done | tail -1 >> "$KEYS"
      # Escape во время хода — ход прерван; Stop в этом случае не пишется.
      ;;
  esac
  return 0
}
log() { echo "LOG $*" >> "$EVENTS"; }
restart_session() { echo "RESTART $1 ${2:-} mode=${3:-}" >> "$EVENTS"; PANE_NOW="$PANE_IDLE"; }
PII_WANT="$PII_MODE_DIRECT"

deliver() {   # <секунд назад> <текст> — метка доставки плагина
  printf '%s\n%s' "$(( $(date +%s) - $1 ))" "$2" > "$(inbound_marker_file "$AGENT")"
}
turn_end() {   # <секунд назад> — stop-hook записал конец хода
  touch -d "@$(( $(date +%s) - $1 ))" "$WS/logs/verbose-2026-11-23.jsonl"
}
reset_all() {
  rm -f "$WS/logs/"*.jsonl "$(pii_replayed_file "$AGENT")" "$KEYS" "$EVENTS" \
    "$(pii_switch_continue_file "$AGENT")"
}

# 1. Решение о повторе.
reset_all
pii_replay_pending "$AGENT" >/dev/null && fail "без метки доставки повторять нечего"
deliver 60 "проверь отчёт"
ts="$(pii_replay_pending "$AGENT")" || fail "неотвеченное свежее входящее нужно повторить"
turn_end 120
pii_replay_pending "$AGENT" >/dev/null || fail "конец хода ДО доставки — ответа ещё нет"
turn_end 10
pii_replay_pending "$AGENT" >/dev/null && fail "ход закончился после доставки — ответ был"
rm -f "$WS/logs/"*.jsonl
pii_replay_mark "$AGENT" "$ts"
pii_replay_pending "$AGENT" >/dev/null && fail "то же входящее второй раз не повторяем"
reset_all
deliver $(( PII_REPLAY_MAX_AGE_SEC + 60 )) "давнее"
pii_replay_pending "$AGENT" >/dev/null && fail "давнее входящее не повторяем"
deliver 5 $'первая строка\nвторая'
eq "$(pii_replay_text "$AGENT")" "первая строка вторая" "многострочное склеивается в строку"

# 2. Прокси упал посреди хода: Escape, рестарт с --continue без флап-счёта, повтор один раз.
reset_all
deliver 60 "сделай сводку"
PANE_NOW=$'✻ Working… (12s · esc to interrupt)\n❯\xc2\xa0'
pii_switch_claude "посреди хода" interrupt
grep -qx Escape "$KEYS" || fail "ход не прерван"
grep -q '^RESTART .* noflap mode=direct$' "$EVENTS" \
  || fail "рестарт без noflap или без решения watchdog о режиме (start-agent переиграл бы его)"
[ -e "$(pii_switch_continue_file "$AGENT")" ] || fail "нет метки --continue"
grep -qx "сделай сводку" "$KEYS" || fail "входящее не повторено"
eq "$(grep -cx Enter "$KEYS")" 1 "повтор отправлен один раз"
# Тот же перевод ещё раз (рестарт демона) — повтора нет.
: > "$KEYS"
pii_switch_claude "посреди хода" interrupt
grep -qx "сделай сводку" "$KEYS" && fail "входящее повторено дважды"

# 3. Ход успел закончиться сам между решением и Escape — не задваиваем.
reset_all
deliver 60 "посчитай итог"
PANE_NOW=$'✻ Working… (3s · esc to interrupt)\n❯\xc2\xa0'
tmux() {
  case "$1" in
    capture-pane) printf '%s' "$PANE_NOW" ;;
    send-keys)
      local a; for a in "$@"; do printf '%s\n' "$a"; done | tail -1 >> "$KEYS"
      # Escape пришёл после конца хода: stop-hook уже записал Stop.
      [ "${*: -1}" = Escape ] && touch "$WS/logs/verbose-2026-11-23.jsonl" ;;
  esac
  return 0
}
pii_switch_claude "посреди хода" interrupt
grep -qx "посчитай итог" "$KEYS" && fail "ответ уже был — повтор задвоил бы его"
grep -q '^RESTART' "$EVENTS" || fail "режим всё равно переключается"

# 4. Возврат через прокси — без прерывания и без повтора.
reset_all
deliver 30 "ещё вопрос"
PII_WANT="$PII_MODE_PROXY"
pii_switch_claude "простой"
[ -s "$KEYS" ] && fail "возврат через прокси ничего не набирает"
grep -q '^RESTART .* mode=proxy$' "$EVENTS" || fail "возврат через прокси — перезапуск в простое"

# 5. Промпт не дождались — ничего не набираем.
PANE_NOW=$'✻ Working… (1s · esc to interrupt)'
: > "$KEYS"
pii_replay_type "$SESSION" "текст" && fail "без промпта набирать нельзя"
[ -s "$KEYS" ] && fail "без промпта ничего не отправлено"

echo "OK: pii-replay.test.sh"
