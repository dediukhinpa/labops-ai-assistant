#!/usr/bin/env bash
# pane.sh — classify what an agent's tmux pane is showing.
#
# Extracted from watchdog.sh so the classification is testable: watchdog.sh is
# an endless supervision loop and cannot be sourced by a test.
#
# WHY THE OVERLAY CASE EXISTS:
# Claude Code slash commands (/context, /status, /cost, /help) are handled
# locally by the CLI — the model never runs. Two consequences make their output
# indistinguishable from a dead TUI:
#   1. the full-screen output scrolls the `❯` prompt out of the captured tail;
#   2. no hook fires (hooks are driven by model turns), so the heartbeat goes
#      stale exactly as it would if the session had died.
# The watchdog therefore restarted a perfectly healthy session — observed on
# the live host after an operator ran /context in the pane. Escape dismisses
# the overlay, which is what distinguishes it from a real freeze.

PROMPT_RE='❯|bypass permissions'
ACTIVE_RE='esc to interrupt'

# has_prompt <pane-text> — is the input prompt visible?
has_prompt() { printf '%s' "${1:-}" | grep -qaE "$PROMPT_RE"; }

# has_active_turn <pane-text> — is a model turn currently running?
has_active_turn() { printf '%s' "${1:-}" | grep -qa "$ACTIVE_RE"; }

# looks_like_overlay <pane-text> — does the pane show local slash-command
# output rather than the conversation? Advisory only: the authoritative test is
# whether Escape brings the prompt back (see watchdog.sh). Kept deliberately
# narrow — matching loosely here would mask real freezes.
looks_like_overlay() {
  printf '%s' "${1:-}" | grep -qaE \
    'Context Usage|Estimated usage by category|Auto-compact window|/context all to expand|Memory files ·|Skills ·'
}

# ── Stuck-input detection & recovery ─────────────────────────────────────────
# The tg channel delivers an inbound by asking Claude Code (research-preview
# `claude/channel`) to inject it into the input and auto-submit. That auto-submit
# intermittently fails, leaving the message in the `❯` box uncommitted — and a
# plain Enter cannot finalise a stuck bracketed-paste (verified: Enter, Escape,
# Ctrl-C, ESC[201~ all fail). The reliable path is to CLEAR the box and re-type
# the text as literal keystrokes + Enter (the same primitive task-poller uses,
# which submits cleanly because it is not a bracketed paste).

# pane_input <pane-text> — the input box contents with ALL whitespace stripped.
# Empty ⇒ clean idle prompt. Mirrors watchdog's emptiness test (❯ renders with a
# trailing U+00A0, not an ASCII space).
pane_input() {
  printf '%s' "${1:-}" | grep -a '❯' | tail -1 \
    | sed -e 's/.*❯//' -e 's/\xc2\xa0//g' -e 's/[[:space:]]//g'
}

# pane_input_raw <pane-text> — the input box contents with internal spaces kept
# but ends trimmed (for RE-TYPING the operator's message). Only the last visual
# line is recoverable from the pane, so a wrapped multi-line inbound cannot be
# faithfully reconstructed — callers must treat this as best-effort.
pane_input_raw() {
  printf '%s' "${1:-}" | grep -a '❯' | tail -1 \
    | sed -e 's/.*❯//' -e 's/\xc2\xa0//g' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# is_stuck_input <pane-text> — a message is sitting in the input unsubmitted:
# prompt visible, no active turn, input non-empty, and NOT the rotating
# placeholder hint Try"...". This is the state to recover.
is_stuck_input() {
  local t="${1:-}" inp
  has_prompt "$t" || return 1
  has_active_turn "$t" && return 1
  inp="$(pane_input "$t")"
  [ -n "$inp" ] || return 1
  printf '%s' "$inp" | grep -qE '^Try".*"$' && return 1
  return 0
}
