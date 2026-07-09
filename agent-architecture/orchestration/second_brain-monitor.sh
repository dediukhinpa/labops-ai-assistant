#!/usr/bin/env bash
# second_brain-monitor.sh — periodic health monitor for the second_brain backend
# (MCP servers + workers). Meant to be driven by a systemd timer or cron (~60s).
#
# For each component it checks:
#   * `systemctl is-active <unit>`            — process-level liveness
#   * restart delta (`NRestarts`)             — crash-loop detection
#   * an HTTP reachability probe of the port  — catches "process up but wedged"
#     (FastMCP answers a bare GET /mcp with 4xx, which still proves it is
#     listening; connection refused / timeout = down)
#
# On a status TRANSITION (ok→down or down→ok) it alerts the Operator in Telegram
# via lib/notify.sh (recovery included). State is kept between runs so a steady
# outage is reported once, not every cycle. Fail-safe: never raises; missing
# systemctl/curl degrade gracefully; a failed alert never aborts the run.
#
# Config (env):
#   MONITOR_AGENT          which agent's bot relays alerts (token+chat from its
#                          channel.env); defaults to the first list_agents entry.
#   MONITOR_COMPONENTS     space-separated "key|unit|port" specs (port empty for
#                          workers). Default = the 5 units install enables. Add
#                          task-mcp with e.g.:
#                            MONITOR_COMPONENTS="...defaults... task|second_brain-task-mcp|5003"
#   MONITOR_STATE_DIR      where per-component state is kept (default
#                          $CLAUDE_LAB/logs/monitor-state).
#   WATCHDOG_TG_ALERTS / WATCHDOG_ALERT_COOLDOWN / WATCHDOG_ALERT_CHAT_ID — see lib/notify.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(realpath "$0")")" && pwd)"
# shellcheck source=lib/notify.sh
source "$SCRIPT_DIR/lib/notify.sh"
export NOTIFY_TAG="second_brain-monitor"

SYSTEMCTL="${MONITOR_SYSTEMCTL:-systemctl}"
CURL="${MONITOR_CURL:-curl}"

# Which bot relays ops alerts. Resolve a default from the roster only if unset.
MONITOR_AGENT="${MONITOR_AGENT:-}"
if [ -z "$MONITOR_AGENT" ] && [ -f "$SCRIPT_DIR/lib/agents.sh" ]; then
  # shellcheck source=lib/agents.sh
  source "$SCRIPT_DIR/lib/agents.sh" 2>/dev/null || true
  command -v list_agents >/dev/null 2>&1 && MONITOR_AGENT="$(list_agents 2>/dev/null | head -1)"
fi

STATE_DIR="${MONITOR_STATE_DIR:-${CLAUDE_LAB:-$HOME/.claude-lab}/logs/monitor-state}"
mkdir -p "$STATE_DIR" 2>/dev/null || true

# Default monitored set = the units install.sh enables (task-mcp is opt-in).
DEFAULT_COMPONENTS="memory|second_brain-memory-mcp|5001 memory_router|second_brain-memory_router-mcp|5002 agent_router|second_brain-agent_router-mcp|5000 ingest|second_brain-ingest-worker| agent_routerw|second_brain-agent_router-worker|"
read -ra COMPONENTS <<< "${MONITOR_COMPONENTS:-$DEFAULT_COMPONENTS}"

log() { echo "[sb-monitor] $(date -u '+%H:%M:%S') $*"; }

# Probe one component. Echoes a failure reason (empty = healthy). Also emits a
# one-off crash-loop notice when NRestarts climbs between runs.
probe() {
  local unit="$1" port="$2"
  if command -v "$SYSTEMCTL" >/dev/null 2>&1; then
    local active; active="$("$SYSTEMCTL" is-active "$unit" 2>/dev/null || true)"
    if [ "$active" != "active" ]; then
      echo "unit ${active:-unknown}"; return
    fi
    local nr prev; nr="$("$SYSTEMCTL" show -p NRestarts --value "$unit" 2>/dev/null || echo 0)"
    [[ "$nr" =~ ^[0-9]+$ ]] || nr=0
    prev="$(cat "$STATE_DIR/$unit.nrestarts" 2>/dev/null || echo 0)"
    [[ "$prev" =~ ^[0-9]+$ ]] || prev=0
    echo "$nr" > "$STATE_DIR/$unit.nrestarts" 2>/dev/null || true
    if [ "$nr" -gt "$prev" ]; then
      notify_op "${MONITOR_AGENT:-ops}" "♻️ $unit перезапускался (NRestarts ${prev}→${nr})"
    fi
  fi
  if [ -n "$port" ] && command -v "$CURL" >/dev/null 2>&1; then
    if ! "$CURL" -s -o /dev/null --max-time 5 "http://127.0.0.1:$port/mcp"; then
      echo "port $port unreachable"; return
    fi
  fi
  echo ""   # healthy
}

for spec in "${COMPONENTS[@]}"; do
  [ -n "$spec" ] || continue
  IFS='|' read -r key unit port <<< "$spec"
  reason="$(probe "$unit" "$port")"
  sf="$STATE_DIR/$key.status"
  prev="$(cat "$sf" 2>/dev/null || echo ok)"
  if [ -z "$reason" ]; then
    if [ "$prev" != "ok" ]; then
      log "$key recovered"
      notify_op "${MONITOR_AGENT:-ops}" "🟢 $unit восстановился"
    fi
    echo ok > "$sf" 2>/dev/null || true
  else
    log "$key DOWN — $reason"
    if [ "$prev" = "ok" ]; then
      notify_op "${MONITOR_AGENT:-ops}" "🔴 $unit недоступен — $reason"
    fi
    echo down > "$sf" 2>/dev/null || true
  fi
done
exit 0
