#!/bin/bash
# Night Learnings Cycle — 02:00 ночной запуск
# Триггирует агентов на review learnings и обновление rules.md
# Запускается через cron/systemd timer

set -euo pipefail

source "$(dirname "$0")/lib/agents.sh"

# Конфигурация
SECOND_BRAIN_AGENT_ROUTER_URL="http://localhost:5000/mcp"
mapfile -t AGENTS < <(list_agents)
LOG_DIR="/home/agent/.claude-lab/logs/night-cycle"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
LOG_FILE="$LOG_DIR/learnings-$(date +%Y%m%d-%H%M%S).log"

mkdir -p "$LOG_DIR"

{
  echo "=== Night Learnings Cycle Started at $TIMESTAMP ==="
  echo ""

  # Для каждого агента отправляем задачу на review learnings
  for agent in "${AGENTS[@]}"; do
    echo "[$agent] Triggering learnings review..."

    # Получи bearer token для agenta
    TOKEN_FILE="$HOME/.claude-lab/$agent/.claude/.mcp.json"
    if [ ! -f "$TOKEN_FILE" ]; then
      echo "  ⚠️ No MCP config for $agent, skipping"
      continue
    fi

    # Извлеки token (простой парсинг JSON)
    BEARER_TOKEN=$(grep -A2 "second_brain-agent_router" "$TOKEN_FILE" | grep "Authorization" | grep -oP '(?<=Bearer )[^"]+' | head -1)

    if [ -z "$BEARER_TOKEN" ]; then
      echo "  ⚠️ No bearer token for $agent, skipping"
      continue
    fi

    # Payload для agent_router.notify
    PAYLOAD=$(cat <<EOF
{
  "method": "agent_router.notify",
  "params": {
    "arguments": {
      "to_agent": "$agent",
      "payload": {
        "title": "Night Learnings Review",
        "body": "Проверь накопленные learnings за последние 7 дней. Для каждого оцени: нужно ли добавить или обновить правило в rules.md. Если да — обнови. Затем отправь мне отчёт о внесённых изменениях.",
        "instruction_type": "batch_learnings_review",
        "priority": "normal",
        "task_type": "rules_update"
      }
    }
  }
}
EOF
)

    # Отправляй agent_router.notify через MCP
    echo "  → Sending notification to $agent..."
    RESPONSE=$(curl -s -X POST "$SECOND_BRAIN_AGENT_ROUTER_URL" \
      -H "Authorization: Bearer $BEARER_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$PAYLOAD" 2>&1 || echo "ERROR")

    if echo "$RESPONSE" | grep -q "ERROR\|error\|null"; then
      echo "  ⚠️ Error sending to $agent: $RESPONSE"
    else
      echo "  ✓ Notification queued for $agent"
    fi

    echo ""
  done

  echo "=== Night Learnings Cycle Completed ==="
  echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"

} | tee -a "$LOG_FILE"

exit 0
