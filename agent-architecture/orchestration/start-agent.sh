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

tmux new-session -d -s "$SESSION" -c "$WORKSPACE" \
  -e TELEGRAM_BOT_TOKEN="$TELEGRAM_BOT_TOKEN" \
  -e TELEGRAM_STATE_DIR="$TELEGRAM_STATE_DIR" \
  -e TELEGRAM_ALLOWED_USER_IDS="$TELEGRAM_ALLOWED_USER_IDS" \
  -e TELEGRAM_WORKSPACE_ROOT="$WORKSPACE" \
  -e TELEGRAM_WEBHOOK_PORT="$TELEGRAM_WEBHOOK_PORT" \
  -e TELEGRAM_WEBHOOK_TOKEN="$TELEGRAM_WEBHOOK_TOKEN" \
  -e GROQ_API_KEY="$GROQ_API_KEY" \
  -e PATH="$HOME/.local/bin:$BUN_BIN_DIR:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  "$CLAUDE_BIN" \
    --dangerously-skip-permissions \
    --dangerously-load-development-channels server:labops-channel

DEADLINE=$(( $(date +%s) + 30 ))
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  PANE=$(tmux capture-pane -pt "$SESSION" -S -30 2>/dev/null || true)
  if echo "$PANE" | grep -q "Listening for channel"; then
    echo "[start-agent] $AGENT listening (webhook :$TELEGRAM_WEBHOOK_PORT)"
    exit 0
  fi
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

echo "[start-agent] WARNING: $AGENT did not reach Listening in 30s" >&2
exit 0
