#!/usr/bin/env bash
set -euo pipefail

# task-poller.sh — near-real-time agent-to-agent task delivery over shared memory (L4).
#
# WHY THIS EXISTS:
# Active push (agent_router.notify -> webhook-listener) delivers via `claude -p`,
# which bills separate SDK credits — deliberately avoided (see AGENT_ROUTER.md).
# This poller stays entirely inside the live, subscription-billed TUI session:
#   - the POLL itself is a cheap HTTP recall to memory_router — it does NOT wake
#     the agent, so a 5s cadence costs nothing but a tiny query;
#   - the agent is woken ONCE per genuinely-new task, and only on a clean idle
#     prompt, by typing a single-line instruction into the tmux session (the same
#     primitive the watchdog uses for control keys).
#
# The delivered instruction tells the agent to run the task via a BACKGROUND
# subagent, so a long task does not monopolise the main session.
#
# Idempotent: every delivered task path is recorded in $SEEN and never re-fired,
# even across poller restarts. Fail-open: any error just retries next cycle.
#
# Env:
#   AGENT_WORKSPACE   agent .claude dir (default: parent of this script's dir)
#   AGENT_ID          agent name (default: basename of workspace's parent)
#   TASK_POLL_INTERVAL  seconds between polls (default 5)
#   SECOND_BRAIN_MEMORY_ROUTER_URL  recall endpoint (default http://localhost:5002/mcp)
#   AGENT_BEARER      memory_router bearer (default: parsed from .mcp.json)
#   TASK_POLLER_LIB=1 source the functions only, do not run the loop (for tests)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="${AGENT_WORKSPACE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
AGENT_ID="${AGENT_ID:-$(basename "$(dirname "$WS")")}"
SESSION="labops-${AGENT_ID}"
INTERVAL="${TASK_POLL_INTERVAL:-5}"
ROUTER_URL="${SECOND_BRAIN_MEMORY_ROUTER_URL:-http://localhost:5002/mcp}"
LOGDIR="$WS/logs"; mkdir -p "$LOGDIR"
LOG="$LOGDIR/task-poller.log"
SEEN="$WS/core/active/.task-seen"
mkdir -p "$(dirname "$SEEN")"; touch "$SEEN"

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [task-poller] $1" >> "$LOG"; }

# Bearer for memory_router — prefer env, else parse the agent's own .mcp.json.
poller_bearer() {
  if [ -n "${AGENT_BEARER:-}" ]; then printf '%s' "$AGENT_BEARER"; return; fi
  local mcp="$WS/.mcp.json"
  [ -f "$mcp" ] || return 0
  grep -A3 'memory_router' "$mcp" 2>/dev/null | grep 'Authorization' \
    | grep -oE 'Bearer [^"]+' | head -1 | sed 's/^Bearer //'
}

# sb_recent_json <token> — print the raw items JSON array from recent(decisions).
#
# memory_router is FastMCP streamable-http: it REQUIRES the MCP handshake
# (initialize → mcp-session-id header → tools/call with that header) and answers
# in SSE frames. Doing that in bash+curl is error-prone (a bare tools/call gets
# "Missing session ID"), so the request is a self-contained python client.
# Split out from the filter so tests can stub the network cleanly.
sb_recent_json() {
  local token="$1"
  [ -n "$token" ] || return 0
  SB_URL="$ROUTER_URL" SB_TOKEN="$token" SB_TIMEOUT="$INTERVAL" \
    python3 - <<'PY' 2>/dev/null || true
import json, os, urllib.request
url = os.environ["SB_URL"]; token = os.environ["SB_TOKEN"]
timeout = float(os.environ.get("SB_TIMEOUT", "5"))

def post(payload, sid=None):
    data = json.dumps(payload).encode()
    req = urllib.request.Request(url, data=data, method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("Accept", "application/json, text/event-stream")
    req.add_header("Authorization", f"Bearer {token}")
    if sid:
        req.add_header("mcp-session-id", sid)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        raw = r.read().decode()
        got = r.headers.get("mcp-session-id")
    if "data:" in raw:  # SSE frame → take the last data: line
        for line in raw.splitlines():
            if line.startswith("data:"):
                raw = line[5:].strip()
    try:
        return json.loads(raw), got
    except Exception:
        return {}, got

try:
    _, sid = post({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                   "params": {"protocolVersion": "2024-11-05", "capabilities": {},
                              "clientInfo": {"name": "task-poller", "version": "0"}}})
    if sid:
        post({"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}}, sid)
    resp, _ = post({"jsonrpc": "2.0", "id": 2, "method": "tools/call",
                    "params": {"name": "recent",
                               "arguments": {"scope": "decisions", "limit": 30}}}, sid)
    print(resp["result"]["content"][0]["text"])
except Exception:
    raise SystemExit(0)
PY
}

# Fetch open task paths addressed to this agent. Prints one rel-path per line.
#
# recent() returns each note's BODY as `snippet` but NOT its frontmatter tags,
# so addressing must live in the body (see AGENT_ROUTER.md): a task note
# starts with machine-readable header lines
#     TASK-FOR: <agent>
#     STATUS: open
# We match those in the snippet. Tags stay for humans / recall; the poller does
# not depend on them (they are invisible to recent()).
fetch_open_tasks() {
  local token="$1"
  [ -n "$token" ] || return 0
  # NB: use `python3 -c` (not `python3 - <<HEREDOC`) — a heredoc would claim
  # stdin and the piped items would never reach the filter.
  sb_recent_json "$token" | SB_AGENT="$AGENT_ID" python3 -c '
import json, os, re, sys
me = re.escape(os.environ["SB_AGENT"].lower())
try:
    items = json.loads(sys.stdin.read() or "[]")
except Exception:
    raise SystemExit(0)
for it in items:
    blob = str(it.get("snippet", "")).lower()
    if re.search(r"task-for:\s*" + me + r"\b", blob) and re.search(r"status:\s*open\b", blob):
        p = it.get("path")
        if p:
            print(p)
' 2>/dev/null || true
}

# Is the session sitting on a CLEAN idle prompt? Replicates the watchdog's check
# so we never type into an active turn or a stuck input box.
session_clean_idle() {
  local tail input
  tail="$(tmux capture-pane -pt "$SESSION" -S -8 2>/dev/null || true)"
  [ -n "$tail" ] || return 1
  printf '%s' "$tail" | grep -qa '❯' || return 1          # no prompt → not idle
  input="$(printf '%s' "$tail" | grep -a '❯' | tail -1 \
            | sed -e 's/.*❯//' -e 's/\xc2\xa0//g' -e 's/[[:space:]]//g')"
  # Empty, or the rotating placeholder hint Try"..." → clean idle.
  [ -z "$input" ] || printf '%s' "$input" | grep -qE '^Try".*"$'
}

# Type a one-line task-delivery instruction into the session and submit it.
deliver_task() {
  local path="$1"
  local msg="📥 Новая межагентная задача: ${path}. Забери её (memory_router.get), выполни ФОНОВЫМ субагентом, по завершении supersede_decision → STATUS: done, затем продолжай текущую работу. См. AGENT_ROUTER.md."
  tmux send-keys -t "$SESSION" -l "$msg" 2>/dev/null || return 1
  tmux send-keys -t "$SESSION" Enter 2>/dev/null || return 1
  return 0
}

# One poll pass. Returns 0 always (fail-open).
poll_once() {
  local token paths p
  token="$(poller_bearer || true)"
  [ -n "$token" ] || { log "no bearer — skip"; return 0; }
  paths="$(fetch_open_tasks "$token" || true)"
  [ -n "$paths" ] || return 0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    grep -Fxq "$p" "$SEEN" && continue                    # already delivered
    if ! session_clean_idle; then
      # Busy/active turn — leave unseen, retry when the agent frees up.
      continue
    fi
    if deliver_task "$p"; then
      echo "$p" >> "$SEEN"
      log "delivered task $p → session (background subagent)"
    else
      log "deliver failed for $p (tmux) — will retry"
    fi
  done <<< "$paths"
  return 0
}

# Test hook: source functions without running the loop.
[ "${TASK_POLLER_LIB:-0}" = "1" ] && return 0

log "started (agent=$AGENT_ID session=$SESSION interval=${INTERVAL}s)"

# Долгоживущий цикл ОБЯЗАН пережить транзиентные сбои. Снимаем -e на теле цикла:
# под `set -e` прерванный сигналом `sleep` (в момент рестарта юнита) или мелькнув-
# ший tmux роняли поллер БЕЗ записи в лог — ровно это наблюдалось в гонке рестарта.
# Выходим ТОЛЬКО когда сессия реально исчезла, и подтверждаем это несколькими
# промахами подряд, чтобы кратковременный флап tmux-сервера при рестарте не заставил
# поллер выйти раньше времени (за ним всё равно следит watchdog/ensure_task_poller).
set +e
GONE_LIMIT="${TASK_POLLER_GONE_LIMIT:-3}"
gone=0
while true; do
  if tmux has-session -t "$SESSION" 2>/dev/null; then
    gone=0
    poll_once || true
  else
    gone=$((gone + 1))
    if [ "$gone" -ge "$GONE_LIMIT" ]; then
      log "session gone (${gone}× подряд) — exiting"
      exit 0
    fi
    log "session check failed (${gone}/${GONE_LIMIT}) — возможно рестарт, не выхожу"
  fi
  sleep "$INTERVAL" || true
done
