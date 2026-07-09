#!/usr/bin/env bash
# Handle incoming Telegram messages: set read receipt reaction (eyes emoji)
# Called by: SessionStart hook for each agent
# Purpose: Mark messages as read immediately upon arrival

set -euo pipefail

source "$(dirname "$0")/lib/agents.sh"

AGENT="${1:?Agent name required}"
CHANNEL_DIR="/home/agent/.claude/channels/labops-$AGENT"

if [[ ! -d "$CHANNEL_DIR" ]]; then
  exit 0 # Channel not initialized yet
fi

# Function to extract chat_id and message_id from context
# Format expected: message files in inbox contain metadata
mark_unread_messages() {
  local bot_token="$1"
  local agent="$2"

  # Get the latest processed offset
  local offset_file="$CHANNEL_DIR/update-offset"
  local current_offset=""

  if [[ -f "$offset_file" ]]; then
    current_offset=$(cat "$offset_file" 2>/dev/null || echo "0")
  fi

  # Fetch recent updates from Telegram to find unread messages
  # This gets updates that arrived since last check
  local result=$(curl -s "https://api.telegram.org/bot${bot_token}/getUpdates?offset=$((current_offset + 1))&limit=10&timeout=1")

  # Extract message info and set reactions
  echo "$result" | jq -r '.result[] | select(.message != null) | "\(.update_id):\(.message.chat.id):\(.message.message_id)"' | while IFS=':' read -r update_id chat_id message_id; do
    if [[ -n "$message_id" && -n "$chat_id" ]]; then
      # Set eyes emoji reaction
      curl -s -X POST "https://api.telegram.org/bot${bot_token}/setMessageReaction" \
        -H "Content-Type: application/json" \
        -d "{
          \"chat_id\": $chat_id,
          \"message_id\": $message_id,
          \"reaction\": [{\"type\": \"emoji\", \"emoji\": \"👀\"}]
        }" > /dev/null 2>&1

      # Export for agent to use in CLAUDE.md instructions
      export TELEGRAM_CHAT_ID="$chat_id"
      export TELEGRAM_MESSAGE_ID="$message_id"
    fi
  done
}

BOT_TOKEN=$(agent_bot_token "$AGENT")
mark_unread_messages "$BOT_TOKEN" "$AGENT"

# Log completion
echo "[$(date '+%H:%M:%S')] ✓ Incoming message handler ready for $AGENT" >> "$CHANNEL_DIR/logs/messages.log" 2>/dev/null || true
