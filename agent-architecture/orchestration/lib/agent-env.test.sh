#!/usr/bin/env bash
# Unit tests for lib/agent-env.sh + session-exec.sh.
#
# Главная проверка — секрет доезжает до процесса ЧЕРЕЗ ОКРУЖЕНИЕ и при этом не
# появляется в его командной строке. Ради неё тест не мокает запуск, а реально
# исполняет session-exec.sh с подставным `claude`, который печатает свою cmdline
# и своё окружение.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ORCH="$(cd "$HERE/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

AGENT="probe"
export CLAUDE_LAB="$TMP/lab"
WS="$CLAUDE_LAB/$AGENT/.claude"
mkdir -p "$WS/secrets" "$CLAUDE_LAB/shared/secrets" "$CLAUDE_LAB/shared/state/$AGENT/telegram"

# Заведомо узнаваемые «секреты»: если хоть один всплывёт в командной строке,
# тест это увидит по подстроке.
TOK="111111:AAtest-bot-token-value"
BEARER="test-bearer-value"
WHTOK="test-webhook-token-value"
GROQ="gsk_test-groq-key-value"

cat > "$CLAUDE_LAB/shared/state/$AGENT/telegram/channel.env" <<EOF
TELEGRAM_BOT_TOKEN=$TOK
TELEGRAM_WEBHOOK_TOKEN=$WHTOK
TELEGRAM_ALLOWED_USER_IDS=42
TELEGRAM_WEBHOOK_PORT=6099
EOF
chmod 600 "$CLAUDE_LAB/shared/state/$AGENT/telegram/channel.env"
printf '%s' "$GROQ" > "$CLAUDE_LAB/shared/secrets/groq-api-key"

write_agent_env() {   # <bearer>
  cat > "$WS/agent.env" <<EOF
export AGENT_BEARER=$1
export MCP_HOST=127.0.0.1
export SECOND_BRAIN_MEMORY_URL=http://127.0.0.1:5001/mcp
export AGENT_SCOPES=knowledge
EOF
  chmod 600 "$WS/agent.env"
}
write_agent_env "$BEARER"

# shellcheck disable=SC1091
source "$HERE/agent-env.sh"

# 1. Полный резолв: секреты и производные значения на месте.
( resolve_agent_env "$AGENT" >/dev/null 2>&1
  [ "$TELEGRAM_BOT_TOKEN" = "$TOK" ]        || exit 1
  [ "$TELEGRAM_WEBHOOK_TOKEN" = "$WHTOK" ]  || exit 2
  [ "$AGENT_BEARER" = "$BEARER" ]           || exit 3
  [ "$GROQ_API_KEY" = "$GROQ" ]             || exit 4   # подхват из shared/secrets
  [ "$TELEGRAM_WEBHOOK_PORT" = "6099" ]     || exit 5
  [ "$TELEGRAM_EXPECTED_BOT_ID" = "111111" ] || exit 6  # выводится из токена
  [ "$TELEGRAM_ALLOWED_CHAT_IDS" = "42" ]   || exit 7   # падает на user_ids
  [ "$AGENT_WORKSPACE" = "$WS" ]            || exit 8
) || fail "резолв окружения неполный (код $?)"

# 2. Плейсхолдер bearer ВЫЧИЩАЕТСЯ, а не просто «не экспортируется»: agent.env к
#    этому моменту уже засорсен, и без unset мёртвый токен уехал бы в сессию.
write_agent_env "CHANGE_ME"
( resolve_agent_env "$AGENT" >/dev/null 2>&1
  [ -z "${AGENT_BEARER:-}" ] || exit 1
  [ -z "${SECOND_BRAIN_MEMORY_URL:-}" ] || exit 2
) || fail "плейсхолдер CHANGE_ME не вычищен из окружения (код $?)"
write_agent_env "$BEARER"

# 3. Нет бот-токена — внятный отказ, а не молчаливый запуск без канала.
mv "$CLAUDE_LAB/shared/state/$AGENT/telegram/channel.env" "$TMP/ch.bak"
( resolve_agent_env "$AGENT" >/dev/null 2>&1 ) && fail "резолв без бот-токена не должен проходить"
mv "$TMP/ch.bak" "$CLAUDE_LAB/shared/state/$AGENT/telegram/channel.env"

# 4. Порт как конфиг — отдельной функцией, без затягивания секретов.
[ "$(agent_env_webhook_port "$AGENT")" = "6099" ] || fail "порт вебхука резолвится неверно"

# ── Главное: секреты в окружении, но НЕ в командной строке ──────────────────
# Заглушку кладём в ~/.local/bin подставного HOME, а не просто в PATH: resolve
# ставит "$HOME/.local/bin" В НАЧАЛО PATH, и настоящий claude иначе перебьёт
# заглушку. Заодно проверяется именно тот путь поиска, что работает в бою.
export HOME="$TMP/home"
mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/claude" <<'EOF'
#!/usr/bin/env bash
# Подставной движок: печатает свою cmdline и интересующее нас окружение.
echo "CMDLINE:$(tr '\0' ' ' < /proc/$$/cmdline)"
# Родитель нужен для проверки exec: если обёртка не сделала exec, она осталась
# висеть отдельным процессом и видна здесь как ppid.
echo "PARENT:$(tr '\0' ' ' < "/proc/$PPID/cmdline")"
echo "ENV_TOKEN:${TELEGRAM_BOT_TOKEN:-}"
echo "ENV_BEARER:${AGENT_BEARER:-}"
echo "ENV_GROQ:${GROQ_API_KEY:-}"
echo "ENV_WHTOK:${TELEGRAM_WEBHOOK_TOKEN:-}"
EOF
chmod +x "$HOME/.local/bin/claude"

OUT="$(bash "$ORCH/session-exec.sh" "$AGENT" 2>/dev/null)"

# 5. Окружение доехало полностью.
printf '%s' "$OUT" | grep -q "ENV_TOKEN:$TOK"     || fail "бот-токен не доехал до процесса через окружение"
printf '%s' "$OUT" | grep -q "ENV_BEARER:$BEARER" || fail "bearer не доехал до процесса через окружение"
printf '%s' "$OUT" | grep -q "ENV_GROQ:$GROQ"     || fail "ключ groq не доехал до процесса через окружение"
printf '%s' "$OUT" | grep -q "ENV_WHTOK:$WHTOK"   || fail "webhook-токен не доехал до процесса через окружение"

# 6. И ни одного из них нет в командной строке — ради этого всё и затевалось.
CMDLINE="$(printf '%s' "$OUT" | grep '^CMDLINE:')"
for secret in "$TOK" "$BEARER" "$GROQ" "$WHTOK"; do
  case "$CMDLINE" in
    *"$secret"*) fail "секрет виден в командной строке процесса: $CMDLINE" ;;
  esac
done

# 7. Панель обязана СТАТЬ claude (exec), иначе pane_pid укажет на обёртку и мимо
#    промахнутся и детектор дрейфа версии, и снятие агента. Смотреть надо на
#    РОДИТЕЛЯ: в собственной cmdline дочернего процесса обёртки не видно никогда,
#    сделан exec или нет.
printf '%s' "$OUT" | grep '^PARENT:' | grep -q "session-exec.sh" \
  && fail "session-exec.sh не сделал exec — обёртка осталась отдельным процессом"

echo "OK: agent-env.sh + session-exec.sh — 7 проверок пройдено"
