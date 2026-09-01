#!/usr/bin/env bash
# pane-recover.sh — reliably submit a stuck/unsubmitted input in an agent's
# tmux session. See lib/pane.sh for WHY the channel auto-submit sticks.
#
# Strategy (all via tmux, the same session the watchdog owns):
#   1. read the input box (best-effort — only the last visual line survives);
#   2. clear it: Ctrl-U, then a Backspace burst as fallback;
#   3. re-type the text as LITERAL keystrokes + Enter — this submits cleanly
#      because it is not a bracketed paste (task-poller proves it).
#
# ОТКУДА БЕРЁТСЯ ТЕКСТ. Из панели читается только визуальная строка с «❯», то
# есть НАЧАЛО сообщения: замерено на 80 колонках — 202 символа превращаются в
# 77, и агент выполнял обрезанную на полуслове инструкцию. Поэтому, если
# нарисованное подтверждено меткой доставки (lib/pane.sh::inbound_matches),
# перепечатываем ПОЛНЫЙ текст из метки, а панель остаётся запасным вариантом.
# Переносы строк при этом склеиваются в пробелы: литеральный перевод строки в
# поле ввода означает отправку, и многострочное сообщение ушло бы кусками.
#
# If the box cannot be cleared, we bail and let the caller escalate to the
# operator (same as today).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/pane.sh
. "$SCRIPT_DIR/pane.sh"

# Settle delay between key actions (override to 0 in tests).
RECOVER_SETTLE="${RECOVER_SETTLE:-0.3}"
# Пауза между литеральным вводом и Enter. Замерено на живой сессии 2026-08-09:
# с паузой 1s Enter не коммитил строку, с 2s — коммитил. 0.3s (RECOVER_SETTLE)
# заведомо мало, поэтому отдельная константа, а не переиспользование.
RECOVER_SUBMIT_DELAY="${RECOVER_SUBMIT_DELAY:-2}"
# Backspace-burst length when Ctrl-U leaves residue.
RECOVER_BSPACE="${RECOVER_BSPACE:-64}"

_recover_capture() { tmux capture-pane -pt "$1" -S -8 2>/dev/null || true; }

# _reflow_inbound <text> — склеить переносы строк в пробелы (см. шапку).
_reflow_inbound() {
  printf '%s' "${1:-}" | tr '\n\t' '  ' | tr -s ' ' | sed -e 's/^ //' -e 's/ $//'
}

# recover_stuck_input <session> [agent]
#   0 — input was stuck and has been cleared+resubmitted
#   1 — input was stuck but could NOT be cleared (caller should escalate)
#   2 — nothing to do (input not stuck)
# Без <agent> метка доставки недоступна и текст берётся только из панели.
# RECOVER_TRUNCATED — выставляется каждым вызовом: 1, если восстановленный текст
# заведомо неполон (ввод занимал больше строки, а метки, из которой можно взять
# полный текст, не нашлось). Вызывающий решает, беспокоить ли этим оператора:
# точное восстановление его не касается, потерянный хвост — касается.
# RECOVER_SOURCE — marker | pane, откуда взят перепечатанный текст (для логов).
RECOVER_TRUNCATED=0
RECOVER_SOURCE=pane

recover_stuck_input() {
  local session="$1" agent="${2:-}" pane text full
  pane="$(_recover_capture "$session")"
  is_stuck_input "$pane" || return 2

  text="$(pane_input_raw "$pane")"
  RECOVER_TRUNCATED=0
  RECOVER_SOURCE=pane
  if [ -n "$agent" ] && inbound_matches "$agent" "$text" \
     && full="$(inbound_delivered_text "$agent")" && [ -n "$full" ]; then
    text="$(_reflow_inbound "$full")"
    RECOVER_SOURCE=marker
  elif input_is_multiline "$pane"; then
    RECOVER_TRUNCATED=1
  fi

  # 1. Очистка поля — ТОЛЬКО если в буфере действительно что-то есть.
  # Чаще всего его там нет: сорванный auth-submit канала оставляет лишь
  # ОТРИСОВКУ сообщения (см. buffer_is_empty в pane.sh). Раньше проверка
  # «очистилось ли» читала ту же отрисовку, вечно видела текст и возвращала 1
  # («box won't clear») — восстановление сдавалось ровно в том случае, ради
  # которого написано, и звало оператора. Теперь пустоту подтверждает курсор.
  if ! buffer_is_empty "$session"; then
    tmux send-keys -t "$session" C-u 2>/dev/null || return 1
    sleep "$RECOVER_SETTLE"
    if ! buffer_is_empty "$session"; then
      # Ctrl-U left residue (stuck paste can resist it) → backspace burst.
      local i
      for ((i = 0; i < RECOVER_BSPACE; i++)); do
        tmux send-keys -t "$session" BSpace 2>/dev/null || break
      done
      sleep "$RECOVER_SETTLE"
      buffer_is_empty "$session" || return 1   # still stuck — give up
    fi
  fi

  # 2. Перепечатываем текст литерально и отправляем. Литеральный ввод — не
  # bracketed paste, поэтому Enter его коммитит (проверено вручную на живой
  # сессии 2026-08-09: именно так потерянное сообщение оператора дошло до
  # модели). Пауза перед Enter обязательна — на живой сессии отправка сразу
  # после -l не срабатывала, TUI не успевал принять строку.
  if [ -n "$text" ]; then
    tmux send-keys -t "$session" -l "$text" 2>/dev/null || return 1
    sleep "$RECOVER_SUBMIT_DELAY"
  fi
  tmux send-keys -t "$session" Enter 2>/dev/null || return 1
  return 0
}
