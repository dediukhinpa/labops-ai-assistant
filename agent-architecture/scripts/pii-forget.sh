#!/usr/bin/env bash
set -euo pipefail

# pii-forget.sh — удаление данных субъекта по требованию (152-ФЗ ст. 21).
# Тонкая обёртка над pii_forget.py. По умолчанию --dry-run: ничего не меняется.
#   bash pii-forget.sh --user-id 123 --workspace ~/.claude-lab/tony/.claude          # отчёт
#   bash pii-forget.sh --user-id 123 --workspace ... --apply --backup-dir ~/bk        # удаление
# Все параметры: pii_forget.py --help. Секреты не печатаются, отчёт без ПДн.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY_SCRIPT="$SCRIPT_DIR/pii_forget.py"

if [ ! -f "$PY_SCRIPT" ]; then
  echo "[pii-forget] не найден $PY_SCRIPT" >&2
  exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "[pii-forget] нужен python3" >&2
  exit 2
fi
echo "[pii-forget] запуск (по умолчанию dry-run)" >&2
exec python3 "$PY_SCRIPT" "$@"
