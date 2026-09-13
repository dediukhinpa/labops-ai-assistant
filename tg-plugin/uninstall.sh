#!/usr/bin/env bash
#
# labops-tg-plugin — деинсталлятор.
# Откатывает то, что поставил install.sh для ЭТОГО плагина: node_modules,
# python venv, хуки, конфиг channel.env.
# Системные зависимости (bun, tmux, claude, python3) НЕ трогает — они могли
# стоять до плагина или использоваться другими программами.
#
# Использование:
#   ./uninstall.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$REPO_DIR/plugin"

# Вид вывода — копия agent-architecture/orchestration/lib/ui.sh: плагин ставится
# и отдельно от монорепо, а в общей установке его строки идут вперемешку со
# строками архитектуры и должны выглядеть так же. test.sh сверяет копию.
# ui:begin — от этой метки до ui:end test.sh сверяет с tg-plugin/install.sh.
UI_SECTION='\033[1;36m'; UI_OK='\033[0;32m'; UI_WARN='\033[1;33m'; UI_ERR='\033[1;31m'
UI_INFO='\033[0;36m'; UI_BOLD='\033[1m'; UI_RESET='\033[0m'
say()  { printf "\n${UI_SECTION}▶ %s${UI_RESET}\n" "$*"; }
ok()   { printf "${UI_OK}✓ %s${UI_RESET}\n" "$*"; }
warn() { printf "${UI_WARN}⚠ %s${UI_RESET}\n" "$*"; }
die()  { printf "${UI_ERR}✗ %s${UI_RESET}\n" "$*" >&2; exit 1; }
step() { printf "${UI_INFO}→ %s${UI_RESET}\n" "$*"; }
note() { printf "${UI_INFO}ℹ %s${UI_RESET}\n" "$*"; }
# ui:end

SKIPPED=()
skip() { warn "$*"; SKIPPED+=("$*"); }

# ─── 1. Хуки Claude Code ─────────────────────────────────────────
say "Удаление хуков Claude Code"
if [ -x "$PLUGIN_DIR/scripts/uninstall-hooks.sh" ]; then
  ( cd "$PLUGIN_DIR" && ./scripts/uninstall-hooks.sh ) || skip "uninstall-hooks.sh завершился с ошибкой — хуки могли остаться зарегистрированы"
  ok "хуки удалены"
else
  skip "scripts/uninstall-hooks.sh не найден — автоматическое удаление хуков не поддерживается, снимите вручную (см. docs/06)"
fi

# ─── 2. Зависимости плагина ──────────────────────────────────────
say "Удаление зависимостей плагина"
if [ -d "$PLUGIN_DIR/node_modules" ]; then
  rm -rf "$PLUGIN_DIR/node_modules"
  ok "node_modules удалён"
else
  skip "node_modules не найден — нечего удалять"
fi

if [ -d "$REPO_DIR/.venv" ]; then
  rm -rf "$REPO_DIR/.venv"
  ok "python venv (.venv) удалён"
else
  skip ".venv не найден — нечего удалять"
fi

# ─── 3. Конфиг (channel.env с токеном) ───────────────────────────
say "Удаление конфига"
CHANNEL_ENV_CANDIDATES=()
[ -n "${CHANNEL_ENV:-}" ] && CHANNEL_ENV_CANDIDATES+=("$CHANNEL_ENV")
[ -n "${AGENT_ID:-}" ] && CHANNEL_ENV_CANDIDATES+=("/etc/labops-plugin/$AGENT_ID/channel.env")

FOUND_ENV=""
for c in "${CHANNEL_ENV_CANDIDATES[@]:-}"; do
  [ -n "$c" ] && [ -f "$c" ] && { FOUND_ENV="$c"; break; }
done

if [ -n "$FOUND_ENV" ]; then
  rm -f "$FOUND_ENV" 2>/dev/null || sudo rm -f "$FOUND_ENV"
  ok "channel.env удалён ($FOUND_ENV)"
  ENV_DIR="$(dirname "$FOUND_ENV")"
  if [ -d "$ENV_DIR" ] && [ -z "$(ls -A "$ENV_DIR" 2>/dev/null)" ]; then
    rmdir "$ENV_DIR" 2>/dev/null || sudo rmdir "$ENV_DIR" 2>/dev/null || true
  fi
else
  skip "channel.env не найден (CHANNEL_ENV=/path или AGENT_ID=... для точного поиска) — проверьте /etc/labops-plugin/<agent>/ вручную"
fi

# ─── 4. Финальный статус ─────────────────────────────────────────
if [ "${#SKIPPED[@]}" -gt 0 ]; then
  printf "\n${UI_WARN}⚠ Удаление завершено, но кое-что пропущено:${UI_RESET}\n"
  for s in "${SKIPPED[@]}"; do printf '   • %s\n' "$s"; done
else
  printf "\n${UI_OK}✓ Плагин полностью удалён.${UI_RESET}\n"
fi

cat <<'NEXT'

Системные зависимости НЕ тронуты (могли стоять до плагина или нужны другим
программам). Если хотите удалить и их — вручную:
  • bun:    rm -rf "$HOME/.bun"
  • claude: rm -f "$HOME/.local/bin/claude" && rm -rf "$HOME/.claude"
  • tmux/python3: sudo apt-get remove tmux python3   (или brew uninstall)
NEXT
