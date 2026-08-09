#!/usr/bin/env bash
# notify.sh — best-effort Telegram alerts to the Operator from supervisor daemons
# (watchdog and friends). SOURCE this file; it provides notify_op():
#
#     notify_op <agent> <message...>
#
# Guarantees:
#   * opt-in      — WATCHDOG_TG_ALERTS=1 (default) enables; set 0 to disable.
#   * never fatal — a failed/blocked send returns 0, so a `set -e` daemon keeps
#                   running even when Telegram is unreachable or unconfigured.
#   * throttled   — an identical message is sent at most once per
#                   WATCHDOG_ALERT_COOLDOWN seconds (default 300), so flapping
#                   (restart→online→restart…) never spams the Operator.
#   * delivery via tg-send.sh (bot token + Operator chat_id resolved from
#     channel.env — no secrets here). Override the sender with NOTIFY_SEND_CMD
#     (used by the unit test). A dedicated alert chat may be set with
#     WATCHDOG_ALERT_CHAT_ID; otherwise the Operator chat from channel.env is used.

# Per-message last-sent timestamps (bash 4+). Guarded so re-sourcing is harmless.
# ВНИМАНИЕ: это лишь кэш в памяти процесса — он НЕ переживает рестарт демона.
# Ровно поэтому троттл раньше не работал в самом важном сценарии: watchdog падал
# и systemd поднимал его заново, память обнулялась, и оператор получал один и тот
# же алерт каждые ~2 минуты часами (найдено 2026-08-09). Источник правды теперь —
# файловые метки в $NOTIFY_STATE_DIR; массив остаётся быстрым fallback'ом на
# случай, когда каталог состояния недоступен (нет прав, read-only fs).
declare -A _NOTIFY_TS 2>/dev/null || true

# Каталог файловых меток «когда это сообщение отправляли в прошлый раз».
_notify_state_dir() {
  printf '%s' "${NOTIFY_STATE_DIR:-${CLAUDE_LAB:-$HOME/.claude-lab}/shared/state/notify}"
}

# _notify_key <msg> — стабильное имя файла-метки для сообщения.
_notify_key() {
  local h
  h="$(printf '%s' "${1:-}" | sha256sum 2>/dev/null | cut -c1-32)"
  [ -n "$h" ] || h="$(printf '%s' "${1:-}" | cksum 2>/dev/null | tr -d ' ' || true)"
  printf '%s' "${h:-fallback}"
}

notify_op() {
  local agent="${1:-}"; shift || true
  local body="$*"
  [ "${WATCHDOG_TG_ALERTS:-1}" = "1" ] || return 0
  [ -n "$agent" ] || return 0

  # Source label shown to the Operator; override with NOTIFY_TAG (e.g. a backend
  # monitor sets NOTIFY_TAG="second_brain-monitor"). Defaults to "watchdog/<agent>".
  local label="${NOTIFY_TAG:-watchdog/${agent}}"
  local msg="🔧 ${label}: ${body}"
  local cooldown="${WATCHDOG_ALERT_COOLDOWN:-300}"
  local now last last_file dir stamp
  now="$(date +%s)"
  last="${_NOTIFY_TS[$msg]:-0}"

  # Файловая метка переживает рестарт демона — берём более позднюю из двух.
  dir="$(_notify_state_dir)"
  stamp=""
  if mkdir -p "$dir" 2>/dev/null; then
    stamp="$dir/$(_notify_key "$msg")"
    last_file="$(cat "$stamp" 2>/dev/null || echo 0)"
    case "$last_file" in ''|*[!0-9]*) last_file=0 ;; esac
    # ВАЖНО: только if — конструкция `[ ... ] && x=y` возвращает 1 при ложном
    # условии и под `set -e` убила бы вызывающий демон (тот же класс бага, что
    # ронял watchdog на recover_stuck_input).
    if [ "$last_file" -gt "$last" ]; then last="$last_file"; fi
    # Дешёвая уборка: метки старше суток уже никого не троттлят.
    find "$dir" -maxdepth 1 -type f -mmin +1440 -delete 2>/dev/null || true
  fi

  if [ "$((now - last))" -lt "$cooldown" ]; then
    return 0
  fi
  _NOTIFY_TS[$msg]="$now"
  if [ -n "$stamp" ]; then printf '%s' "$now" > "$stamp" 2>/dev/null || true; fi

  local here send
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  send="${NOTIFY_SEND_CMD:-$here/../tg-send.sh}"
  # Subshell + `|| true`: a non-zero exit (network down, no channel.env, blocked)
  # must never propagate to the caller's `set -e`.
  ( TG_CHAT_ID="${WATCHDOG_ALERT_CHAT_ID:-}" "$send" "$agent" "$msg" ) >/dev/null 2>&1 || true
  return 0
}
