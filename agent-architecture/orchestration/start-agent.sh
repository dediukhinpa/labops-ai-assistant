#!/usr/bin/env bash
set -euo pipefail

# Запускается из-под systemd (watchdog.sh) — минимальный PATH без ~/.local/bin,
# где нативный claude ставится. Без этого "command -v claude" ниже не находит
# бинарник, и агент вообще не поднимается под systemd.
export PATH="$HOME/.local/bin:$PATH"

source "$(dirname "$0")/lib/agents.sh"

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

# Channel config + секреты живут в channel.env (его пишет create-agent /
# new-agent.sh) — единый источник истины, chmod 600, в git не попадает. Легаси-
# файлы под .claude/secrets/ поддерживаются как fallback. Ничего не хардкодим.
CH_ENV="$(agent_channel_env "$AGENT" 2>/dev/null || true)"
if [ -n "$CH_ENV" ]; then set -a; . "$CH_ENV"; set +a; fi

# Per-agent webhook port (config, not secret): из channel.env, иначе детермини-
# рованно из позиции агента в ростере (lib/agents.sh), от WEBHOOK_BASE_PORT.
WEBHOOK_BASE_PORT="${WEBHOOK_BASE_PORT:-6000}"
if [ -z "${TELEGRAM_WEBHOOK_PORT:-}" ]; then
  idx=0
  while IFS= read -r _a; do
    if [ "$_a" = "$AGENT" ]; then TELEGRAM_WEBHOOK_PORT=$(( WEBHOOK_BASE_PORT + idx )); break; fi
    idx=$(( idx + 1 ))
  done < <(list_agents)
fi
if [ -z "${TELEGRAM_WEBHOOK_PORT:-}" ]; then
  echo "Unknown agent: $AGENT (нет ни в channel.env, ни в ростере)" >&2; exit 1
fi

# Секреты: сначала channel.env (уже в окружении после source), затем
# .claude/secrets/ (per-agent), затем shared/secrets/ (кросс-агентные — GROQ
# обычно один на всех агентов, кладёт его туда new-agent.sh / install.sh,
# чтобы не спрашивать заново на каждого нового агента). Claude Code сюда не
# входит: TUI-сессия ниже авторизуется через ~/.claude/.credentials.json
# (реальный вход, один на $HOME), а не через переменную окружения.
SECRETS="$CLAUDE_LAB/$AGENT/.claude/secrets"
SHARED_SECRETS="$CLAUDE_LAB/shared/secrets"
read_secret_opt() { local p="$SECRETS/$1"; [ -r "$p" ] && cat "$p" || true; }
read_shared_secret_opt() { local p="$SHARED_SECRETS/$1"; [ -r "$p" ] && cat "$p" || true; }
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-$(read_secret_opt telegram-bot-token)}"
TELEGRAM_WEBHOOK_TOKEN="${TELEGRAM_WEBHOOK_TOKEN:-$(read_secret_opt telegram-webhook-token)}"
GROQ_API_KEY="${GROQ_API_KEY:-$(read_secret_opt groq-api-key)}"
GROQ_API_KEY="${GROQ_API_KEY:-$(read_shared_secret_opt groq-api-key)}"
TELEGRAM_STATE_DIR="${TELEGRAM_STATE_DIR:-$CLAUDE_LAB/shared/state/$AGENT/telegram}"
TELEGRAM_ALLOWED_USER_IDS="${TELEGRAM_ALLOWED_USER_IDS:-}"

if [ -z "$TELEGRAM_BOT_TOKEN" ]; then
  echo "no TELEGRAM_BOT_TOKEN for '$AGENT' — искал в channel.env и $SECRETS/telegram-bot-token" >&2
  echo "  создайте агента через skills/create-agent/new-agent.sh (он пишет channel.env)" >&2
  exit 1
fi

tmux kill-session -t "$SESSION" 2>/dev/null || true

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

# Движок и bun резолвим из окружения, не хардкодим путь.
CLAUDE_BIN="$(command -v claude 2>/dev/null || echo claude)"
BUN_BIN_DIR="${BUN_INSTALL:-$HOME/.bun}/bin"

# tmux -e PATH below sets the SESSION environment, but when new-session spins up a
# fresh tmux server the launched command inherits the SERVER's (this caller's)
# PATH, not the -e value. That PATH lacks ~/.bun/bin, so claude spawns its channel
# MCP server (bun ./src/server.ts) and fails with "Executable not found in $PATH:
# bun" — the channel never comes up and the agent goes silent. Export bun's dir
# here so the tmux server itself has it resolvable (belt-and-suspenders with -e).
export PATH="$BUN_BIN_DIR:$PATH"

# Heartbeat-readiness (см. цикл ниже): SessionStart-хук пишет эпоху в
# $WORKSPACE/state/heartbeat. Значение >= LAUNCH_TS = сессия реально
# инициализировалась. HAS_CHANNEL различает агентов с каналом (у них есть более
# сильный сигнал — слушающий webhook-порт) и без него.
HEARTBEAT="$WORKSPACE/state/heartbeat"
HAS_CHANNEL=0; [ "$PLUGIN_CWD" != "$WORKSPACE" ] && HAS_CHANNEL=1
LAUNCH_TS=$(date +%s)

# Second-brain runtime env (memory recall + agent MCP tools). Lives in agent.env
# (written by new-agent.sh), but start-agent never propagated it into the session
# — so the SessionStart recall hook saw MCP_HOST/AGENT_BEARER unset and silently
# skipped recall (it has never worked). Propagate via -e below. Placeholder guard:
# a CHANGE_ME/empty bearer means second_brain isn't wired yet, so recall stays OFF
# (else every session start eats a ~15s dead curl); it activates automatically once
# a real token is written to agent.env. We propagate ONLY via -e and unset locally
# afterwards, so a placeholder can never leak into the session through the tmux
# server's global env (the way PATH does — see the export above).
AGENT_ENV_FILE="$WORKSPACE/agent.env"
if [ -f "$AGENT_ENV_FILE" ]; then set -a; . "$AGENT_ENV_FILE"; set +a; fi
SB_ENV=()
if [ -n "${AGENT_BEARER:-}" ] && [ "${AGENT_BEARER:-}" != "CHANGE_ME" ]; then
  SB_ENV=( -e "MCP_HOST=${MCP_HOST:-}" -e "AGENT_BEARER=${AGENT_BEARER}" \
           -e "SECOND_BRAIN_MEMORY_URL=${SECOND_BRAIN_MEMORY_URL:-}" \
           -e "SECOND_BRAIN_MEMORY_ROUTER_URL=${SECOND_BRAIN_MEMORY_ROUTER_URL:-}" \
           -e "SECOND_BRAIN_AGENT_ROUTER_URL=${SECOND_BRAIN_AGENT_ROUTER_URL:-}" \
           -e "AGENT_SCOPES=${AGENT_SCOPES:-}" -e "SUMMARY_LANGUAGE=${SUMMARY_LANGUAGE:-}" )
else
  echo "[start-agent] $AGENT: second_brain recall off (AGENT_BEARER placeholder/unset — бэкенд не подключён)" >&2
fi
unset AGENT_BEARER MCP_HOST SECOND_BRAIN_MEMORY_URL SECOND_BRAIN_MEMORY_ROUTER_URL \
      SECOND_BRAIN_AGENT_ROUTER_URL AGENT_SCOPES SUMMARY_LANGUAGE 2>/dev/null || true

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

# --settings below is REQUIRED, not optional: CWD is the plugin dir so .mcp.json
# is discovered, but claude canonicalises the symlinked plugin path to its real
# location (/home/.../labops-tg-plugin/plugin) OUTSIDE the workspace tree. Config
# discovery then walks up from there and never sees $WORKSPACE/settings.json — so
# NONE of the workspace hooks (heartbeat, SessionStart recall, Stop) ever fire.
# Loading settings.json explicitly fixes that (and the long-silent memory hooks).
#
# Per-agent channel identity MUST be passed explicitly below: tmux new-session
# builds the session env from the shared tmux SERVER's GLOBAL environment
# (polluted by whichever agent started first) plus the -e overrides — it does
# NOT inherit start-agent's process env. Keys absent from the -e list leak from
# the global env (e.g. developer's TELEGRAM_EXPECTED_BOT_ID / MEMORY_*), so a
# new agent's channel server boots with the wrong bot_id ("bot_id mismatch ->
# poller exited") and the wrong memory workspace. Session env overrides global.
tmux new-session -d -s "$SESSION" -c "$PLUGIN_CWD" \
  -e AGENT_ID="$AGENT" \
  -e AGENT_WORKSPACE="$WORKSPACE" \
  ${SB_ENV[@]+"${SB_ENV[@]}"} \
  -e TELEGRAM_BOT_TOKEN="$TELEGRAM_BOT_TOKEN" \
  -e TELEGRAM_STATE_DIR="$TELEGRAM_STATE_DIR" \
  -e TELEGRAM_ALLOWED_USER_IDS="$TELEGRAM_ALLOWED_USER_IDS" \
  -e TELEGRAM_WORKSPACE_ROOT="$WORKSPACE" \
  -e TELEGRAM_WEBHOOK_PORT="$TELEGRAM_WEBHOOK_PORT" \
  -e TELEGRAM_WEBHOOK_TOKEN="$TELEGRAM_WEBHOOK_TOKEN" \
  -e GROQ_API_KEY="$GROQ_API_KEY" \
  -e TELEGRAM_EXPECTED_BOT_ID="${TELEGRAM_EXPECTED_BOT_ID:-${TELEGRAM_BOT_TOKEN%%:*}}" \
  -e TELEGRAM_ALLOWED_CHAT_IDS="${TELEGRAM_ALLOWED_CHAT_IDS:-$TELEGRAM_ALLOWED_USER_IDS}" \
  -e TELEGRAM_WEBHOOK_HOST="${TELEGRAM_WEBHOOK_HOST:-127.0.0.1}" \
  -e TELEGRAM_MEMORY_ENABLED="${TELEGRAM_MEMORY_ENABLED:-true}" \
  -e TELEGRAM_MEMORY_WORKSPACE="${TELEGRAM_MEMORY_WORKSPACE:-$WORKSPACE}" \
  -e TELEGRAM_MEMORY_AGENT_LABEL="${TELEGRAM_MEMORY_AGENT_LABEL:-$AGENT}" \
  -e TELEGRAM_MEMORY_SOURCE_TAG="${TELEGRAM_MEMORY_SOURCE_TAG:-tg}" \
  -e PATH="$HOME/.local/bin:$BUN_BIN_DIR:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  "$CLAUDE_BIN" \
    --settings "$WORKSPACE/settings.json" \
    --dangerously-skip-permissions \
    --dangerously-load-development-channels server:labops-channel

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

DEADLINE=$(( $(date +%s) + 30 ))
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
  PANE=$(tmux capture-pane -pt "$SESSION" -S -30 2>/dev/null || true)
  # Стоит на экране логина — ~/.claude/.credentials.json нет/просрочен. Токен
  # из окружения тут не поможет (TUI его не проверяет, см. install.sh), и
  # 30с-таймаут ниже дал бы неинформативный WARNING — watchdog.sh тихо крутил
  # бы рестарты (StartLimitIntervalSec=120, StartLimitBurst=5), пока это не
  # исправят вручную. Фейлим сразу с понятной причиной.
  if echo "$PANE" | grep -qE "Browser didn't open|Use the url below to sign in"; then
    echo "[start-agent] ERROR: $AGENT застрял на экране логина — нет ~/.claude/.credentials.json (или просрочен)." >&2
    echo "  Исправьте один раз: claude --dangerously-skip-permissions (войдите по ссылке, затем /exit), затем перезапустите сервис." >&2
    tmux kill-session -t "$SESSION" 2>/dev/null || true
    exit 1
  fi
  if echo "$PANE" | grep -q "I am using this for local development"; then
    tmux send-keys -t "$SESSION" Enter
  fi
  sleep 1
done

echo "[start-agent] WARNING: $AGENT — webhook :$TELEGRAM_WEBHOOK_PORT не слушается за 30s (канал не поднялся)" >&2
exit 0
