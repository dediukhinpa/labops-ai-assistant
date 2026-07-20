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
