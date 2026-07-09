#!/usr/bin/env bash
# Start message reaction daemons for all agents
# This ensures all incoming messages get 👀 reaction immediately

set -euo pipefail

source "$(dirname "$0")/lib/agents.sh"

DAEMON_SCRIPT="/home/agent/.claude-lab/message-reaction-daemon.sh"
LOGDIR="/home/agent/.claude-lab/logs/reaction-daemons"

mkdir -p "$LOGDIR"

# Make daemon executable
chmod +x "$DAEMON_SCRIPT"

mapfile -t AGENTS < <(list_agents)
for AGENT in "${AGENTS[@]}"; do
  LOGFILE="$LOGDIR/${AGENT}.log"
  PIDFILE="/tmp/reaction-daemon-${AGENT}.pid"

  # Kill existing daemon if running
  if [[ -f "$PIDFILE" ]]; then
    OLD_PID=$(cat "$PIDFILE" 2>/dev/null || echo "")
    if [[ -n "$OLD_PID" ]] && kill -0 "$OLD_PID" 2>/dev/null; then
      kill "$OLD_PID" 2>/dev/null || true
      sleep 1
    fi
  fi

  # Start new daemon in background
  bash "$DAEMON_SCRIPT" "$AGENT" &
  DAEMON_PID=$!
  echo "$DAEMON_PID" > "$PIDFILE"

  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Started reaction daemon for $AGENT (PID: $DAEMON_PID)" | tee -a "$LOGFILE"
done

echo ""
echo "✓ Reaction daemons started for all agents"
echo "  Logs: $LOGDIR"
echo "  Each daemon checks for new messages every 3 seconds"
echo "  All message types (text, voice, photos, stickers) will get 👀 reaction"

# Verify daemons running
sleep 2
echo ""
echo "Active daemons:"
ps aux | grep "message-reaction-daemon" | grep -v grep
