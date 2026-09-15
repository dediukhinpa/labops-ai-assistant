#!/usr/bin/env bash
# session-reset.sh — команда «/reset force» из Telegram: очистить контекст живой
# сессии агента.
#
# ПОЧЕМУ ТАК. Раньше плагин отвечал «сессия сброшена» и пересылал модели текст
# «/reset force». Его никто не обрабатывал, а сама модель не может выполнить
# /clear над своей сессией: контекст оставался прежним, хук SessionEnd не
# срабатывал, дневник в общую память не уходил (15.09.2026). Рабочий путь —
# набрать /clear в панели сессии, как это сделал бы человек: Claude Code тогда
# зовёт SessionEnd (reason=clear, brain-flush.sh отправляет дневник в inbox/) и
# SessionStart (source=clear). Проверено на Claude Code 2.1: /clear, набранный
# через tmux send-keys, даёт ровно эти два события. Процесс, MCP-серверы и канал
# при этом не перезапускаются.
#
# Набирать должен watchdog, а не плагин: плагин живёт внутри сессии, и ответ
# «сброшено» должен прийти после фактического сброса. Поэтому, как у /doctor,
# плагин только кладёт заявку, а исполняет и отчитывается watchdog.
#
# Библиотека: при сорсинге ничего не делает. Нужны функции lib/pane.sh.

# shellcheck shell=bash

# Сколько ждать конца текущего хода, прежде чем отменить заявку, секунд.
SESSION_RESET_MAX_WAIT="${SESSION_RESET_MAX_WAIT:-1800}"
# Сколько ждать подтверждения сброса от хуков после набора /clear, секунд.
SESSION_RESET_CONFIRM_SEC="${SESSION_RESET_CONFIRM_SEC:-20}"

# reset_request_path <agent> — файл заявки. Каталог тот же, что у /doctor;
# плагин собирает путь в tg-plugin/plugin/src/commands/oob.ts — держать в синхроне.
reset_request_path() {
  printf '%s/shared/state/%s/reset.request' "${CLAUDE_LAB:-$HOME/.claude-lab}" "$1"
}

reset_request_pending() {   # <agent>
  [ -f "$(reset_request_path "$1")" ]
}

# reset_request_age <agent> — сколько секунд лежит заявка (0, если не прочитать).
reset_request_age() {
  local f mtime
  f="$(reset_request_path "$1")"
  mtime="$(stat -c %Y "$f" 2>/dev/null || true)"
  case "$mtime" in ''|*[!0-9]*) echo 0; return ;; esac
  echo $(( $(date +%s) - mtime ))
}

# reset_request_take <agent> — забрать заявку: печатает chat_id и возвращает 0.
# Через mv, чтобы одну заявку не исполнили дважды.
reset_request_take() {
  local f taken
  f="$(reset_request_path "$1")"
  [ -f "$f" ] || return 1
  taken="$f.taken.$$"
  mv "$f" "$taken" 2>/dev/null || return 1
  cat "$taken" 2>/dev/null || true
  rm -f "$taken" 2>/dev/null || true
  return 0
}

# reset_pane_ready <pane-text> <session> — можно ли набрать /clear прямо сейчас:
# промпт на экране, ход не идёт, в поле ввода нет текста оператора. Нарисованная
# подсказка при пустом буфере (см. buffer_is_empty в lib/pane.sh) вводом не
# считается. Посреди хода /clear встал бы в очередь или оборвал бы работу.
reset_pane_ready() {
  local tail="$1" session="$2"
  has_prompt "$tail" || return 1
  has_active_turn "$tail" && return 1
  looks_like_overlay "$tail" && return 1
  [ -z "$(pane_input "$tail")" ] && return 0
  buffer_is_empty "$session"
}

# _hooks_log_size <file> — размер лога хуков в байтах (0, если файла нет).
_hooks_log_size() {
  stat -c %s "$1" 2>/dev/null || echo 0
}

# session_clear <session> <hooks-log> — набрать /clear и дождаться подтверждения:
# в логе хуков после набора появилась строка SessionEnd (brain-flush с
# «(session-end)») или SessionStart («[session-start]»). Возвращает 0 при
# подтверждении. Без подтверждения чистит поле, чтобы «/clear» не остался
# висеть в нём и не ушёл вместе со следующим сообщением оператора.
session_clear() {
  local session="$1" hooks_log="$2" before waited=0
  before="$(_hooks_log_size "$hooks_log")"
  tmux send-keys -t "=$session:^.{top-left}" -l "/clear" 2>/dev/null || return 1
  sleep 1
  tmux send-keys -t "=$session:^.{top-left}" Enter 2>/dev/null || return 1
  while [ "$waited" -lt "$SESSION_RESET_CONFIRM_SEC" ]; do
    sleep 1
    waited=$((waited + 1))
    if tail -c +"$((before + 1))" "$hooks_log" 2>/dev/null \
         | grep -qaE '\(session-end\)|\[session-start\]'; then
      return 0
    fi
  done
  tmux send-keys -t "=$session:^.{top-left}" C-u 2>/dev/null || true
  return 1
}

# serve_session_reset — исполнить заявку, если она есть. Использует переменные
# watchdog: AGENT, SESSION, AGENT_WS, TG_SEND и функцию log.
# Заявку исполняем, только когда сессия простаивает: посреди хода /clear встал бы
# в очередь или оборвал работу. Ждём конца хода до SESSION_RESET_MAX_WAIT, потом
# отменяем и честно говорим об этом. Отвечаем оператору по факту сброса.
# SESSION_RESET_SERVED=1 после вызова — /clear набирался.
SESSION_RESET_WAIT_LOGGED=0
SESSION_RESET_SERVED=0
serve_session_reset() {
  local tail chat msg
  SESSION_RESET_SERVED=0
  reset_request_pending "$AGENT" || return 0
  tmux has-session -t "=$SESSION" 2>/dev/null || return 0
  tail="$(tmux capture-pane -pt "=$SESSION:^.{top-left}" -S -8 2>/dev/null || true)"
  if ! reset_pane_ready "$tail" "$SESSION"; then
    if [ "$(reset_request_age "$AGENT")" -ge "$SESSION_RESET_MAX_WAIT" ]; then
      chat="$(reset_request_take "$AGENT")" || return 0
      SESSION_RESET_WAIT_LOGGED=0
      log "запрос /reset отменён: агент не освободился за ${SESSION_RESET_MAX_WAIT}с"
      ( TG_CHAT_ID="$chat" "$TG_SEND" "$AGENT" \
          "⚠️ Сброс сессии отменён: агент так и не закончил текущую задачу. Пришлите /stop, затем /reset force." ) \
        >/dev/null 2>&1 || true
    elif [ "$SESSION_RESET_WAIT_LOGGED" -eq 0 ]; then
      log "запрос /reset ждёт конца текущего хода"
      SESSION_RESET_WAIT_LOGGED=1
    fi
    return 0
  fi
  chat="$(reset_request_take "$AGENT")" || return 0
  SESSION_RESET_WAIT_LOGGED=0
  SESSION_RESET_SERVED=1
  log "запрос /reset принят — очищаю контекст (/clear)"
  if session_clear "$SESSION" "$AGENT_WS/logs/hooks.log"; then
    log "сессия сброшена (/clear подтверждён хуками)"
    msg="✅ Сессия сброшена: контекст очищен, память сохранена."
  else
    log "сброс не подтверждён: хуки SessionEnd/SessionStart не отметились за ${SESSION_RESET_CONFIRM_SEC}с"
    msg="⚠️ Не удалось подтвердить сброс сессии. Пришлите /doctor."
  fi
  ( TG_CHAT_ID="$chat" "$TG_SEND" "$AGENT" "$msg" ) >/dev/null 2>&1 || true
  return 0
}
