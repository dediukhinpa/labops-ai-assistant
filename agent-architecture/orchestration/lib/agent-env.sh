#!/usr/bin/env bash
# agent-env.sh — сборка окружения агентской сессии в ОДНОМ месте.
#
# ЗАЧЕМ ОТДЕЛЬНАЯ БИБЛИОТЕКА. Раньше окружение собирал start-agent.sh и передавал
# в сессию флагами `tmux new-session -e VAR=value`. Значения при этом попадают в
# КОМАНДНУЮ СТРОКУ, а её видно в обычном `ps` любому пользователю машины —
# файловые права 0600 на channel.env такую выдачу не закрывают.
#
# Утечка была не мгновенной, а постоянной: tmux-сервер живёт с cmdline той
# команды, которая его подняла, то есть до перезапуска всего роя. Замер на живом
# хосте 08.09.2026 — в cmdline tmux-сервера открытым текстом лежали
# AGENT_BEARER, TELEGRAM_BOT_TOKEN, TELEGRAM_WEBHOOK_TOKEN и GROQ_API_KEY,
# при выключенном hidepid у /proc.
#
# Теперь окружение собирает session-exec.sh уже ВНУТРИ панели, вызывая
# resolve_agent_env, и в командной строке остаётся только имя агента.
#
# Побочно это надёжнее прежнего способа. `tmux new-session` не наследует
# окружение вызывающего: сессия строится из ГЛОБАЛЬНОГО окружения общего
# tmux-сервера (его загрязнил тот агент, что стартовал первым) плюс -e. Ключ,
# забытый в списке -e, молча протекал от соседа. Здесь же экспорт внутри панели
# перекрывает всё унаследованное, и полнота списка больше ни на что не влияет.

# Не трогаем SCRIPT_DIR: watchdog.sh собирает по нему пути, а lib/pane-recover.sh
# его при сорсинге перезаписывает — повторять эту ошибку не будем.
_AGENT_ENV_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Сорсим ростер, только если вызывающий его ещё не подтянул: у agents.sh нет
# защиты от повторного сорсинга, а проверять по наличию функции — надёжнее
# любого флага-переменной.
# shellcheck source=agents.sh
command -v list_agents >/dev/null 2>&1 || . "$_AGENT_ENV_LIB_DIR/agents.sh"

# Порт вебхука агента — конфиг, не секрет. Отдельной функцией, чтобы вызывающему
# (start-agent.sh) не приходилось ради одного числа тянуть в своё окружение
# секреты и потом их вычищать.
agent_env_webhook_port() {   # <agent>
  local agent="$1" port idx=0 a
  port="$(agent_channel_var "$agent" TELEGRAM_WEBHOOK_PORT 2>/dev/null || true)"
  if [ -z "$port" ]; then
    while IFS= read -r a; do
      if [ "$a" = "$agent" ]; then port=$(( ${WEBHOOK_BASE_PORT:-6000} + idx )); break; fi
      idx=$(( idx + 1 ))
    done < <(list_agents)
  fi
  [ -n "$port" ] || return 1
  printf '%s\n' "$port"
}

# resolve_agent_env <agent> — экспортирует всё, что нужно сессии claude.
#
# Порядок источников тот же, что был в start-agent.sh: channel.env → per-agent
# .claude/secrets/ → shared/secrets/ (GROQ обычно один на рой). Возвращает 1 и
# пишет причину в stderr, если бот-токена нет нигде.
resolve_agent_env() {   # <agent>
  local agent="${1:?agent required}"
  local lab="${CLAUDE_LAB:-$HOME/.claude-lab}"
  local workspace="$lab/$agent/.claude"
  local ch_env secrets shared_secrets

  ch_env="$(agent_channel_env "$agent" 2>/dev/null || true)"
  if [ -n "$ch_env" ]; then set -a; . "$ch_env"; set +a; fi

  secrets="$workspace/secrets"
  shared_secrets="$lab/shared/secrets"
  _read_secret_opt()        { local p="$secrets/$1";        [ -r "$p" ] && cat "$p" || true; }
  _read_shared_secret_opt() { local p="$shared_secrets/$1"; [ -r "$p" ] && cat "$p" || true; }

  TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-$(_read_secret_opt telegram-bot-token)}"
  TELEGRAM_WEBHOOK_TOKEN="${TELEGRAM_WEBHOOK_TOKEN:-$(_read_secret_opt telegram-webhook-token)}"
  GROQ_API_KEY="${GROQ_API_KEY:-$(_read_secret_opt groq-api-key)}"
  GROQ_API_KEY="${GROQ_API_KEY:-$(_read_shared_secret_opt groq-api-key)}"

  if [ -z "${TELEGRAM_BOT_TOKEN:-}" ]; then
    echo "no TELEGRAM_BOT_TOKEN for '$agent' — искал в channel.env и $secrets/telegram-bot-token" >&2
    echo "  создайте агента через skills/create-agent/new-agent.sh (он пишет channel.env)" >&2
    return 1
  fi

  TELEGRAM_WEBHOOK_PORT="${TELEGRAM_WEBHOOK_PORT:-$(agent_env_webhook_port "$agent" || true)}"
  if [ -z "${TELEGRAM_WEBHOOK_PORT:-}" ]; then
    echo "Unknown agent: $agent (нет ни в channel.env, ни в ростере)" >&2
    return 1
  fi

  AGENT_ID="$agent"
  AGENT_WORKSPACE="$workspace"
  TELEGRAM_STATE_DIR="${TELEGRAM_STATE_DIR:-$lab/shared/state/$agent/telegram}"
  TELEGRAM_ALLOWED_USER_IDS="${TELEGRAM_ALLOWED_USER_IDS:-}"
  TELEGRAM_WORKSPACE_ROOT="$workspace"
  TELEGRAM_EXPECTED_BOT_ID="${TELEGRAM_EXPECTED_BOT_ID:-${TELEGRAM_BOT_TOKEN%%:*}}"
  TELEGRAM_ALLOWED_CHAT_IDS="${TELEGRAM_ALLOWED_CHAT_IDS:-$TELEGRAM_ALLOWED_USER_IDS}"
  TELEGRAM_WEBHOOK_HOST="${TELEGRAM_WEBHOOK_HOST:-127.0.0.1}"
  TELEGRAM_MEMORY_ENABLED="${TELEGRAM_MEMORY_ENABLED:-true}"
  TELEGRAM_MEMORY_WORKSPACE="${TELEGRAM_MEMORY_WORKSPACE:-$workspace}"
  TELEGRAM_MEMORY_AGENT_LABEL="${TELEGRAM_MEMORY_AGENT_LABEL:-$agent}"
  TELEGRAM_MEMORY_SOURCE_TAG="${TELEGRAM_MEMORY_SOURCE_TAG:-tg}"

  export AGENT_ID AGENT_WORKSPACE TELEGRAM_BOT_TOKEN TELEGRAM_STATE_DIR \
         TELEGRAM_ALLOWED_USER_IDS TELEGRAM_WORKSPACE_ROOT TELEGRAM_WEBHOOK_PORT \
         TELEGRAM_WEBHOOK_TOKEN GROQ_API_KEY TELEGRAM_EXPECTED_BOT_ID \
         TELEGRAM_ALLOWED_CHAT_IDS TELEGRAM_WEBHOOK_HOST TELEGRAM_MEMORY_ENABLED \
         TELEGRAM_MEMORY_WORKSPACE TELEGRAM_MEMORY_AGENT_LABEL TELEGRAM_MEMORY_SOURCE_TAG

  # second_brain: recall включается только с НАСТОЯЩИМ токеном. Плейсхолдер
  # оставлять в окружении нельзя — SessionStart-хук на каждом старте съедал бы
  # ~15 с мёртвым curl. Здесь плейсхолдер именно ВЫЧИЩАЕТСЯ: agent.env мы уже
  # засорсили, поэтому просто «не экспортировать» недостаточно.
  local agent_env_file="$workspace/agent.env"
  if [ -f "$agent_env_file" ]; then set -a; . "$agent_env_file"; set +a; fi
  if [ -n "${AGENT_BEARER:-}" ] && [ "${AGENT_BEARER:-}" != "CHANGE_ME" ]; then
    export MCP_HOST="${MCP_HOST:-}" AGENT_BEARER \
           SECOND_BRAIN_MEMORY_URL="${SECOND_BRAIN_MEMORY_URL:-}" \
           SECOND_BRAIN_MEMORY_ROUTER_URL="${SECOND_BRAIN_MEMORY_ROUTER_URL:-}" \
           SECOND_BRAIN_AGENT_ROUTER_URL="${SECOND_BRAIN_AGENT_ROUTER_URL:-}" \
           SECOND_BRAIN_TASKS_URL="${SECOND_BRAIN_TASKS_URL:-}" \
           AGENT_SCOPES="${AGENT_SCOPES:-}" SUMMARY_LANGUAGE="${SUMMARY_LANGUAGE:-}"
  else
    echo "[agent-env] $agent: second_brain recall off (AGENT_BEARER placeholder/unset — бэкенд не подключён)" >&2
    unset AGENT_BEARER MCP_HOST SECOND_BRAIN_MEMORY_URL SECOND_BRAIN_MEMORY_ROUTER_URL \
          SECOND_BRAIN_AGENT_ROUTER_URL SECOND_BRAIN_TASKS_URL AGENT_SCOPES \
          SUMMARY_LANGUAGE 2>/dev/null || true
  fi

  # bun обязан быть в PATH: без него claude не поднимет свой канальный MCP-сервер
  # («Executable not found in $PATH: bun») и агент молча остаётся без Telegram.
  export PATH="$HOME/.local/bin:${BUN_INSTALL:-$HOME/.bun}/bin:$PATH"
}
