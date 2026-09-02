#!/usr/bin/env bash
set -uo pipefail

# task-poller.sh — надзор над долгоживущим поллером задач (task_poller.py).
#
# ПОЧЕМУ ОБЁРТКА, А НЕ ПРЯМОЙ ЗАПУСК PYTHON: надзор
# (orchestration/lib/task-poller-launch.sh) считает живые поллеры по процессам
# с comm=bash, у которых путь ЭТОГО скрипта лежит отдельным аргументом в
# cmdline. Уйди мы в exec python3 — поллер стал бы невидим, watchdog счёл бы
# его мёртвым и поднимал бы второй каждые 30 секунд.
#
# Сама логика опроса переехала в python: прежний bash-цикл поднимал
# интерпретатор дважды за цикл и заново открывал MCP-сессию каждые пять
# секунд — 254 мс на цикл, 11.2% ядра на двух агентов вхолостую (замер
# 2026-09-02). Постоянный процесс держит соединение и сессию открытыми.
#
# Env: AGENT_WORKSPACE, AGENT_ID, TASK_POLL_INTERVAL, AGENT_BEARER,
#      SECOND_BRAIN_MEMORY_ROUTER_URL, TASK_POLLER_GONE_LIMIT, PANE_INPUT_COL0.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="${AGENT_WORKSPACE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
AGENT_ID="${AGENT_ID:-$(basename "$(dirname "$WS")")}"
DAEMON="$SCRIPT_DIR/task_poller.py"
LOGDIR="$WS/logs"; mkdir -p "$LOGDIR"
LOG="$LOGDIR/task-poller.log"

# Пауза перед подъёмом после аварийного выхода: не крутить рестарт-карусель,
# если демон падает сразу (нет python3, битый файл, отсутствует воркспейс).
RESTART_DELAY="${TASK_POLLER_RESTART_DELAY:-10}"

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [task-poller] $1" >> "$LOG"; }

if [ ! -f "$DAEMON" ]; then
    log "нет $DAEMON — поллер не запущен"
    exit 0
fi

# Тестовый хук: дать тестам подключить функции, не запуская цикл.
[ "${TASK_POLLER_LIB:-0}" = "1" ] && return 0

while true; do
    AGENT_WORKSPACE="$WS" AGENT_ID="$AGENT_ID" python3 "$DAEMON"
    rc=$?
    # 0 — сессия агента исчезла, это штатный конец жизни поллера.
    if [ "$rc" -eq 0 ]; then
        exit 0
    fi
    log "демон вышел с кодом $rc — подъём через ${RESTART_DELAY}s"
    sleep "$RESTART_DELAY" || true
done
