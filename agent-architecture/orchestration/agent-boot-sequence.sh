#!/bin/bash
# Agent Boot Sequence — инициализация при старте сессии
# SessionStart hook: проверяем входящие задачи через second_brain Swarm
#
# Это ДЕТЕРМИНИСТИЧНАЯ проверка, не зависит от LLM памяти
# Гарантирует, что агент НЕ пропустит задачу от другого агента

set -euo pipefail

source "$(dirname "$0")/lib/agents.sh"

AGENT_NAME="${1:-unknown}"
CLAUDE_DIR="${2:-.claude}"
SECOND_BRAIN_AGENT_ROUTER_URL="http://localhost:5000/mcp"
LOG_DIR="/home/agent/.claude-lab/logs/boot-sequence"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/${AGENT_NAME}-$(date +%Y%m%d-%H%M%S).log"

{
  # Timestamp omitted from stdout (it lands in the agent's context and would
  # vary the session-start prefix on --resume); it is preserved in $LOG_FILE's name.
  echo "[BOOT] Session start: $AGENT_NAME"

  # Получи bearer token для этого агента
  MCP_CONFIG="$HOME/.claude-lab/$AGENT_NAME/$CLAUDE_DIR/.mcp.json"
  if [ ! -f "$MCP_CONFIG" ]; then
    echo "[BOOT] ⚠️ No MCP config at $MCP_CONFIG"
    exit 1
  fi

  # Извлеки bearer token для second_brain-agent_router
  BEARER_TOKEN=$(grep -A2 "second_brain-agent_router" "$MCP_CONFIG" | grep "Authorization" | grep -oP '(?<=Bearer )[^"]+' | head -1)
  if [ -z "$BEARER_TOKEN" ]; then
    echo "[BOOT] ⚠️ No bearer token in MCP config"
    exit 1
  fi

  echo "[BOOT] Starting boot sequence for $AGENT_NAME..."

  # ============================================================================
  # STEP 0: Set message reactions — mark all unread messages as read
  # ============================================================================
  echo "[BOOT] Step 0: Setting message reactions (read receipts)..."

  # Get bot token from config
  BOT_TOKEN="$(agent_bot_token "$AGENT_NAME" 2>/dev/null || true)"

  if [ -n "$BOT_TOKEN" ]; then
    # Get recent updates and set reactions on unread messages
    UPDATES=$(curl -s --max-time 5 "https://api.telegram.org/bot${BOT_TOKEN}/getUpdates?limit=5" 2>&1)

    # Extract and process each message
    if echo "$UPDATES" | grep -q '"message_id"'; then
      MESSAGE_COUNT=$(echo "$UPDATES" | grep -o '"message_id"' | wc -l)
      echo "[BOOT] Found $MESSAGE_COUNT recent messages, setting reactions..."

      # Set eyes emoji reaction on each message
      echo "$UPDATES" | jq -r '.result[] | select(.message != null) | "\(.message.chat.id)|\(.message.message_id)"' 2>/dev/null | while IFS='|' read -r chat_id msg_id; do
        if [[ -n "$chat_id" && -n "$msg_id" ]]; then
          curl -s --max-time 5 -X POST "https://api.telegram.org/bot${BOT_TOKEN}/setMessageReaction" \
            -H "Content-Type: application/json" \
            -d "{\"chat_id\": $chat_id, \"message_id\": $msg_id, \"reaction\": [{\"type\": \"emoji\", \"emoji\": \"👀\"}]}" > /dev/null 2>&1
        fi
      done
      echo "[BOOT] ✓ Message reactions set"
    fi
  fi

  # ============================================================================
  # STEP 1: list_my_pending — проверь входящие задачи от других агентов
  # ============================================================================
  echo "[BOOT] Step 1: Checking pending tasks (swarm.list_my_pending)..."

  PAYLOAD_1=$(cat <<'EOF'
{
  "method": "swarm.list_my_pending",
  "params": {
    "arguments": {
      "agent": ""
    }
  }
}
EOF
)
  # Подставь имя агента
  PAYLOAD_1=$(echo "$PAYLOAD_1" | sed "s/\"agent\": \"\"/\"agent\": \"$AGENT_NAME\"/")

  RESPONSE_1=$(curl -s --max-time 3 -X POST "$SECOND_BRAIN_AGENT_ROUTER_URL" \
    -H "Authorization: Bearer $BEARER_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD_1" 2>&1 || echo '{"error":"curl_failed"}')

  # Проверь ответ
  if echo "$RESPONSE_1" | grep -q '"error"'; then
    echo "[BOOT] ⚠️ swarm.list_my_pending failed: $RESPONSE_1"
  else
    PENDING_COUNT=$(echo "$RESPONSE_1" | grep -o '"count":[0-9]*' | grep -o '[0-9]*' | head -1 || echo "0")
    echo "[BOOT] ✓ Pending tasks: $PENDING_COUNT"

    # Если есть pending tasks — логируй их
    if [ "$PENDING_COUNT" -gt 0 ]; then
      echo "[BOOT] ⚠️ WARNING: $PENDING_COUNT pending tasks detected!"
      echo "$RESPONSE_1" | grep -o '"task_id":"[^"]*"' | head -5
    fi
  fi

  # ============================================================================
  # STEP 2: task_list — получи актуальный список задач с статусом
  # ============================================================================
  echo "[BOOT] Step 2: Fetching task list (tasks.task_list)..."

  PAYLOAD_2=$(cat <<'EOF'
{
  "method": "tasks.task_list",
  "params": {
    "arguments": {
      "assignee": "",
      "status": "new"
    }
  }
}
EOF
)
  PAYLOAD_2=$(echo "$PAYLOAD_2" | sed "s/\"assignee\": \"\"/\"assignee\": \"$AGENT_NAME\"/")

  RESPONSE_2=$(curl -s --max-time 3 -X POST "$SECOND_BRAIN_AGENT_ROUTER_URL" \
    -H "Authorization: Bearer $BEARER_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD_2" 2>&1 || echo '{"error":"curl_failed"}')

  if echo "$RESPONSE_2" | grep -q '"error"'; then
    echo "[BOOT] ⚠️ tasks.task_list failed: $RESPONSE_2"
  else
    NEW_TASK_COUNT=$(echo "$RESPONSE_2" | grep -o '"count":[0-9]*' | grep -o '[0-9]*' | head -1 || echo "0")
    echo "[BOOT] ✓ New tasks: $NEW_TASK_COUNT"
  fi

  # ============================================================================
  # STEP 3: agent_heartbeat — сообщи что агент онлайн
  # ============================================================================
  echo "[BOOT] Step 3: Sending heartbeat (tasks.agent_heartbeat)..."

  PAYLOAD_3=$(cat <<'EOF'
{
  "method": "tasks.agent_heartbeat",
  "params": {
    "arguments": {
      "agent": "",
      "status": "online"
    }
  }
}
EOF
)
  PAYLOAD_3=$(echo "$PAYLOAD_3" | sed "s/\"agent\": \"\"/\"agent\": \"$AGENT_NAME\"/")

  RESPONSE_3=$(curl -s --max-time 3 -X POST "$SECOND_BRAIN_AGENT_ROUTER_URL" \
    -H "Authorization: Bearer $BEARER_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD_3" 2>&1 || echo '{"error":"curl_failed"}')

  if echo "$RESPONSE_3" | grep -q '"error"'; then
    echo "[BOOT] ⚠️ agent_heartbeat failed (non-critical): $RESPONSE_3"
  else
    echo "[BOOT] ✓ Heartbeat sent"
  fi

  # ============================================================================
  # SUMMARY
  # ============================================================================
  echo ""
  echo "[BOOT] ✓ Boot sequence completed"
  echo "[BOOT] Agent: $AGENT_NAME | Pending: $PENDING_COUNT | New tasks: $NEW_TASK_COUNT"

} | tee -a "$LOG_FILE"

exit 0
