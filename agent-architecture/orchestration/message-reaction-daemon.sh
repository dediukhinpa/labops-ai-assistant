#!/usr/bin/env bash
# Message Reaction Daemon — постоянный мониторинг и реакции на все сообщения
# Запускается как фоновый процесс для каждого агента
# Purpose: Ставить 👀 на ВСЕ входящие сообщения (текст, голос, стикеры и т.д.) немедленно

set -euo pipefail

source "$(dirname "$0")/lib/agents.sh"

AGENT="${1:?Agent name required}"
INTERVAL="${2:-3}"  # Check every 3 seconds

BOT_TOKEN=$(agent_bot_token "$AGENT" 2>/dev/null || true)
if [[ -z "$BOT_TOKEN" ]]; then
  echo "[daemon:$AGENT] ERROR: Unknown agent $AGENT" >&2
  exit 1
fi

# Track already-reacted messages to avoid duplicates
PROCESSED_FILE="/tmp/telegram-reactions-$AGENT.processed"
touch "$PROCESSED_FILE"

# Function to process messages
process_messages() {
  # Get latest updates from Telegram
  local result=$(curl -s "https://api.telegram.org/bot${BOT_TOKEN}/getUpdates?limit=10&timeout=1" 2>&1)

  # Extract and process each message
  echo "$result" | jq -r '.result[] | select(.message != null) | "\(.update_id):\(.message.chat.id):\(.message.message_id)"' 2>/dev/null | while IFS=':' read -r update_id chat_id message_id; do
    if [[ -z "$update_id" || -z "$chat_id" || -z "$message_id" ]]; then
      continue
    fi

    # Check if already processed
    local key="$chat_id:$message_id"
    if grep -q "^$key$" "$PROCESSED_FILE" 2>/dev/null; then
      continue
    fi

    # Set eyes emoji reaction
    curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/setMessageReaction" \
      -H "Content-Type: application/json" \
      -d "{
        \"chat_id\": $chat_id,
        \"message_id\": $message_id,
        \"reaction\": [{\"type\": \"emoji\", \"emoji\": \"👀\"}]
      }" > /dev/null 2>&1

    # Mark as processed
    echo "$key" >> "$PROCESSED_FILE"

    # Keep file size reasonable (last 1000 entries)
    if [[ $(wc -l < "$PROCESSED_FILE") -gt 1000 ]]; then
      tail -500 "$PROCESSED_FILE" > "$PROCESSED_FILE.tmp"
      mv "$PROCESSED_FILE.tmp" "$PROCESSED_FILE"
    fi
  done
}

# Main loop
echo "[daemon:$AGENT] Started message reaction daemon (checking every ${INTERVAL}s)"

while true; do
  process_messages
  sleep "$INTERVAL"
done
