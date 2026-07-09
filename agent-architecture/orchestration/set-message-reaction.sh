#!/usr/bin/env bash
# Set a Telegram message reaction (emoji) to indicate message was read
# Usage: set-message-reaction.sh <agent-name> <chat-id> <message-id> [emoji]
# Default emoji: 👀 (eyes)

set -euo pipefail

source "$(dirname "$0")/lib/agents.sh"

AGENT="${1:?Agent name required (<agent>)}"
CHAT_ID="${2:?Chat ID required}"
MESSAGE_ID="${3:?Message ID required}"
EMOJI="${4:-👀}"

# Get bot token based on agent name
BOT_TOKEN="$(agent_bot_token "$AGENT")" || { echo "Unknown agent: $AGENT" >&2; exit 1; }

# Set message reaction via Telegram Bot API
curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/setMessageReaction" \
  -H "Content-Type: application/json" \
  -d "{
    \"chat_id\": $CHAT_ID,
    \"message_id\": $MESSAGE_ID,
    \"reaction\": [{\"type\": \"emoji\", \"emoji\": \"$EMOJI\"}]
  }" > /dev/null

echo "[$(date '+%H:%M:%S')] ✓ Reaction '$EMOJI' set on message $MESSAGE_ID in chat $CHAT_ID"
