#!/usr/bin/env bash
set -euo pipefail

# Запускается из-под systemd (watchdog.sh) — минимальный PATH без ~/.local/bin,
# где нативный claude ставится. Без этого "command -v claude" ниже не находит
# бинарник, и агент вообще не поднимается под systemd.
export PATH="$HOME/.local/bin:$PATH"

source "$(dirname "$0")/lib/agents.sh"
# Единый запуск/надзор task-поллера (тот же код использует watchdog для supervise).
source "$(dirname "$0")/lib/task-poller-launch.sh"
# Метка пройденного онбординга перед стартом — иначе обновившийся CLI встретит
# сессию мастером первого запуска (см. cli_version_mark_onboarding_done).
source "$(dirname "$0")/lib/cli-version.sh"
# Распознавание вопроса о каналах для разработки — общее с watchdog.sh.
source "$(dirname "$0")/lib/pane.sh"

AGENT="$1"
SESSION="labops-$AGENT"
WORKSPACE="$CLAUDE_LAB/$AGENT/.claude"

# claude's CWD must be inside the plugin dir, not the workspace root: config
# discovery (CLAUDE.md, .mcp.json) walks UP from CWD, so plugin/.mcp.json
# (defines the labops-channel MCP server) is only found if CWD starts there
# or below (docs/02-where-to-place-plugin.md — "90% of first-run problems").
# CWD at WORKSPACE skips over it entirely: the channel MCP server then never
# loads ("no MCP server configured with that name"), even though the plugin
# is symlinked into the tree. Falls back to WORKSPACE if the plugin isn't
# laid out there (agent has no channel).
PLUGIN_CWD="$WORKSPACE/labops-tg-plugin/plugin"
[ -d "$PLUGIN_CWD" ] || PLUGIN_CWD="$WORKSPACE"

# Окружение сессии (включая секреты) собирает lib/agent-env.sh — ОДНО место на
# весь запуск. Здесь секретов сознательно не держим: этот процесс порождает
# tmux-сервер, и всё, что лежит в его окружении и командной строке, видно в ps
# любому пользователю машины до перезапуска роя.
# shellcheck source=lib/agent-env.sh
source "$(dirname "$0")/lib/agent-env.sh"

# Порт вебхука — конфиг, не секрет: он нужен ниже для проверки готовности.
TELEGRAM_WEBHOOK_PORT="$(agent_env_webhook_port "$AGENT" || true)"
if [ -z "$TELEGRAM_WEBHOOK_PORT" ]; then
  echo "Unknown agent: $AGENT (нет ни в channel.env, ни в ростере)" >&2; exit 1
fi

# Ранняя диагностика: убеждаемся, что окружение вообще собирается (есть
# бот-токен и прочее), но делаем это в ПОДОБОЛОЧКЕ — так сообщение об ошибке
# оператор видит здесь, а секреты в наше окружение не попадают.
if ! ( resolve_agent_env "$AGENT" >/dev/null ); then
  exit 1
fi

tmux kill-session -t "=$SESSION" 2>/dev/null || true

# Reap any leaked channel-server (bun) for THIS agent. kill-session kills claude,
# but its child bun reparents to PID 1; on a bad-luck race it lands in an EPIPE
# exception loop (the uncaughtException handler writes to the dead parent's log
# socket, which itself EPIPEs → re-enters the handler) and spins at ~90% CPU. On
# this 2-core box one such orphan starves the live sessions → frozen turns →
# watchdog restart → another orphan → cascade. The server's own orphan-watchdog
# (5s poll, server.ts:1010) loses that race intermittently, so reap explicitly
# here. The path match is agent-specific — never touches another agent's bun, and
# the new session's bun is spawned only after this point.
pkill -9 -f "$CLAUDE_LAB/$AGENT/.claude/.*/plugin/src/server.ts" 2>/dev/null || true

# PATH для сессии выставляет resolve_agent_env уже внутри панели. Здесь тем не
# менее добавляем bun и себе: свежий tmux-сервер наследует PATH ЭТОГО процесса,
# и если bun в нём не находится, claude не поднимает свой канальный MCP-сервер
# («Executable not found in $PATH: bun») — агент молча остаётся без Telegram.
export PATH="${BUN_INSTALL:-$HOME/.bun}/bin:$PATH"

# Heartbeat-readiness (см. цикл ниже): SessionStart-хук пишет эпоху в
# $WORKSPACE/state/heartbeat. Значение >= LAUNCH_TS = сессия реально
# инициализировалась. HAS_CHANNEL различает агентов с каналом (у них есть более
# сильный сигнал — слушающий webhook-порт) и без него.
HEARTBEAT="$WORKSPACE/state/heartbeat"
HAS_CHANNEL=0; [ "$PLUGIN_CWD" != "$WORKSPACE" ] && HAS_CHANNEL=1
LAUNCH_TS=$(date +%s)

# second_brain-окружение (recall + MCP-инструменты) собирает resolve_agent_env
# внутри панели, вместе с гардом на плейсхолдер CHANGE_ME. Здесь его больше не
# трогаем: держать AGENT_BEARER в этом процессе значит отдать его в ps через
# порождаемый tmux-сервер.

# Pre-trust the folders claude will open, so it does NOT block on the interactive
# "Is this a project you trust?" dialog at startup — which --dangerously-skip-
# permissions does NOT bypass (folder-trust is a separate first-run gate). A
# blocked dialog means claude never loads the plugin, so the bun channel server
# never starts and :6000 stays dead. claude canonicalises the symlinked plugin
# cwd, so trust BOTH the symlink path and its real target.
pretrust_folder() {
  local p="$1" cfg="$HOME/.claude.json"
  [ -n "$p" ] || return 0
  [ -f "$cfg" ] || printf '{}' > "$cfg"
  P="$p" CFG="$cfg" python3 - <<'PY' 2>/dev/null || true
import json, os
cfg = os.environ["CFG"]; p = os.environ["P"]
try:
    with open(cfg) as f: d = json.load(f)
except Exception:
    d = {}
e = d.setdefault("projects", {}).setdefault(p, {})
e["hasTrustDialogAccepted"] = True
e["hasCompletedProjectOnboarding"] = True
# A fresh agent's CLAUDE.md @-imports external files (e.g. @SECONDBRAIN_WRITE_RULES.md).
# On first run claude blocks on a "CLAUDE.md imports files outside the project —
# approve?" gate that --dangerously-skip-permissions does NOT bypass; while blocked,
# claude never spawns the labops-channel MCP server, so the webhook port stays dead
# (channel banner shows, but no bun child, :6000+ never binds). Pre-approving it here
# is the same trust decision the operator already made by installing the agent.
e["hasClaudeMdExternalIncludesApproved"] = True
e["hasClaudeMdExternalIncludesWarningShown"] = True
tmp = cfg + ".tmp"
with open(tmp, "w") as f: json.dump(d, f, indent=2)
os.replace(tmp, cfg)
PY
}
pretrust_folder "$WORKSPACE"
pretrust_folder "$PLUGIN_CWD"
pretrust_folder "$(readlink -f "$PLUGIN_CWD" 2>/dev/null || true)"

# Тот же приём и по той же причине, но для ГЛОБАЛЬНОГО гейта: обновившийся CLI
# показывает мастер первого запуска (тема, затем вход), и сессия встаёт на нём
# насмерть — до промпта не доходит, канал порт не поднимает.
cli_version_mark_onboarding_done

# Панель запускает session-exec.sh, а он уже собирает окружение и становится
# claude. Секретов в командной строке больше нет — в ps виден только агент.
#
# Побочный выигрыш: раньше сессия строилась из ГЛОБАЛЬНОГО окружения общего
# tmux-сервера (его задавал агент, стартовавший первым) плюс список -e, и ключ,
# забытый в этом списке, молча протекал от соседа — чужой bot_id ронял поллер
# канала. Теперь экспорт идёт внутри панели и перекрывает унаследованное
# целиком, так что полнота списка ни на что не влияет.
tmux new-session -d -s "$SESSION" -c "$PLUGIN_CWD" \
  "$(dirname "$(realpath "$0")")/session-exec.sh" "$AGENT"

# Near-real-time agent-to-agent task delivery (см. AGENT_ROUTER.md). Polls shared
# memory every TASK_POLL_INTERVAL s and types a new task into THIS session only
# on a clean idle prompt — no `claude -p`, so it stays on the subscription.
# ensure_task_poller идемпотентен (точный подсчёт по /proc, без self-match) и
# делится с watchdog, который поднимет поллер, если тот тихо умрёт между рестартами.
case "$(ensure_task_poller "$AGENT" "$WORKSPACE")" in
  launched) echo "[start-agent] $AGENT task-poller started (interval ${TASK_POLL_INTERVAL:-5}s)" ;;
  running)  echo "[start-agent] $AGENT task-poller already running — not duplicating" ;;
  noscript) echo "[start-agent] $AGENT no task-poller.sh — skipping" ;;
esac

# Готовность канала = его webhook-сервер (bun ./src/server.ts, спавнит claude)
# забиндил TELEGRAM_WEBHOOK_PORT на localhost. Это авторитетный сигнал, не завися-
# щий от версии claude и формулировок в TUI. Раньше грепали строку "Listening for
# channel" из pane — в текущих версиях claude её нет, поэтому проверка всегда
# истекала по таймауту и сыпала ложный WARNING (канал при этом реально поднимался,
# порт слушался). Предшествующий pkill/kill-session освободил порт, так что
# слушающий сокет = именно новый сервер этой сессии.
channel_ready() {
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | grep -qE "127\.0\.0\.1:${TELEGRAM_WEBHOOK_PORT}\b"
  else
    # fallback без ss: успешный TCP-connect к порту (fd закроется с выходом subshell)
    (exec 3<>"/dev/tcp/127.0.0.1/${TELEGRAM_WEBHOOK_PORT}") 2>/dev/null
  fi
}

# Готовность сессии = SessionStart-хук записал свежий heartbeat (эпоха >= момента
# запуска). Не зависит от TUI-текста; для агентов без канала это единственный
# надёжный сигнал (раньше грепали исчезнувшую строку "Listening for channel").
session_ready() {
  local hb
  [ -f "$HEARTBEAT" ] || return 1
  hb=$(cat "$HEARTBEAT" 2>/dev/null || echo 0)
  case "$hb" in ''|*[!0-9]*) return 1;; esac
  [ "$hb" -ge "$LAUNCH_TS" ]
}

# Сколько ждать готовности. Вопрос о каналах для разработки claude задаёт не
# сразу: после самообновления CLI первый старт медленнее, и 10.09.2026 вопрос
# появился позже прежних 30 секунд — скрипт вышел, не ответив, и агент так и
# остался на нём. Ответ продублирован в watchdog.sh (ветка A0), а здесь просто
# ждём дольше. watchdog зовёт этот скрипт синхронно, юнит Type=simple, поэтому
# лимит запуска systemd на это ожидание не распространяется.
START_READY_TIMEOUT="${START_READY_TIMEOUT:-90}"
DEADLINE=$(( $(date +%s) + START_READY_TIMEOUT ))
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  # Агент с каналом готов, когда его webhook-порт слушается (строгое доказательство,
  # что claude поднял MCP-сервер); агент без канала — когда SessionStart-хук
  # отметил heartbeat. И то, и другое — сигналы независимые от TUI-текста.
  if [ "$HAS_CHANNEL" -eq 1 ] && channel_ready; then
    echo "[start-agent] $AGENT ready (session up, webhook :$TELEGRAM_WEBHOOK_PORT)"
    exit 0
  fi
  if [ "$HAS_CHANNEL" -eq 0 ] && session_ready; then
    echo "[start-agent] $AGENT ready (session up)"
    exit 0
  fi
  PANE=$(tmux capture-pane -pt "=$SESSION:" -S -30 2>/dev/null || true)
  # Стоит на экране логина — ~/.claude/.credentials.json нет/просрочен. Токен
  # из окружения тут не поможет (TUI его не проверяет, см. install.sh), и
  # таймаут ниже дал бы неинформативный WARNING — watchdog.sh тихо крутил
  # бы рестарты (StartLimitIntervalSec=120, StartLimitBurst=5), пока это не
  # исправят вручную. Фейлим сразу с понятной причиной.
  if echo "$PANE" | grep -qE "Browser didn't open|Use the url below to sign in"; then
    echo "[start-agent] ERROR: $AGENT застрял на экране логина — нет ~/.claude/.credentials.json (или просрочен)." >&2
    echo "  Исправьте один раз: claude --dangerously-skip-permissions (войдите по ссылке, затем /exit), затем перезапустите сервис." >&2
    tmux kill-session -t "=$SESSION" 2>/dev/null || true
    exit 1
  fi
  # Тот же детектор и тот же ответ, что в watchdog.sh (ветка A0): Enter только
  # на первом пункте, иначе claude бы вышел.
  if looks_like_dev_channels_prompt "$PANE"; then
    answer_dev_channels_prompt "$SESSION" "$PANE" || true
  fi
  sleep 1
done

echo "[start-agent] WARNING: $AGENT — webhook :$TELEGRAM_WEBHOOK_PORT не слушается за ${START_READY_TIMEOUT}s (канал не поднялся)" >&2
exit 0
