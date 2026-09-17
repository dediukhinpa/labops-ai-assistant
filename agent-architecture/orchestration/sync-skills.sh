#!/usr/bin/env bash
# Обновляет общие скиллы агентов из репозитория и переводит skills/ каждого
# агента на общую копию. Запускать после git pull — скиллы в агентах сами
# не обновляются: это копия, а не ссылка в репозиторий (см. lib/skills.sh).
#
# Использование: bash orchestration/sync-skills.sh
# Env: CLAUDE_LAB — лаборатория агентов (по умолчанию ~/.claude-lab).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$HERE/.." && pwd)"
LAB_DIR="${CLAUDE_LAB:-$HOME/.claude-lab}"
# shellcheck source=lib/skills.sh
. "$HERE/lib/skills.sh"

[ -d "$LAB_DIR" ] || { echo "нет лаборатории агентов: $LAB_DIR" >&2; exit 1; }

echo "Синхронизация скиллов: $REPO_DIR/skills → $(shared_skills_dir "$LAB_DIR")"
sync_shared_skills "$REPO_DIR/skills" "$LAB_DIR"

own=0
for ws in "$LAB_DIR"/*/.claude; do
  [ -d "$ws" ] || continue
  case "$ws" in "$LAB_DIR/shared/"*) continue ;; esac
  link_workspace_skills "$ws" "$LAB_DIR" || own=1
done
[ "$own" -eq 0 ] || echo "У части агентов skills/ — собственный каталог: он не менялся."
echo "Готово. Новые скиллы агент увидит в следующей сессии."
