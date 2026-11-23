#!/usr/bin/env bash
# lib/agents.sh — shared helpers for resolving the agent roster and per-agent
# Telegram bot tokens WITHOUT hardcoding any lab-specific names or secrets.
#
# This file is meant to be *sourced*, not executed, so it does NOT set `set -e`.
#
#   source "$(dirname "$0")/lib/agents.sh"
#
# Provides:
#   list_agents                 -> prints one agent-id per line
#   agent_bot_token <agent>     -> prints that agent's TELEGRAM_BOT_TOKEN

# Root of the local agent lab. Override with CLAUDE_LAB if needed.
: "${CLAUDE_LAB:=$HOME/.claude-lab}"

# list_agents — print the roster, one agent-id per line.
#
# Resolution order:
#   1. If $CLAUDE_LAB/agents.conf exists, print its non-empty, non-comment lines.
#   2. Otherwise, scan $CLAUDE_LAB/*/.claude and print the parent directory
#      basename for each, excluding infra directories.
list_agents() {
  local conf="$CLAUDE_LAB/agents.conf"
  if [ -f "$conf" ]; then
    # Strip comments and blank lines; trim surrounding whitespace.
    while IFS= read -r line; do
      line="${line%%#*}"
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      [ -n "$line" ] && printf '%s\n' "$line"
    done < "$conf"
    return 0
  fi

  local d name
  for d in "$CLAUDE_LAB"/*/.claude; do
    [ -d "$d" ] || continue
    name="$(basename "$(dirname "$d")")"
    case "$name" in
      shared|logs|mcp-servers|__pycache__) continue ;;
    esac
    printf '%s\n' "$name"
  done
}

# agent_channel_env <agent> — print the path to the agent's channel.env.
#
# Reads the first existing of:
#   /etc/labops-plugin/<agent>/channel.env
#   $CLAUDE_LAB/shared/state/<agent>/telegram/channel.env
# Returns 1 (no output) if none exists.
agent_channel_env() {
  local agent="$1" f
  [ -n "$agent" ] || { echo "agent_channel_env: agent name required" >&2; return 1; }
  for f in \
    "/etc/labops-plugin/$agent/channel.env" \
    "$CLAUDE_LAB/shared/state/$agent/telegram/channel.env"; do
    [ -f "$f" ] && { printf '%s\n' "$f"; return 0; }
  done
  return 1
}

# agent_channel_var <agent> <VAR> — print the value of VAR from the agent's
# channel.env (quotes/whitespace stripped). Nothing is ever hardcoded here —
# all per-agent config and secrets live in that file (chmod 600, not in git).
# Returns 1 if the file or the variable is missing.
agent_channel_var() {
  local agent="$1" var="$2" f line val
  [ -n "$var" ] || { echo "agent_channel_var: VAR name required" >&2; return 1; }
  f="$(agent_channel_env "$agent")" || return 1
  line="$(grep -E "^[[:space:]]*${var}[[:space:]]*=" "$f" | head -1)"
  [ -n "$line" ] || return 1
  val="${line#*=}"
  val="${val#"${val%%[![:space:]]*}"}"
  val="${val%"${val##*[![:space:]]}"}"
  val="${val#\"}"; val="${val%\"}"
  val="${val#\'}"; val="${val%\'}"
  [ -n "$val" ] || return 1
  printf '%s\n' "$val"
}

# agent_bot_token <agent> — print that agent's TELEGRAM_BOT_TOKEN (from channel.env).
agent_bot_token() {
  local agent="$1" token
  if [ -z "$agent" ]; then
    echo "agent_bot_token: agent name required" >&2
    return 1
  fi
  token="$(agent_channel_var "$agent" TELEGRAM_BOT_TOKEN)" && [ -n "$token" ] && {
    printf '%s\n' "$token"; return 0;
  }
  echo "agent_bot_token: no TELEGRAM_BOT_TOKEN found for agent '$agent'" >&2
  return 1
}

# ── Маркер «агент останавливается» ───────────────────────────────────────────
# systemd при `systemctl stop` сначала исполняет ExecStop (stop-agent.sh), пока главный процесс
# юнита — watchdog — ещё жив, и только потом шлёт ему SIGTERM. У агента на Codex stop-agent ждёт
# сброса памяти драйвером до 35 с; watchdog в это окно видел «сессии нет» и поднимал агента
# заново, а его start-agent переживал SIGTERM главному процессу (KillMode=process) — остановка
# не останавливала. Маркер ставит stop-agent ДО снятия сессии; watchdog перед любым рестартом
# его проверяет. Снимается при старте watchdog и при ручном запуске start-agent.
# Все функции возвращают 0 (кроме agent_stopping): их зовут из скриптов под set -e.

# agent_stop_marker <agent> — путь маркера (в state рабочей папки агента).
agent_stop_marker() { printf '%s/%s/.claude/state/stopping\n' "$CLAUDE_LAB" "$1"; }

# agent_stop_mark <agent> — поставить маркер. Нет рабочей папки агента — не создаём мусор.
agent_stop_mark() {
  local f
  [ -d "$CLAUDE_LAB/$1/.claude" ] || return 0
  f="$(agent_stop_marker "$1")"
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 0
  date +%s > "$f" 2>/dev/null || true
  return 0
}

# agent_stop_clear <agent> — снять маркер.
agent_stop_clear() { rm -f "$(agent_stop_marker "$1")" 2>/dev/null || true; return 0; }

# agent_stopping <agent> — 0, если агент сейчас останавливается.
agent_stopping() { [ -f "$(agent_stop_marker "$1")" ]; }
