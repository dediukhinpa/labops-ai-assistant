#!/usr/bin/env bash
# session-exec.sh — команда панели tmux: собрать окружение и стать claude.
#
# ЗАЧЕМ. Раньше tmux запускал claude напрямую, а окружение приезжало флагами
# `tmux new-session -e VAR=value` — то есть секреты лежали в КОМАНДНОЙ СТРОКЕ и
# были видны в обычном `ps` любому пользователю машины. Причём не мельком:
# tmux-сервер живёт с cmdline поднявшей его команды, так что токены висели там
# до перезапуска всего роя (замер 08.09.2026 — в cmdline сервера открытым
# текстом AGENT_BEARER, TELEGRAM_BOT_TOKEN, TELEGRAM_WEBHOOK_TOKEN, GROQ_API_KEY
# при выключенном hidepid).
#
# Теперь в командной строке остаётся только имя агента, а окружение собирается
# уже внутри панели — из тех же файлов (channel.env, agent.env, secrets/),
# которые и так лежат под 0600.
#
# Usage: session-exec.sh <agent>   (запускается tmux, не человеком)
set -euo pipefail

AGENT="${1:?agent required}"
HERE="$(cd "$(dirname "$(realpath "$0")")" && pwd)"

# shellcheck source=lib/agent-env.sh
. "$HERE/lib/agent-env.sh"
# shellcheck source=lib/deep-sleep-continue.sh
. "$HERE/lib/deep-sleep-continue.sh"

resolve_agent_env "$AGENT"

CLAUDE_BIN="$(command -v claude 2>/dev/null || echo claude)"

# Продолжить прежнюю сессию, если этот старт — пробуждение из глубокого сна
# (labops-web-app: PR 7 плана тарифов), а не обычный краш-рестарт: см.
# lib/deep-sleep-continue.sh. RESUME_FLAG пуст на обычном старте — тогда
# массив ниже просто не добавляет claude лишний аргумент.
RESUME_FLAG="$(deep_sleep_continue_flag || true)"
RESUME_ARGS=()
[ -n "$RESUME_FLAG" ] && RESUME_ARGS=("$RESUME_FLAG")

# --settings обязателен, а не декоративен: CWD — каталог плагина, поэтому
# .mcp.json находится, но claude канонизирует симлинк плагина в его настоящее
# место (/home/.../labops-tg-plugin/plugin) ВНЕ дерева workspace. Поиск конфига
# идёт вверх уже оттуда и до $AGENT_WORKSPACE/settings.json не доходит — то есть
# НИ ОДИН хук workspace (heartbeat, SessionStart recall, Stop) не срабатывает.
# Явная загрузка settings.json это чинит.
#
# exec, а не запуск дочерним: панель должна БЫТЬ процессом claude. Иначе
# pane_pid указывал бы на эту обёртку, и всё, что смотрит на процесс панели —
# детектор дрейфа версии (lib/cli-version.sh) и снятие агента (stop-agent.sh) —
# видело бы bash вместо claude.
exec "$CLAUDE_BIN" \
  --settings "$AGENT_WORKSPACE/settings.json" \
  --dangerously-skip-permissions \
  --dangerously-load-development-channels server:labops-channel \
  "${RESUME_ARGS[@]}"
