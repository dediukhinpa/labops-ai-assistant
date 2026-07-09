#!/bin/bash
# Broadcast task: second_brain Vault Audit
# Отправляет всем агентам задачу на проверку и заполнение vault

set -euo pipefail

source "$(dirname "$0")/lib/agents.sh"

mapfile -t AGENTS < <(list_agents)
SECOND_BRAIN_AGENT_ROUTER_URL="http://localhost:5000/mcp"

echo "=== Sending second_brain Vault Audit Broadcast ==="
echo ""

for AGENT in "${AGENTS[@]}"; do
  echo "Sending to $AGENT..."

  # Получи bearer token
  MCP_CONFIG="$HOME/.claude-lab/$AGENT/.claude/.mcp.json"
  BEARER_TOKEN=$(grep -A2 "second_brain-agent_router" "$MCP_CONFIG" | grep "Authorization" | grep -oP '(?<=Bearer )[^"]+' | head -1)

  if [ -z "$BEARER_TOKEN" ]; then
    echo "  ⚠️ No bearer token for $AGENT"
    continue
  fi

  # Подготовь payload
  INSTRUCTION=$(cat <<'INSTRUCTION_EOF'
second_brain Vault Audit — проверка и заполнение общей памяти

Цель: Убедиться что все твои важные решения и знания в vault.

Что делать:
1. Запусти: bash /home/agent/.claude-lab/second_brain-vault-audit.sh $AGENT_NAME ./.claude
   → Проверит что пропущено в vault

2. Для каждого пропущенного пункта добавь в second_brain:

   Decision (архитектурное решение):
   second_brain-memory.create_decision_note(
     title="Git workflow strategy",
     body="Используем trunk-based development с feature branches...",
     tags=["git", "workflow", "deployment"]
   )

   Error Pattern (ошибка и как её фиксить):
   second_brain-memory.create_error_pattern_note(
     title="Auth middleware race condition",
     body="Проблема: несколько одновременных запросов...\nРешение: добавить mutex...",
     tags=["auth", "concurrency", "bug"]
   )

   External (полезные ссылки и кейсы):
   second_brain-memory.create_external_note(
     title="Successful content examples",
     body="Reels от конкурентов которые сработали:\n- [link1] - 2M views\n- [link2] - 1.5M views",
     source_url="https://instagram.com/...",
     tags=["marketing", "examples"]
   )

3. После добавления всего отправь подтверждение:
   second_brain-agent_router.notify(
     to_agent="<coordinator>",
     payload={
       "task": "vault_audit_complete",
       "agent": "$AGENT_NAME",
       "items_added": <COUNT>,
       "status": "done"
     }
   )

4. Отправь отчёт оператору в Telegram:
   "✓ second_brain Vault audit completed
   - Items added: 5
   - Categories: decisions(2), error_patterns(1)
   - Total vault entries now: N"

Дедлайн: сегодня, 18:00
Priority: high

Если что-то не ясно — recall из vault существующие примеры.
INSTRUCTION_EOF
)

  # Создай payload для agent_router.notify
  PAYLOAD=$(cat <<EOF
{
  "method": "agent_router.notify",
  "params": {
    "arguments": {
      "to_agent": "$AGENT",
      "payload": {
        "title": "second_brain Vault Audit — fill in missing knowledge",
        "body": "$INSTRUCTION",
        "task_type": "vault_audit",
        "priority": "high",
        "source": "orchestrator",
        "deadline": "2026-05-30 18:00"
      }
    }
  }
}
EOF
)

  # Отправь
  curl -s -X POST "$SECOND_BRAIN_AGENT_ROUTER_URL" \
    -H "Authorization: Bearer $BEARER_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" > /dev/null 2>&1

  echo "  ✓ Task sent to $AGENT"
done

echo ""
echo "✓ Broadcast completed"
