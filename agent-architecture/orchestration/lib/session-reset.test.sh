#!/usr/bin/env bash
# session-reset.test.sh — «/reset force» из Telegram: заявка → watchdog набирает
# /clear в панели → ответ оператору по факту.
#
# Главное: сброс не рапортуется, пока хуки его не подтвердили; посреди хода и
# поверх набранного оператором текста /clear не набирается; одна заявка
# исполняется один раз. Панель — настоящая tmux-сессия в своём сервере, вместо
# Claude Code в ней простой скрипт: рисует «❯ », читает строку и на «/clear»
# пишет в лог хуков то же, что пишет brain-flush.sh из хука SessionEnd.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
# shellcheck source=lib/tmux-test-isolation.sh
. "$HERE/tmux-test-isolation.sh"
tmux_test_isolate "$TMP"
cleanup() { tmux_test_kill_server; rm -rf "$TMP"; }
trap cleanup EXIT

command -v tmux >/dev/null 2>&1 || { echo "session-reset: пропуск — нет tmux"; exit 0; }

# shellcheck source=lib/pane.sh
. "$HERE/pane.sh"
# shellcheck source=lib/session-reset.sh
. "$HERE/session-reset.sh"

pass=0; fail=0
ok()  { echo "✓ $*"; pass=$((pass+1)); }
bad() { echo "✗ $*"; fail=$((fail+1)); }

export CLAUDE_LAB="$TMP/lab"
AGENT=dev
SESSION=labops-dev-test
AGENT_WS="$CLAUDE_LAB/$AGENT/.claude"
HOOKS="$AGENT_WS/logs/hooks.log"
SENT="$TMP/sent.txt"
mkdir -p "$AGENT_WS/logs"
: > "$HOOKS"
log() { echo "LOG: $*" >> "$TMP/watchdog.log"; }

# Подставной tg-send.sh: записывает, кому и что ушло.
TG_SEND="$TMP/tg-send.sh"
cat > "$TG_SEND" <<EOF
#!/usr/bin/env bash
printf '%s|%s\n' "\${TG_CHAT_ID:-}" "\$2" >> "$SENT"
EOF
chmod +x "$TG_SEND"

# Подставная панель Claude Code. MODE: ok — /clear подтверждается хуком;
# ignore — хуки молчат; busy — идёт ход.
FAKE="$TMP/fake-claude.sh"
cat > "$FAKE" <<'EOF'
#!/usr/bin/env bash
mode="$1" hooks="$2"
while :; do
  if [ "$mode" = busy ]; then
    printf '● Working…\n  ✻ Thinking (esc to interrupt)\n'
    sleep 3600
  fi
  printf '────\n❯ '
  IFS= read -r line || exit 0
  if [ "$line" = "/clear" ] && [ "$mode" = ok ]; then
    echo "2026-09-15T00:00:00Z [brain-flush] skip (session-end): content unchanged" >> "$hooks"
    printf '\033[2J\033[H'
  fi
done
EOF
chmod +x "$FAKE"

# wait_pane <grep-шаблон> — дождаться строки в панели (до 10 с). Фиксированные
# паузы под нагрузкой полного test.sh не успевали за отрисовкой.
wait_pane() {
  local i
  for i in $(seq 1 50); do
    tmux capture-pane -pt "=$SESSION:^.{top-left}" -S -8 2>/dev/null | grep -qa -- "$1" && return 0
    sleep 0.2
  done
  return 1
}
start_pane() {   # <mode>
  tmux kill-session -t "=$SESSION" 2>/dev/null || true
  tmux new-session -d -s "$SESSION" -x 120 -y 20 "bash $FAKE $1 $HOOKS"
  if [ "$1" = busy ]; then wait_pane 'esc to interrupt'; else wait_pane '❯'; fi
}
put_request() { mkdir -p "$(dirname "$(reset_request_path "$AGENT")")"; printf '%s' "$1" > "$(reset_request_path "$AGENT")"; }
pane() { tmux capture-pane -pt "=$SESSION:^.{top-left}" -S -8 2>/dev/null; }

export SESSION_RESET_CONFIRM_SEC=4

# 1. Нет заявки — ничего не набирается.
start_pane ok
serve_session_reset
[ "$SESSION_RESET_SERVED" -eq 0 ] && [ ! -s "$HOOKS" ] && ok "без заявки панель не трогается" \
  || bad "без заявки что-то набрано"

# 2. Простой — /clear набран, хук подтвердил, оператору «сброшено» в его чат.
: > "$SENT"; : > "$HOOKS"
put_request 424242
serve_session_reset
if [ "$SESSION_RESET_SERVED" -eq 1 ] && grep -q '(session-end)' "$HOOKS" \
   && grep -q '^424242|✅ Сессия сброшена' "$SENT"; then
  ok "простой: /clear набран, подтверждён хуком, ответ ушёл в чат заявки"
else
  bad "простой: сброс не прошёл (sent=$(cat "$SENT"), hooks=$(cat "$HOOKS"))"
fi
reset_request_pending "$AGENT" && bad "заявка не забрана после исполнения" || ok "заявка забрана"

# 3. Повторный вызов — второй раз не сбрасывает.
: > "$SENT"; : > "$HOOKS"
serve_session_reset
[ ! -s "$SENT" ] && [ ! -s "$HOOKS" ] && ok "одна заявка исполняется один раз" \
  || bad "заявка исполнилась повторно"

# 4. Идёт ход — ждём, ничего не набираем и не отвечаем.
start_pane busy
: > "$SENT"; : > "$HOOKS"
put_request 424242
SESSION_RESET_MAX_WAIT=1800 serve_session_reset
if [ "$SESSION_RESET_SERVED" -eq 0 ] && reset_request_pending "$AGENT" && [ ! -s "$SENT" ] \
   && ! pane | grep -q '/clear'; then
  ok "идёт ход: заявка ждёт, /clear не набран, оператору не отвечено"
else
  bad "идёт ход: сброс не дождался конца хода"
fi

# 5. Ход так и не кончился — заявка отменяется с честным ответом, /clear не набран.
SESSION_RESET_MAX_WAIT=0 serve_session_reset
if ! reset_request_pending "$AGENT" && grep -q '^424242|⚠️ Сброс сессии отменён' "$SENT" \
   && ! pane | grep -q '/clear'; then
  ok "таймаут ожидания: заявка отменена, оператор знает, /clear не набран"
else
  bad "таймаут ожидания обработан неверно (sent=$(cat "$SENT"))"
fi

# 6. В поле набран текст оператора — поверх него /clear не набираем.
start_pane ok
: > "$SENT"; : > "$HOOKS"
tmux send-keys -t "=$SESSION:^.{top-left}" -l "недописанное сообщение"
wait_pane 'недописанное сообщение' || bad "текст не отрисовался в панели"
put_request 424242
SESSION_RESET_MAX_WAIT=1800 serve_session_reset
if reset_request_pending "$AGENT" && [ ! -s "$HOOKS" ] && pane | grep -q 'недописанное сообщение'; then
  ok "набранный текст оператора не затирается: заявка ждёт"
else
  bad "набранный текст оператора затёрт или сброс прошёл поверх"
fi
rm -f "$(reset_request_path "$AGENT")"

# 7. Хуки не подтвердили — не врём «сброшено», поле очищено от «/clear».
start_pane ignore
: > "$SENT"; : > "$HOOKS"
put_request 424242
serve_session_reset
sleep 1
if grep -q '^424242|⚠️ Не удалось подтвердить сброс' "$SENT" && ! grep -q 'Сессия сброшена' "$SENT"; then
  ok "без подтверждения хуков — честный ответ, а не «сброшено»"
else
  bad "без подтверждения ответ неверный (sent=$(cat "$SENT"))"
fi
[ -z "$(pane_input "$(pane)")" ] && ok "без подтверждения «/clear» не остаётся в поле" \
  || bad "в поле остался текст: $(pane_input "$(pane)")"

# 8. Контракт пути заявки с плагином и подключение в watchdog.
PLUGIN_OOB="$HERE/../../../tg-plugin/plugin/src/commands/oob.ts"
if [ ! -f "$PLUGIN_OOB" ] || grep -q "resolveStateRequestPath('reset.request'" "$PLUGIN_OOB"; then
  ok "плагин кладёт заявку в тот же reset.request"
else
  bad "плагин и watchdog расходятся в имени заявки"
fi
grep -q 'reset_request_pending "\$AGENT"; then serve_reset_request' "$HERE/../watchdog.sh" \
  && grep -q 'source "\$SCRIPT_DIR/lib/session-reset.sh"' "$HERE/../watchdog.sh" \
  && ok "watchdog проверяет заявки на сброс в быстром цикле" \
  || bad "watchdog не подключает обслуживание /reset"

echo "session-reset: passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
