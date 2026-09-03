#!/usr/bin/env bash
# stop-agent.sh — детерминированная остановка ОДНОГО агента.
#
# ЗАЧЕМ ОТДЕЛЬНЫЙ СКРИПТ: у юнита не было ни ExecStop, ни KillMode, поэтому
# systemd убивал только свою cgroup. А сессия claude туда не попадает: tmux-
# сервер общий на весь рой и живёт в cgroup ТОГО агента, который поднял его
# первым (проверено на живом хосте 03.09.2026: сессии всех трёх агентов лежали
# в cgroup claude-agent-carmella). Из этого росли два бага:
#   • `systemctl restart claude-agent-<не-владелец>` не перезапускал сессию —
#     watchdog поднимался, видел живую сессию и не пересоздавал её, так что
#     правки .mcp.json / CLAUDE.md / settings.json молча не доезжали;
#   • `systemctl disable --now` оставлял осиротевший claude с его bun-каналом,
#     держащим webhook-порт, — уже после удаления воркспейса.
# Теперь юнит зовёт этот скрипт в ExecStop и снимает ровно своего агента,
# не трогая ни общий tmux-сервер, ни чужие сессии.
#
# Usage: stop-agent.sh <agent>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/agents.sh
. "$SCRIPT_DIR/lib/agents.sh"

AGENT="${1:?agent required}"
SESSION="labops-$AGENT"
WORKSPACE="$CLAUDE_LAB/$AGENT/.claude"

echo "[stop-agent] останавливаю '$AGENT'"

# 1. Сессия tmux. Именно kill-session, а не kill-server: сервер общий, снос
#    сервера уронил бы сессии всех остальных агентов.
if tmux has-session -t "$SESSION" 2>/dev/null; then
  tmux kill-session -t "$SESSION" 2>/dev/null || true
  echo "[stop-agent] сессия $SESSION снята"
else
  echo "[stop-agent] сессии $SESSION не было"
fi

# 2. Поллер доски. Он запущен через setsid, поэтому переживает снятие сессии;
#    ищем по точному совпадению пути в cmdline (см. lib/task-poller-launch.sh:
#    pgrep -f матчил бы и нас самих, путь попадает в нашу собственную cmdline).
stopped_pollers=0
for candidate in "$WORKSPACE/scripts/task-poller.sh" "$WORKSPACE/scripts/task_poller.py"; do
  [ -f "$candidate" ] || continue
  for pid in $(pgrep -x bash 2>/dev/null || true) $(pgrep -x python3 2>/dev/null || true); do
    # 2>/dev/null ДО редиректа ввода: процесс мог исчезнуть между pgrep и чтением.
    if tr '\0' '\n' 2>/dev/null < "/proc/$pid/cmdline" | grep -Fxq "$candidate"; then
      kill "$pid" 2>/dev/null || true
      stopped_pollers=$((stopped_pollers + 1))
    fi
  done
done
echo "[stop-agent] поллеров остановлено: $stopped_pollers"

# 3. Осиротевший bun-канал этого агента. kill-session убивает claude, но его
#    ребёнок bun переусыновляется к PID 1 и продолжает держать webhook-порт
#    (та же гонка, что описана в start-agent.sh). Шаблон пути агент-специфичен —
#    чужой канал не заденет.
if pkill -9 -f "$CLAUDE_LAB/$AGENT/.claude/.*/plugin/src/server.ts" 2>/dev/null; then
  echo "[stop-agent] осиротевший канал агента прибран"
fi

echo "[stop-agent] '$AGENT' остановлен"
