#!/bin/bash
# PostToolUse Hook: автозаписи важных правил в rules.md
# Запускается после каждого Edit/Write/MultiEdit
# Проверяет learnings и дописывает актуальные правила

set -euo pipefail

AGENT_NAME="${1:-unknown}"
CLAUDE_DIR="${2:-.claude}"
RULES_FILE="$CLAUDE_DIR/core/rules.md"
LEARNINGS_FILE="$CLAUDE_DIR/core/LEARNINGS.md"
DECISIONS_FILE="$CLAUDE_DIR/core/warm/decisions.md"

# Если files нет — пропусти
[ ! -f "$LEARNINGS_FILE" ] && exit 0

# Читай последние 5 записей из LEARNINGS
LAST_LEARNINGS=$(tail -20 "$LEARNINGS_FILE" 2>/dev/null | grep -E "^\*\*" || true)

if [ -z "$LAST_LEARNINGS" ]; then
  exit 0
fi

# Ищи строки с CRITICAL, HARD RULE, must, ALWAYS
CRITICAL_PATTERNS=$(echo "$LAST_LEARNINGS" | grep -iE "(CRITICAL|HARD RULE|MUST NOT|ALWAYS|never)" || true)

if [ -z "$CRITICAL_PATTERNS" ]; then
  exit 0
fi

# Проверь, не добавлены ли уже в rules.md
RULES_CONTENT=$(cat "$RULES_FILE" 2>/dev/null || echo "")

while IFS= read -r line; do
  [ -z "$line" ] && continue

  # Очисти от маркеров
  CLEAN_LINE=$(echo "$line" | sed 's/^\*\*\|^\*\*$//g' | xargs)

  # Если строка коротче 10 символов — пропусти
  [ ${#CLEAN_LINE} -lt 10 ] && continue

  # Если уже в rules.md — пропусти
  if echo "$RULES_CONTENT" | grep -qF "$CLEAN_LINE"; then
    continue
  fi

  # Дописали в rules.md с датой
  echo "" >> "$RULES_FILE"
  echo "**[$AGENT_NAME] $(date '+%Y-%m-%d %H:%M')**" >> "$RULES_FILE"
  echo "$CLEAN_LINE" >> "$RULES_FILE"

done <<< "$CRITICAL_PATTERNS"

exit 0
