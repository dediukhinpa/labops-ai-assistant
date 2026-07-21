#!/usr/bin/env bash
# pane-recover.sh — reliably submit a stuck/unsubmitted input in an agent's
# tmux session. See lib/pane.sh for WHY the channel auto-submit sticks.
#
# Strategy (all via tmux, the same session the watchdog owns):
#   1. read the input box (best-effort — only the last visual line survives);
#   2. clear it: Ctrl-U, then a Backspace burst as fallback;
#   3. re-type the captured text as LITERAL keystrokes + Enter — this submits
#      cleanly because it is not a bracketed paste (task-poller proves it).
#
# If the box cannot be cleared, we bail and let the caller escalate to the
# operator (same as today). If the inbound was long/multi-line, the retype is
# lossy by nature; the real fix for fidelity is prevention in the plugin
# (deliver via send-keys instead of the channel paste) — see AGENT_ROUTER.md /
# the tg-plugin. This recovery is the immediate safety net.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/pane.sh
. "$SCRIPT_DIR/pane.sh"

# Settle delay between key actions (override to 0 in tests).
RECOVER_SETTLE="${RECOVER_SETTLE:-0.3}"
# Backspace-burst length when Ctrl-U leaves residue.
RECOVER_BSPACE="${RECOVER_BSPACE:-64}"

_recover_capture() { tmux capture-pane -pt "$1" -S -8 2>/dev/null || true; }

# recover_stuck_input <session>
#   0 — input was stuck and has been cleared+resubmitted
#   1 — input was stuck but could NOT be cleared (caller should escalate)
#   2 — nothing to do (input not stuck)
recover_stuck_input() {
  local session="$1" pane text
  pane="$(_recover_capture "$session")"
  is_stuck_input "$pane" || return 2

  text="$(pane_input_raw "$pane")"

  # 1. clear the box
  tmux send-keys -t "$session" C-u 2>/dev/null || return 1
  sleep "$RECOVER_SETTLE"
  pane="$(_recover_capture "$session")"
  if [ -n "$(pane_input "$pane")" ]; then
    # Ctrl-U left residue (stuck paste can resist it) → backspace burst.
    local i
    for ((i = 0; i < RECOVER_BSPACE; i++)); do
      tmux send-keys -t "$session" BSpace 2>/dev/null || break
    done
    sleep "$RECOVER_SETTLE"
    pane="$(_recover_capture "$session")"
    [ -z "$(pane_input "$pane")" ] || return 1   # still stuck — give up
  fi

  # 2. re-type the captured text literally and submit
  if [ -n "$text" ]; then
    tmux send-keys -t "$session" -l "$text" 2>/dev/null || return 1
  fi
  tmux send-keys -t "$session" Enter 2>/dev/null || return 1
  return 0
}
