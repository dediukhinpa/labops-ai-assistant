#!/bin/bash
# second_brain Vault Audit — проверка и заполнение общей памяти
# Каждый агент запускает это чтобы:
# 1. Проверить что пропущено в Vault
# 2. Добавить важные решения и learnings
# 3. Уведомить что готово

set -euo pipefail

AGENT_NAME="${1:-unknown}"
CLAUDE_DIR="${2:-.claude}"
SECOND_BRAIN_MEMORY_URL="http://localhost:5001/mcp"
LOG_DIR="/home/agent/.claude-lab/logs/vault-audit"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/${AGENT_NAME}-$(date +%Y%m%d-%H%M%S).log"

{
  echo "[VAULT] Audit started: $AGENT_NAME at $TIMESTAMP"

  # Получи bearer token
  MCP_CONFIG="$HOME/.claude-lab/$AGENT_NAME/$CLAUDE_DIR/.mcp.json"
  if [ ! -f "$MCP_CONFIG" ]; then
    echo "[VAULT] ⚠️ No MCP config"
    exit 1
  fi

  BEARER_TOKEN=$(grep -A2 "second_brain-memory" "$MCP_CONFIG" | grep "Authorization" | grep -oP '(?<=Bearer )[^"]+' | head -1)
  if [ -z "$BEARER_TOKEN" ]; then
    echo "[VAULT] ⚠️ No bearer token"
    exit 1
  fi

  echo "[VAULT] Step 1: Checking existing vault content..."

  # ============================================================================
  # Проверить что уже в vault
  # ============================================================================
  PAYLOAD=$(cat <<'EOF'
{
  "method": "memory.search",
  "params": {
    "arguments": {
      "query": "agent_name decision error_pattern external",
      "limit": 50
    }
  }
}
EOF
)

  RESPONSE=$(curl -s -X POST "$SECOND_BRAIN_MEMORY_URL" \
    -H "Authorization: Bearer $BEARER_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" 2>&1 || echo '{"error":"curl_failed"}')

  if echo "$RESPONSE" | grep -q '"error"'; then
    echo "[VAULT] ⚠️ Memory search failed"
    VAULT_COUNT=0
  else
    VAULT_COUNT=$(echo "$RESPONSE" | grep -o '"id":"[^"]*"' | wc -l)
    echo "[VAULT] ✓ Found $VAULT_COUNT existing vault entries"
  fi

  # ============================================================================
  # Проверить что пропущено ДЛЯ ЭТОГО АГЕНТА
  # ============================================================================
  echo "[VAULT] Step 2: Checking what's missing for $AGENT_NAME..."

  # Per-agent audit checklists are project-specific. Define them in an optional
  # file at "$CLAUDE_LAB/vault-audit/$AGENT_NAME.items" (one "category: slug" per
  # line, # comments allowed). Absent file -> nothing to audit for this agent.
  MISSING_ITEMS=()
  ITEMS_FILE="${CLAUDE_LAB:-$HOME/.claude-lab}/vault-audit/$AGENT_NAME.items"
  if [ -f "$ITEMS_FILE" ]; then
    while IFS= read -r line; do
      line="${line%%#*}"
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      [ -n "$line" ] && MISSING_ITEMS+=("$line")
    done < "$ITEMS_FILE"
  fi

  echo "[VAULT] Items to audit: ${#MISSING_ITEMS[@]}"
  for item in "${MISSING_ITEMS[@]}"; do
    echo "  - [ ] $item"
  done

  # ============================================================================
  # Логирование что нужно сделать
  # ============================================================================
  echo ""
  echo "[VAULT] Step 3: Agent action items..."
  echo "[VAULT] ⚠️ Agent must manually add missing items during session"
  echo "[VAULT] Use: second_brain-memory.create_decision_note / _error_pattern_note"
  echo ""
  echo "[VAULT] After adding → send confirmation:"
  echo "[VAULT]   second_brain-agent_router.notify(to_agent='<coordinator>', payload={'task': 'vault_audit_complete', 'agent': '$AGENT_NAME'})"

  # ============================================================================
  # SUMMARY
  # ============================================================================
  echo ""
  echo "[VAULT] ✓ Audit completed at $(date '+%Y-%m-%d %H:%M:%S')"
  echo "[VAULT] Agent: $AGENT_NAME | Vault entries: $VAULT_COUNT | Missing to add: ${#MISSING_ITEMS[@]}"

} | tee -a "$LOG_FILE"

exit 0
