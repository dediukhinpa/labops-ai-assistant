#!/usr/bin/env bash
# watchdog.sh — держит агента живым. Перезапускает tmux-сессию если она падает.
# Usage: watchdog.sh <agent-name>
# Designed to be the ExecStart of a Type=simple systemd service.
set -euo pipefail

AGENT="$1"
SESSION="labops-$AGENT"
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
START_SCRIPT="$SCRIPT_DIR/start-agent.sh"

# Idle-triggered memory consolidation: after the agent sits on a clean idle prompt
# for MEMORY_IDLE_CONSOLIDATE_MIN minutes, nudge the session to reflect (once per
# idle period). Reflection runs in-session (no headless claude); this only pings it.
CLAUDE_LAB="${CLAUDE_LAB:-$HOME/.claude-lab}"
AGENT_WS="$CLAUDE_LAB/$AGENT/.claude"
REFLECT_NUDGE="$AGENT_WS/scripts/reflect-nudge.sh"
IDLE_CYCLES=$(( ${MEMORY_IDLE_CONSOLIDATE_MIN:-10} * 60 / 30 ))   # 30s per loop cycle

# Heartbeat proof-of-life: hooks (settings.json) tick $AGENT_WS/state/heartbeat at
# every turn/tool boundary (SessionStart/UserPromptSubmit/PreToolUse/PostToolUse/
# Notification/Stop). A FRESH heartbeat means the agent is demonstrably alive — used
# below to SUPPRESS false-positive restarts (a static pane that is really a long
# tool run). Hooks fire at boundaries, NOT continuously, so a STALE heartbeat is
# never a restart trigger on its own — it only lifts the suppression and lets the
# pane-based classifier decide. Tune the window via WATCHDOG_HEARTBEAT_GRACE_SEC.
HEARTBEAT_FILE="$AGENT_WS/state/heartbeat"
HEARTBEAT_GRACE="${WATCHDOG_HEARTBEAT_GRACE_SEC:-45}"
heartbeat_age() {   # seconds since last heartbeat, or 999999 if absent/unreadable
  local hb now
  [ -f "$HEARTBEAT_FILE" ] || { echo 999999; return; }
  hb=$(cat "$HEARTBEAT_FILE" 2>/dev/null || echo '')
  case "$hb" in ''|*[!0-9]*) echo 999999; return;; esac
  now=$(date +%s)
  echo $(( now - hb ))
}
heartbeat_fresh() { [ "$(heartbeat_age)" -le "$HEARTBEAT_GRACE" ]; }

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
# ❯ / bypass permissions — реальные маркеры отрисованного промпта. "Listening for
# channel" убран: строку текущие сборки claude не печатают (см. start-agent.sh).
PROMPT_RE='❯|bypass permissions'
PREV_TAIL=""
FROZEN_COUNT=0
NUDGE_STAGE=0
IDLE_COUNT=0
IDLE_CONSOLIDATED=0

restart_session() {
  log "restarting ($1)"
  notify_op "$AGENT" "⚠️ перезапуск tmux-сессии — причина: $1"
  "$START_SCRIPT" "$AGENT"
  notify_op "$AGENT" "✅ сессия снова в строю (после: $1)"
  PREV_TAIL=""; FROZEN_COUNT=0; NUDGE_STAGE=0; IDLE_COUNT=0; IDLE_CONSOLIDATED=0
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
    FROZEN_COUNT=0; NUDGE_STAGE=0; IDLE_COUNT=0; IDLE_CONSOLIDATED=0
    PREV_TAIL="$TAIL"
    continue
  fi

  # --- Pane is STATIC (~30s unchanged). Classify. ---

  # (A) Active-turn marker present but pane frozen → hung turn. Confirm over ~60s.
  if printf '%s' "$TAIL" | grep -qa "$ACTIVE_RE"; then
    # Fresh heartbeat = the turn is actively doing tool work, just not repainting
    # the pane this cycle → alive, not frozen. Escalate only when the pane is
    # static AND the heartbeat has gone stale (no hook fired within the grace).
    if heartbeat_fresh; then
      FROZEN_COUNT=0
      log "active turn, pane static but heartbeat fresh ($(heartbeat_age)s) — alive"
      continue
    fi
    FROZEN_COUNT=$((FROZEN_COUNT + 1))
    if [ "$FROZEN_COUNT" -ge 2 ]; then
      restart_session "frozen turn — esc-to-interrupt static ~60s, heartbeat stale"
      continue
    fi
    log "possible freeze (1/2) — pane static, heartbeat stale — confirming next cycle"
    continue
  fi
  FROZEN_COUNT=0

  # TUI lost its prompt entirely → restart, UNLESS a recent hook proves the
  # session is alive (mid-render / transient repaint). A truly dead TUI stops
  # firing hooks, so a stale heartbeat lets the restart proceed.
  if ! printf '%s' "$TAIL" | grep -qaE "$PROMPT_RE"; then
    if heartbeat_fresh; then
      log "no prompt rendered but heartbeat fresh ($(heartbeat_age)s) — deferring restart"
      continue
    fi
    restart_session "no prompt rendered — heartbeat stale"
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
  # Placeholder hint text (e.g. `Try "fix lint errors"`) renders dim/styled in
  # the TUI, which is how a human tells it apart from real typed input — but
  # capture-pane here has no `-e`, so that styling is invisible and the plain
  # text survives stripping just like real input would. The rotating hint
  # happening to hold still across one 30s poll then read as "stuck input" on
  # a perfectly idle agent → false Enter/Escape/restart cycle (found
  # 2026-07-12). Recognize the hint's fixed `Try "..."` shape and fold it into
  # the idle branch below, same as an empty INPUT.
  if [ -z "$INPUT" ] || printf '%s' "$INPUT" | grep -qE '^Try".*"$'; then
    NUDGE_STAGE=0          # clean idle prompt — healthy, leave it alone
    # Idle-triggered consolidation: once the agent has been idle long enough,
    # nudge it to reflect (episodic → passive). Fire once per idle period.
    IDLE_COUNT=$((IDLE_COUNT + 1))
    if [ "$IDLE_COUNT" -ge "$IDLE_CYCLES" ] && [ "$IDLE_CONSOLIDATED" -eq 0 ] && [ -f "$REFLECT_NUDGE" ]; then
      log "idle ${MEMORY_IDLE_CONSOLIDATE_MIN:-10}min → nudging memory consolidation"
      ( AGENT_WORKSPACE="$AGENT_WS" AGENT_ID="$AGENT" bash "$REFLECT_NUDGE" --reason idle >/dev/null 2>&1 || true ) &
      IDLE_CONSOLIDATED=1
    fi
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
