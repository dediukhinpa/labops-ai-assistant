#!/usr/bin/env bash
# Heartbeat every agent that currently has a LIVE tmux session, so the task-board
# supervisor can tell live agents from dead ones. Agents whose session is gone are
# intentionally skipped -> their last_seen goes stale -> supervisor reclaims their
# in-progress tasks. Driven by cron (every minute). Fail-safe and quiet.
set -uo pipefail

source "$(dirname "$0")/lib/agents.sh"

mapfile -t AGENTS < <(list_agents)
PY=/opt/second_brain/.venv/bin/python
SCRIPT=/home/agent/.claude-lab/second_brain-heartbeat.py

live=()
for a in "${AGENTS[@]}"; do
  if tmux has-session -t "labops-$a" 2>/dev/null; then
    live+=("$a")
  fi
done

[ ${#live[@]} -eq 0 ] && exit 0
timeout 30 "$PY" "$SCRIPT" "${live[@]}" 2>>/home/agent/.claude-lab/logs/heartbeat.log || true
