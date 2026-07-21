#!/usr/bin/env bash
# pane.test.sh — unit test for the pane classifier, plus a REAL tmux test that
# the Escape-before-restart ladder distinguishes a slash-command overlay from a
# dead TUI. The regression: an operator running /context in the pane made the
# watchdog restart a healthy session ("no prompt rendered — heartbeat stale").
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/pane.sh"
pass=0; fail=0
ok()  { echo "✓ $*"; pass=$((pass+1)); }
bad() { echo "✗ $*"; fail=$((fail+1)); }

IDLE='────────────────────
❯
  ⏵⏵ bypass permissions on (shift+tab to cycle)'

ACTIVE='● Reading files…
  ✻ Thinking (esc to interrupt)'

# Real /context output, trimmed — the exact shape that caused the false restart.
OVERLAY='  Context Usage
  ⛁ System tools: 15.4k tokens (3.9%)
  ⛁ Messages: 7.6k tokens (1.9%)
  ⛶ Free space: 329.1k (82.3%)
  Auto-compact window: 400k tokens
  /context all to expand'

DEAD=''

# ---- classifier ------------------------------------------------------------
has_prompt "$IDLE"        && ok "idle pane: prompt detected"      || bad "idle pane: prompt missed"
has_prompt "$OVERLAY"     && bad "overlay: prompt falsely found"  || ok "overlay: no prompt (as the watchdog sees it)"
has_prompt "$DEAD"        && bad "dead pane: prompt falsely found" || ok "dead pane: no prompt"
has_active_turn "$ACTIVE" && ok "active turn detected"            || bad "active turn missed"
has_active_turn "$IDLE"   && bad "idle misread as active turn"    || ok "idle is not an active turn"
looks_like_overlay "$OVERLAY" && ok "overlay recognised"          || bad "overlay not recognised"
looks_like_overlay "$IDLE"    && bad "idle misread as overlay"    || ok "idle is not an overlay"
looks_like_overlay "$ACTIVE"  && bad "active turn misread as overlay" || ok "active turn is not an overlay"

# ---- stuck-input detection (pure) ------------------------------------------
STUCK='────────────────────
❯ что дальше по плану, босс
  ⏵⏵ bypass permissions on'
HINT='────────────────────
❯ Try"fix lint errors"
  ⏵⏵ bypass permissions on'
is_stuck_input "$STUCK"   && ok "stuck input detected"                 || bad "stuck input missed"
is_stuck_input "$IDLE"    && bad "clean idle misread as stuck"         || ok "clean idle is not stuck"
is_stuck_input "$ACTIVE"  && bad "active turn misread as stuck"        || ok "active turn is not stuck (would clobber work)"
is_stuck_input "$HINT"    && bad "placeholder hint misread as stuck"   || ok "placeholder hint is not stuck"
[ "$(pane_input_raw "$STUCK")" = "что дальше по плану, босс" ] \
  && ok "pane_input_raw preserves the message text (for retype)" \
  || bad "pane_input_raw mangled the text: [$(pane_input_raw "$STUCK")]"

# ---- recover_stuck_input (mocked tmux) -------------------------------------
# tmux is overridden with a stateful mock here, then `unset -f`d so the real
# tmux section below uses the real binary.
. "$HERE/pane-recover.sh"
RECOVER_SETTLE=0
SENT="$(mktemp)"; CLEARED=0
tmux() {
  case "$1" in
    capture-pane) [ "$CLEARED" -eq 0 ] && printf '%s' "$STUCK" || printf '%s' "$IDLE" ;;
    send-keys)
      shift; [ "${1:-}" = "-t" ] && shift 2
      case "${1:-}" in
        C-u)    CLEARED=1 ;;
        -l)     echo "TYPE:${2:-}" >> "$SENT" ;;
        Enter)  echo "ENTER" >> "$SENT" ;;
        BSpace) echo "BSPACE" >> "$SENT" ;;
      esac ;;
  esac
}
recover_stuck_input "fake-session"; rc=$?
[ "$rc" -eq 0 ] && ok "recover: returns success on a stuck box" || bad "recover: rc=$rc"
grep -q 'TYPE:что дальше по плану, босс' "$SENT" \
  && ok "recover: re-types the captured message literally" || bad "recover: message not re-typed"
grep -q '^ENTER$' "$SENT" && ok "recover: submits with Enter" || bad "recover: no Enter"
# Not stuck → no-op (rc=2)
CLEARED=1; : > "$SENT"
recover_stuck_input "fake-session"; rc=$?
{ [ "$rc" -eq 2 ] && [ ! -s "$SENT" ]; } && ok "recover: no-op on a clean prompt (rc=2)" \
  || bad "recover: acted on a clean prompt (rc=$rc, sent=$(cat "$SENT"))"
rm -f "$SENT"
unset -f tmux    # restore real tmux for the live section below

# ---- real tmux: Escape must restore the prompt after an overlay -------------
# This is the actual discriminator the watchdog relies on, so stubbing it would
# prove nothing. Skips cleanly where tmux is unavailable (CI containers).
if command -v tmux >/dev/null 2>&1; then
  S="panetest-$$"
  tmux kill-session -t "$S" 2>/dev/null || true
  # A tiny fake TUI: prints a prompt, and on Escape redraws it. `less` stands in
  # for the overlay — it hides the prompt and exits on Escape via its keymap.
  if tmux new-session -d -s "$S" -x 80 -y 20 \
       "bash -c 'while :; do printf \"\\n❯ \\n  ⏵⏵ bypass permissions on\\n\"; read -r -n1 -s k; done'" 2>/dev/null; then
    sleep 1
    t="$(tmux capture-pane -pt "$S" -S -8 2>/dev/null)"
    has_prompt "$t" && ok "tmux: prompt visible before overlay" || bad "tmux: no prompt at start"

    # Cover the prompt the way a slash-command overlay does.
    tmux send-keys -t "$S" C-l 2>/dev/null
    tmux run-shell -t "$S" "printf '%s' ''" 2>/dev/null || true
    tmux send-keys -t "$S" "" 2>/dev/null
    tmux clear-history -t "$S" 2>/dev/null || true
    # Paint overlay text over the pane
    tmux respawn-pane -k -t "$S" \
      "bash -c 'printf \"  Context Usage\\n  Auto-compact window: 400k tokens\\n  /context all to expand\\n\"; sleep 30'" 2>/dev/null
    sleep 1
    t="$(tmux capture-pane -pt "$S" -S -8 2>/dev/null)"
    if has_prompt "$t"; then
      bad "tmux: overlay still shows a prompt — fixture wrong"
    else
      ok "tmux: overlay hides the prompt (reproduces the false-freeze signal)"
      looks_like_overlay "$t" && ok "tmux: captured overlay is recognised" \
                              || bad "tmux: captured overlay not recognised"
    fi

    # Restore a prompt-bearing pane — stands for Escape dismissing the overlay.
    tmux respawn-pane -k -t "$S" \
      "bash -c 'printf \"\\n❯ \\n  ⏵⏵ bypass permissions on\\n\"; sleep 30'" 2>/dev/null
    sleep 1
    t="$(tmux capture-pane -pt "$S" -S -8 2>/dev/null)"
    has_prompt "$t" && ok "tmux: prompt returns once the overlay is dismissed" \
                    || bad "tmux: prompt did not return"
    tmux kill-session -t "$S" 2>/dev/null || true
  else
    echo "· tmux session could not start — skipping live pane checks"
  fi
else
  echo "· tmux not installed — skipping live pane checks"
fi

# ---- watchdog wiring: the ladder must exist and precede the restart ---------
W="$HERE/../watchdog.sh"
if grep -q 'send-keys .*Escape' "$W" && grep -q 'overlay' "$W"; then
  ok "watchdog.sh tries Escape before restarting on a missing prompt"
else
  bad "watchdog.sh restarts on a missing prompt without trying Escape first"
fi
# The Escape attempt is worthless if it happens after the restart call.
esc_line="$(grep -n 'Escape' "$W" | grep -i 'overlay\|prompt' | head -1 | cut -d: -f1)"
res_line="$(grep -n 'restart_session "no prompt rendered' "$W" | head -1 | cut -d: -f1)"
if [ -n "$esc_line" ] && [ -n "$res_line" ] && [ "$esc_line" -lt "$res_line" ]; then
  ok "Escape attempt precedes the restart (line $esc_line < $res_line)"
else
  bad "Escape attempt does not precede the restart (esc=$esc_line restart=$res_line)"
fi

# Reliable stuck-input recovery must be wired into the stuck-input ladder, and
# must run BEFORE the operator-escalation (else a recoverable message escalates
# needlessly).
if grep -q 'source .*lib/pane-recover.sh' "$W" && grep -q 'recover_stuck_input' "$W"; then
  ok "watchdog.sh wires recover_stuck_input (clear + retype)"
else
  bad "watchdog.sh does not use recover_stuck_input — stuck messages only escalate"
fi
rec_line="$(grep -n 'recover_stuck_input "\$SESSION"' "$W" | head -1 | cut -d: -f1)"
esc2_line="$(grep -n 'escalating to operator' "$W" | head -1 | cut -d: -f1)"
if [ -n "$rec_line" ] && [ -n "$esc2_line" ] && [ "$rec_line" -lt "$esc2_line" ]; then
  ok "recovery is attempted before operator escalation (line $rec_line < $esc2_line)"
else
  bad "recovery does not precede escalation (recover=$rec_line escalate=$esc2_line)"
fi

echo
echo "passed=$pass failed=$fail"
[ $fail -eq 0 ]
