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
declare -A _NOTIFY_TS 2>/dev/null || true

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
  local now last
  now="$(date +%s)"
  last="${_NOTIFY_TS[$msg]:-0}"
  if [ "$((now - last))" -lt "$cooldown" ]; then
    return 0
  fi
  _NOTIFY_TS[$msg]="$now"

  local here send
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  send="${NOTIFY_SEND_CMD:-$here/../tg-send.sh}"
  # Subshell + `|| true`: a non-zero exit (network down, no channel.env, blocked)
  # must never propagate to the caller's `set -e`.
  ( TG_CHAT_ID="${WATCHDOG_ALERT_CHAT_ID:-}" "$send" "$agent" "$msg" ) >/dev/null 2>&1 || true
  return 0
}
