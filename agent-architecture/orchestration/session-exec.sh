#!/usr/bin/env bash
# session-exec.sh — команда панели tmux: собрать окружение и стать claude.
#
# ЗАЧЕМ. Раньше tmux запускал claude напрямую, а окружение приезжало флагами
# `tmux new-session -e VAR=value` — то есть секреты лежали в КОМАНДНОЙ СТРОКЕ и
# были видны в обычном `ps` любому пользователю машины. Причём не мельком:
# tmux-сервер живёт с cmdline поднявшей его команды, так что токены висели там
# до перезапуска всего роя (замер 08.09.2026 — в cmdline сервера открытым
# текстом AGENT_BEARER, TELEGRAM_BOT_TOKEN, TELEGRAM_WEBHOOK_TOKEN и ключ сервиса голоса
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

# Режим относительно pii-proxy выбрал start-agent.sh (lib/pii.sh: pii_mode_resolve_start).
# shellcheck source=lib/pii.sh
. "$HERE/lib/pii.sh"
PII_MODE="$(pii_mode_get "$AGENT")"

# Рой на Codex: панель становится драйвером (плагин в режиме LABOPS_HARNESS=codex), а он уже
# сам держит codex app-server. TUI нет, поэтому флаги claude ниже не нужны. cwd панели —
# каталог плагина (его задаёт start-agent.sh), отсюда и ./src/server.ts.
. "$HERE/lib/harness.sh"
. "$HERE/lib/codex-watch.sh"
if [ "$(harness_current)" = "codex" ]; then
  export LABOPS_HARNESS=codex
  CODEX_HOME="$(codex_home_of "$AGENT")"
  export CODEX_HOME
  CODEX_BIN="$(codex_bin || echo codex)"
  export CODEX_BIN
  # Файл режима драйвер читает сам — на старте и затем каждые несколько секунд: при смене режима
  # он перезапускает app-server и продолжает ту же нить (thread/resume); напрямую — прервав
  # идущий ход и повторив его вход, обратно через прокси — между ходами.
  LABOPS_PII_MODE_FILE="$(pii_mode_file "$AGENT")"
  export LABOPS_PII_MODE_FILE
  exec bun ./src/server.ts
fi

CLAUDE_BIN="$(command -v claude 2>/dev/null || echo claude)"

# Продолжить прежнюю сессию, если этот старт — пробуждение из глубокого сна
# (labops-web-app: PR 7 плана тарифов), а не обычный краш-рестарт: см.
# lib/deep-sleep-continue.sh. RESUME_FLAG пуст на обычном старте — тогда
# массив ниже просто не добавляет claude лишний аргумент.
RESUME_FLAG="$(deep_sleep_continue_flag || true)"
# Перезапуск ради смены режима pii-proxy (watchdog, в простое) — тоже продолжение разговора, а
# не новая сессия. Метку забираем всегда, даже если --continue уже дал глубокий сон: иначе она
# пролежала бы до следующего обычного краш-рестарта и продолжила бы не ту сессию.
PII_CONTINUE_FLAG="$(deep_sleep_continue_flag "$(pii_switch_continue_file "$AGENT")" || true)"
RESUME_FLAG="${RESUME_FLAG:-$PII_CONTINUE_FLAG}"
RESUME_ARGS=()
[ -n "$RESUME_FLAG" ] && RESUME_ARGS=("$RESUME_FLAG")

# Напрямую (pii-proxy не ответил на старте): та же настройка без ANTHROPIC_BASE_URL, иначе
# claude ходил бы в мёртвый прокси. Копию пересобираем на каждом старте из settings.json, чтобы
# хуки и модель не расходились с оригиналом; адрес из окружения тоже убираем. Через прокси
# (норма) запуск прежний, побайтно.
SETTINGS_FILE="$AGENT_WORKSPACE/settings.json"
if [ "$PII_MODE" = "$PII_MODE_DIRECT" ]; then
  DIRECT_SETTINGS="$AGENT_WORKSPACE/state/settings.pii-direct.json"
  mkdir -p "$(dirname "$DIRECT_SETTINGS")"
  if python3 - "$SETTINGS_FILE" "$DIRECT_SETTINGS" <<'PY'
import json, os, sys
src, dst = sys.argv[1], sys.argv[2]
with open(src, encoding="utf-8") as fh:
    data = json.load(fh)
env = data.get("env")
if isinstance(env, dict):
    env.pop("ANTHROPIC_BASE_URL", None)
tmp = f"{dst}.tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2, ensure_ascii=False)
os.chmod(tmp, 0o600)
os.replace(tmp, dst)
PY
  then
    SETTINGS_FILE="$DIRECT_SETTINGS"
  fi
  unset ANTHROPIC_BASE_URL
fi

# --settings обязателен, а не декоративен: CWD — каталог плагина, поэтому
# .mcp.json находится, но claude канонизирует симлинк плагина в его настоящее
# место (/home/.../labops-tg-plugin/plugin) ВНЕ дерева workspace. Поиск конфига
# идёт вверх уже оттуда и до $AGENT_WORKSPACE/settings.json не доходит — то есть
# НИ ОДИН хук workspace (heartbeat, SessionStart recall, Stop) не срабатывает.
# Явная загрузка settings.json это чинит.
#
# --mcp-config — по той же причине, что и --settings, только про инструменты.
# .mcp.json, который claude находит сам, лежит в CWD панели (каталог плагина) и
# регистрирует ровно один сервер — labops-channel. Файл воркспейса
# $AGENT_WORKSPACE/.mcp.json с second_brain-memory, -memory_router,
# -agent_router и -tasks не находился никогда: поиск идёт вверх от
# канонизированного пути плагина, мимо дерева воркспейса. Без --mcp-config в
# сессии просто нет инструментов общей памяти, и агент физически не может
# выполнить SECONDBRAIN_WRITE_RULES.md («recall ПЕРЕД записью») и работать с
# доской задач. Флаг ДОПОЛНЯЕТ найденное (заменял бы --strict-mcp-config),
# поэтому канал остаётся на месте.
#
# Обнаружено у клиента 22.09.2026: у всех трёх агентов ни одного вызова
# mcp__second_brain-* за двое суток. Маскировалось тем, что фоновые хуки
# (heartbeat, recall на старте, flush при остановке) ходят в мозг напрямую
# через curl (lib/mcp-call.sh), в обход сессии, и работали штатно.
#
# Файла может не быть (агент без мозга — штатный порядок первой установки):
# тогда флаг не добавляем, иначе claude не стартует вовсе и агент молчит.
MCP_ARGS=()
if [ -f "$AGENT_WORKSPACE/.mcp.json" ]; then
  MCP_ARGS=(--mcp-config "$AGENT_WORKSPACE/.mcp.json")
fi

# exec, а не запуск дочерним: панель должна БЫТЬ процессом claude. Иначе
# pane_pid указывал бы на эту обёртку, и всё, что смотрит на процесс панели —
# детектор дрейфа версии (lib/cli-version.sh) и снятие агента (stop-agent.sh) —
# видело бы bash вместо claude.
exec "$CLAUDE_BIN" \
  --settings "$SETTINGS_FILE" \
  ${MCP_ARGS[@]+"${MCP_ARGS[@]}"} \
  --dangerously-skip-permissions \
  --dangerously-load-development-channels server:labops-channel \
  "${RESUME_ARGS[@]}"
