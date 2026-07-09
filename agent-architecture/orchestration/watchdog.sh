#!/usr/bin/env bash
# watchdog.sh — держит агента живым. Перезапускает tmux-сессию если она падает.
# Usage: watchdog.sh <agent-name>
# Designed to be the ExecStart of a Type=simple systemd service.
set -euo pipefail

AGENT="$1"
SESSION="labops-$AGENT"
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
START_SCRIPT="$SCRIPT_DIR/start-agent.sh"

# Best-effort Telegram alerts to the Operator on failures/restarts. Opt-in via
# WATCHDOG_TG_ALERTS (default 1); never fatal; throttled. See lib/notify.sh.
# shellcheck source=lib/notify.sh
source "$SCRIPT_DIR/lib/notify.sh"

log() { echo "[watchdog/$AGENT] $(date -u '+%H:%M:%S') $*"; }

# Initial start — but DON'T disrupt an already-running agent. This lets the
# watchdog itself be restarted (e.g. to pick up new code) without killing the
# live tmux session: if the session is alive we just resume monitoring.
log "starting..."
if tmux has-session -t "$SESSION" 2>/dev/null; then
  log "session already alive — resuming monitor without restart"
else
  "$START_SCRIPT" "$AGENT"
fi

# Liveness model. The ONLY reliable "a turn is actively running" marker is the
# "esc to interrupt" footer: Claude Code shows it for the whole duration of a turn
# and removes it the instant the turn ends. The elapsed-time line ("Cooked for
# 8s") PERSISTS on screen after a turn completes — keying on it would falsely flag
# a healthy idle agent that just finished a quick turn (this regressed silvio:
# old pattern `for [0-9]+s` matched the leftover "Cooked for Ns" marker and
# restarted an idle agent). So active-turn detection keys ONLY on "esc to
# interrupt".
#
# Two silent-failure modes seen in this lab, both invisible to a naive
# prompt-marker check (a hung TUI still renders ❯ / bypass-permissions):
#   (A) frozen turn — "esc to interrupt" present but pane byte-identical across
#       cycles (timer stopped) → turn wedged. Restart after ~60s.
#   (B) stuck input — an injected inbound sits in ❯ unsubmitted, no active turn.
#       A single Enter does NOT commit a bracketed-paste inbound (verified
#       2026-06-13 on silvio); escalate Enter → Escape+Enter → restart. Acted on
#       ONLY when the input box is non-empty, so a clean idle prompt is never
#       disturbed.
ACTIVE_RE='esc to interrupt'
PROMPT_RE='Listening for channel|❯|bypass permissions'
PREV_TAIL=""
FROZEN_COUNT=0
NUDGE_STAGE=0

restart_session() {
  log "restarting ($1)"
  notify_op "$AGENT" "⚠️ перезапуск tmux-сессии — причина: $1"
  "$START_SCRIPT" "$AGENT"
  notify_op "$AGENT" "✅ сессия снова в строю (после: $1)"
  PREV_TAIL=""; FROZEN_COUNT=0; NUDGE_STAGE=0
}

while true; do
  sleep 30

  # Defense in depth: reap any ORPHANED channel-server bun for this agent — its
  # claude parent died but the bun is spinning (PPID==1). The live bun is a child
  # of the live claude (PPID!=1) so it is never touched. Catches orphans from any
  # path (crash, manual kill, restart race), not just start-agent.sh restarts.
  for p in $(pgrep -f "\.claude-lab/$AGENT/\.claude/plugins/labops-channel/plugin/src/server\.ts" 2>/dev/null || true); do
    if [ "$(awk '{print $4}' "/proc/$p/stat" 2>/dev/null)" = "1" ]; then
      log "reaping orphaned channel-bun pid=$p (ppid=1, parent claude died)"
      kill -9 "$p" 2>/dev/null || true
      notify_op "$AGENT" "♻️ подобрал осиротевший channel-сервер (pid=$p): родительский claude умер"
    fi
  done

  # Session gone entirely
  if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    restart_session "session gone"
    continue
  fi

  TAIL=$(tmux capture-pane -pt "$SESSION" -S -8 2>/dev/null || true)

  # Pane moved since last cycle → agent is progressing; reset and move on
  if [ "$TAIL" != "$PREV_TAIL" ]; then
    FROZEN_COUNT=0; NUDGE_STAGE=0
    PREV_TAIL="$TAIL"
    continue
  fi

  # --- Pane is STATIC (~30s unchanged). Classify. ---

  # (A) Active-turn marker present but pane frozen → hung turn. Confirm over ~60s.
  if printf '%s' "$TAIL" | grep -qa "$ACTIVE_RE"; then
    FROZEN_COUNT=$((FROZEN_COUNT + 1))
    if [ "$FROZEN_COUNT" -ge 2 ]; then
      restart_session "frozen turn — esc-to-interrupt static ~60s"
      continue
    fi
    log "possible freeze (1/2) — confirming next cycle"
    continue
  fi
  FROZEN_COUNT=0

  # TUI lost its prompt entirely → restart
  if ! printf '%s' "$TAIL" | grep -qaE "$PROMPT_RE"; then
    restart_session "no prompt rendered"
    continue
  fi

  # (B) Idle prompt. Is there unsubmitted text stuck in the input box?
  # Strip everything THROUGH the ❯ marker: the idle prompt renders "❯" + a
  # non-breaking space (U+00A0), NOT "❯ " with an ASCII space, so the old
  # `s/.*❯ //` never matched and left the ❯+nbsp in INPUT. Then drop nbsp
  # (which [[:space:]] does NOT match) and all ASCII whitespace. A clean idle
  # prompt → empty INPUT; only genuinely typed text survives. Without this every
  # idle agent looked "stuck" → Enter/Escape/restart on a ~90s cycle, the main
  # cause of agents going silent (found 2026-06-13).
  INPUT=$(printf '%s' "$TAIL" | grep -a '❯' | tail -1 | sed -e 's/.*❯//' -e 's/\xc2\xa0//g' -e 's/[[:space:]]//g')
  if [ -z "$INPUT" ]; then
    NUDGE_STAGE=0          # clean idle prompt — healthy, leave it alone
    continue
  fi

  # Non-empty input that won't submit → escalate commit attempts (~30s apart).
  case "$NUDGE_STAGE" in
    0) log "stuck input detected — Enter"
       notify_op "$AGENT" "✉️ в поле ввода застрял неотправленный промпт — пробую дослать (Enter)"
       tmux send-keys -t "$SESSION" Enter 2>/dev/null || true
       NUDGE_STAGE=1 ;;
    1) log "stuck input persists — Escape then Enter (bracketed-paste commit)"
       tmux send-keys -t "$SESSION" Escape 2>/dev/null || true
       sleep 1
       tmux send-keys -t "$SESSION" Enter 2>/dev/null || true
       NUDGE_STAGE=2 ;;
    *) restart_session "stuck input unrecoverable"
       continue ;;
  esac
done
