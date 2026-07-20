#!/usr/bin/env bash
# task-poller.test.sh — unit test for task-poller.sh (no root, no network, no tmux).
# curl and tmux are overridden with shell functions; python3 parsing is real.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { echo "✓ $*"; pass=$((pass+1)); }
bad() { echo "✗ $*"; fail=$((fail+1)); }

# ---- workspace so the sourced script writes into TMP -------------------------
export AGENT_WORKSPACE="$TMP/lab/carmella/.claude"
export AGENT_ID="carmella"
export AGENT_BEARER="faketoken"   # poll_once needs a bearer; curl is stubbed anyway
mkdir -p "$AGENT_WORKSPACE/core/active" "$AGENT_WORKSPACE/logs"
export TASK_POLLER_LIB=1
# shellcheck source=./task-poller.sh
. "$HERE/task-poller.sh"

# ---- fixtures ---------------------------------------------------------------
# recent(decisions) returns the note BODY as `snippet` (NOT frontmatter tags),
# so addressing lives in the body header: TASK-FOR: <agent> / STATUS: <state>.
# Cases: open task for carmella, a plain note, an open task for silvio, and an
# already-done task for carmella. sb_recent_json (the network layer) is stubbed.
ITEMS='[{"path":"decisions/2026-07-20-task-carmella-alpha.md","snippet":"TASK-FOR: carmella\nSTATUS: open\n\nbuild X"},{"path":"decisions/2026-07-20-plain-note.md","snippet":"just a regular decision about something"},{"path":"decisions/2026-07-20-task-silvio-beta.md","snippet":"TASK-FOR: silvio\nSTATUS: open\n\ndo Y"},{"path":"decisions/2026-07-20-task-carmella-done.md","snippet":"TASK-FOR: carmella\nSTATUS: done\n\nbuild X"}]'
sb_recent_json() { printf '%s' "$ITEMS"; }   # stub the network layer

PANE_IDLE=$'some earlier output\n❯\xc2\xa0'
PANE_HINT=$'output\n❯\xc2\xa0Try"fix lint errors"'
PANE_BUSY=$'esc to interrupt\ndoing tool work'

SENT="$TMP/sent.log"; : > "$SENT"
PANE_STATE="idle"          # switched per-case
tmux() {                                     # tmux stub
  case "$1" in
    capture-pane)
      case "$PANE_STATE" in
        idle) printf '%s' "$PANE_IDLE" ;;
        hint) printf '%s' "$PANE_HINT" ;;
        busy) printf '%s' "$PANE_BUSY" ;;
      esac ;;
    has-session) return 0 ;;
    send-keys)
      # record literal payloads (-l) and Enter
      shift
      if [ "${1:-}" = "-t" ]; then shift 2; fi
      if [ "${1:-}" = "-l" ]; then echo "SEND:${2:-}" >> "$SENT"; else echo "KEY:${*}" >> "$SENT"; fi ;;
  esac
}

# ---- case 1: fetch keeps only open tasks addressed to this agent ------------
tasks="$(fetch_open_tasks "faketoken")"
[ "$tasks" = "decisions/2026-07-20-task-carmella-alpha.md" ] \
  && ok "fetch keeps only open task-for-carmella (drops note / silvio / done)" \
  || bad "fetch returned unexpected: [$tasks]"

# ---- case 2: clean idle detection ------------------------------------------
PANE_STATE="idle"; session_clean_idle && ok "clean idle prompt detected" || bad "idle not detected"
PANE_STATE="hint"; session_clean_idle && ok "placeholder hint counts as idle" || bad "hint misread as busy"
PANE_STATE="busy"; session_clean_idle && bad "busy pane misread as idle" || ok "busy/active pane is NOT idle"

# ---- case 3: poll delivers once, records seen ------------------------------
PANE_STATE="idle"; : > "$SENT"
poll_once
grep -q 'SEND:.*task-carmella-alpha.md' "$SENT" \
  && ok "task delivered into session (send-keys -l)" || bad "task not delivered"
grep -q 'KEY:Enter' "$SENT" && ok "delivery submitted (Enter)" || bad "no Enter submit"
grep -Fxq 'decisions/2026-07-20-task-carmella-alpha.md' "$AGENT_WORKSPACE/core/active/.task-seen" \
  && ok "delivered task recorded in seen-file" || bad "seen-file not updated"

# ---- case 4: idempotent — second poll delivers nothing ---------------------
: > "$SENT"; poll_once
[ ! -s "$SENT" ] && ok "second poll is a no-op (dedup via seen-file)" \
  || bad "task re-delivered: $(cat "$SENT")"

# ---- case 5: busy session defers delivery (task stays unseen) --------------
SEEN2="$AGENT_WORKSPACE/core/active/.task-seen"; : > "$SEEN2"   # forget delivery
PANE_STATE="busy"; : > "$SENT"; poll_once
[ ! -s "$SENT" ] && ok "busy session: delivery deferred, nothing typed" \
  || bad "typed into a busy session: $(cat "$SENT")"
[ ! -s "$SEEN2" ] && ok "deferred task left unseen for retry" || bad "deferred task wrongly marked seen"

echo
echo "passed=$pass failed=$fail"
[ $fail -eq 0 ]
