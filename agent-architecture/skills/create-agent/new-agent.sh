#!/usr/bin/env bash
#
# new-agent.sh — end-to-end создание нового labops-агента.
#
# Доводит до РАБОЧЕГО агента: воркспейс (agent-template) + второй мозг (токен)
# + Telegram-канал (бот) + голос (groq) + автостарт (systemd/watchdog) + smoke.
#
# Используется скиллом create-agent (см. SKILL.md). Можно запускать и напрямую.
#
# Зависимости (репозитории labops):
#   • labops-second-brain   — общий мозг (для выдачи токена агенту)
#   • labops-tg-plugin      — Telegram-канал (бот, голос, реакции)
#
# Переменные (любую можно передать заранее — тогда без вопроса):
#   AGENT_NAME AGENT_ROLE AGENT_ROLE_DESCRIPTION CHARACTER_TRAITS
#   PRIMARY_MODEL OPERATOR_NAME OPERATOR_ADDRESS TIMEZONE LANGUAGE
#   MCP_HOST (default: 127.0.0.1, colocated) AGENT_SCOPES
#   SECOND_BRAIN_MEMORY_URL/_MEMORY_ROUTER_URL/_AGENT_ROUTER_URL (override for remote/reverse-proxy)
#   TELEGRAM_BOT_TOKEN TELEGRAM_ALLOWED_USER_IDS
#   ENABLE_VOICE(=1) AUTOSTART(=1)
#   SECOND_BRAIN_DIR (для авто-выдачи токена)  TG_PLUGIN_DIR  CLAUDE_LAB

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SKILL_DIR/../.." && pwd)"
LAB_DIR="${CLAUDE_LAB:-$HOME/.claude-lab}"
AGENT_TEMPLATE="$REPO_DIR/agent-template"
ORCH_DIR="$REPO_DIR/orchestration"
# Нативный claude ставится в ~/.local/bin, но PATH туда правится только в
# ~/.bashrc — при запуске не-login шеллом (sudo -u ... -H bash ...) это не
# подхватывается. Подмешиваем явно, чтобы claude находился и здесь, и в
# smoke-проверках (шаг 7) ниже.
export PATH="$HOME/.local/bin:$PATH"

C='\033[0;36m'; G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; B='\033[1m'; N='\033[0m'
say()  { printf "\n${C}▶ %s${N}\n" "$*"; }
ok()   { printf "${G}✓ %s${N}\n" "$*"; }
warn() { printf "${Y}⚠ %s${N}\n" "$*"; }
die()  { printf "${R}✗ %s${N}\n" "$*" >&2; exit 1; }
ask()  { local __v="$1" __l="$2" __d="${3:-}" __i; if [ -n "${!__v:-}" ]; then return; fi
         printf "${C}[?]${N} %s%s: " "$__l" "${__d:+ [$__d]}"; read -r __i; printf -v "$__v" '%s' "${__i:-$__d}"; }

echo "════════════════════════════════════════════"
echo "  labops · создание нового агента (end-to-end)"
echo "════════════════════════════════════════════"

# Что деградировало (агент создан, но часть функций недоступна) — печатаем в конце.
DEGRADED=()

# ── 0. Зависимости ──────────────────────────────────────────────
say "0. Проверка зависимостей"
[ -d "$AGENT_TEMPLATE" ] || die "agent-template не найден: $AGENT_TEMPLATE"
command -v curl >/dev/null || die "нужен curl"
command -v tmux >/dev/null || die "нужен tmux (рантайм агента живёт в tmux-сессии): apt-get install tmux"
command -v jq   >/dev/null || warn "jq не найден — smoke-проверки будут грубее"
# Claude Code должен быть авторизован к модели (подписка Max/Pro).
# Без этого агент стартует под systemd, но не достучится до модели.
if command -v claude >/dev/null 2>&1; then
  ok "claude в PATH"
  echo "    Если агент ещё не авторизован — выполните разово (под пользователем агента):"
  echo "      claude --dangerously-skip-permissions        # войдите по ссылке в браузере, затем /exit"
else
  warn "claude не в PATH — поставьте: curl -fsSL https://claude.ai/install.sh | bash, затем 'claude --dangerously-skip-permissions'"
fi
# Персистентная tmux-сессия агента (start-agent.sh запускает "claude
# --dangerously-skip-permissions", БЕЗ -p) проверяет ~/.claude/.credentials.json
# и НЕ читает CLAUDE_CODE_OAUTH_TOKEN — подтверждено эмпирически. headless-путь
# (claude setup-token / claude -p) нигде в этой архитектуре не используется —
# все Claude-вызовы остаются в подписке. Файл на уровне $HOME (не на агента) —
# один вход на пользователя обслуживает всех его агентов, но здесь его не хватает.
if [ -f "$HOME/.claude/.credentials.json" ]; then
  ok "полноценная сессия Claude Code авторизована (\$HOME/.claude/.credentials.json)"
else
  warn "нет \$HOME/.claude/.credentials.json — tmux-сессия агента упрётся в экран логина"
  DEGRADED+=("нет полноценного входа в Claude Code (\$HOME/.claude/.credentials.json) — агент под systemd не подключится к модели; выполните разово: claude --dangerously-skip-permissions (войдите по ссылке, затем /exit)")
fi

TG_PLUGIN_DIR="${TG_PLUGIN_DIR:-}"
for cand in "$TG_PLUGIN_DIR" "$HOME/labops-tg-plugin" "$LAB_DIR/shared/plugins/labops-tg-plugin" "$LAB_DIR/shared/plugins/labops-channel"; do
  [ -n "$cand" ] && [ -d "$cand/plugin" ] && TG_PLUGIN_DIR="$cand" && break
done
[ -n "$TG_PLUGIN_DIR" ] && ok "labops-tg-plugin: $TG_PLUGIN_DIR" || warn "labops-tg-plugin не найден — Telegram пропущу (задайте TG_PLUGIN_DIR)"

# ── 1. Параметры агента ─────────────────────────────────────────
say "1. Конфигурация агента"
ask AGENT_NAME  "Имя агента (напр. Developer, Friday)" "Developer"
ask AGENT_ROLE  "Роль агента" "Разработчик"
ask AGENT_ROLE_DESCRIPTION "Описание роли одной фразой" "Автономный разработчик: пишет код, ревьюит архитектуру, гоняет тесты, помогает ставить других агентов."
AGENT_ID=$(echo "$AGENT_NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
[[ "$AGENT_ID" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || die "имя: только латиница/цифры/дефис, ≤31"
# Идемпотентность: не затираем уже существующего агента молча.
if [ -d "$LAB_DIR/$AGENT_ID/.claude" ] && [ "${REUSE_EXISTING:-0}" != "1" ]; then
  die "агент '$AGENT_ID' уже существует ($LAB_DIR/$AGENT_ID/.claude). Выберите другое имя, либо REUSE_EXISTING=1 чтобы донастроить поверх (существующие файлы не перезапишутся)."
fi
ask PRIMARY_MODEL    "Модель Anthropic — opus / sonnet / haiku (Developer рекоменд.: opus = Opus 4.8)" "opus"
ask LANGUAGE         "Язык ответов" "Russian"
ask OPERATOR_ADDRESS "Как обращаться к вам" "Boss"
# Второй мозг всегда колоцирован на этом же VPS, без reverse proxy — прямые
# host:port URL на дефолтных портах, без вопроса. Переопределяется через
# MCP_HOST (другой хост) или напрямую SECOND_BRAIN_*_URL (напр. свой домен+proxy).
: "${MCP_HOST:=127.0.0.1}"
MCP_HOST="${MCP_HOST%/}"
: "${MCP_MEMORY_PORT:=5001}"
: "${MCP_MEMORY_ROUTER_PORT:=5002}"
: "${MCP_AGENT_ROUTER_PORT:=5000}"
: "${SECOND_BRAIN_MEMORY_URL:=http://${MCP_HOST}:${MCP_MEMORY_PORT}/mcp}"
: "${SECOND_BRAIN_MEMORY_ROUTER_URL:=http://${MCP_HOST}:${MCP_MEMORY_ROUTER_PORT}/mcp}"
: "${SECOND_BRAIN_AGENT_ROUTER_URL:=http://${MCP_HOST}:${MCP_AGENT_ROUTER_PORT}/mcp}"
: "${AGENT_SCOPES:=decisions,external,knowledge,inbox}"

# ── 2. Токен второго мозга ──────────────────────────────────────
say "2. Токен во втором мозге"
# Валидируем в отдельную переменную и присваиваем результат ПОСЛЕ цикла —
# если SECOND_BRAIN_DIR пришёл предустановленным (напр. из install.sh,
# который экспортирует путь клонированного репо, не проверяя venv), а ни
# один кандидат не прошёл проверку, SECOND_BRAIN_DIR должен стать пустым,
# а не тихо остаться на невалидном значении.
_SB_FOUND=""
for cand in "${SECOND_BRAIN_DIR:-}" /opt/second_brain "$HOME/labops-second-brain"; do
  if [ -n "$cand" ] && [ -x "$cand/.venv/bin/python" ] && [ -f "$cand/scripts/issue-agent-token.py" ]; then
    _SB_FOUND="$cand"
    break
  fi
done
SECOND_BRAIN_DIR="$_SB_FOUND"
if [ -z "${AGENT_BEARER:-}" ] && [ -n "$SECOND_BRAIN_DIR" ]; then
  ok "Выдаю токен через $SECOND_BRAIN_DIR/scripts/issue-agent-token.py"
  AGENT_BEARER="$("$SECOND_BRAIN_DIR/.venv/bin/python" "$SECOND_BRAIN_DIR/scripts/issue-agent-token.py" \
                  --agent "$AGENT_ID" --scopes "$AGENT_SCOPES" 2>/dev/null | tail -1)" \
    || warn "не удалось выдать токен автоматически"
fi
if [ -z "${AGENT_BEARER:-}" ]; then
  if [ -n "$SECOND_BRAIN_DIR" ]; then
    # second_brain установлен локально, но автовыдача не сработала — токен
    # мог быть выдан вручную на другом хосте, есть смысл спросить.
    ask AGENT_BEARER "Bearer-токен агента (issue-agent-token.py на VPS мозга)" "CHANGE_ME"
  else
    # second_brain не найден вообще — это ожидаемо при первой установке
    # (second_brain по канону ставится третьим репозиторием). Не варн, не
    # DEGRADED — просто ставим плейсхолдер, это не "дыра", а штатный порядок.
    AGENT_BEARER="CHANGE_ME"
  fi
fi
if [ "$AGENT_BEARER" = "CHANGE_ME" ] && [ -n "$SECOND_BRAIN_DIR" ]; then
  # А вот это уже нештатно: second_brain НАЙДЕН локально, но токен всё равно
  # не выдался (ни авто, ни вручную на вопрос) — стоит явно подсветить.
  DEGRADED+=("нет реального Bearer-токена (second_brain найден в $SECOND_BRAIN_DIR, но токен не выдался) — выполните: python $SECOND_BRAIN_DIR/scripts/issue-agent-token.py --agent $AGENT_ID --scopes '$AGENT_SCOPES', впишите токен в $LAB_DIR/$AGENT_ID/.claude/agent.env (AGENT_BEARER=...) и перезапустите сервис агента")
fi

# ── 3. Скаффолд воркспейса (agent-template, неинтерактивно) ──────
say "3. Скаффолд воркспейса"
NONINTERACTIVE=1 AGENT_NAME="$AGENT_NAME" AGENT_ROLE="$AGENT_ROLE" \
  AGENT_ROLE_DESCRIPTION="$AGENT_ROLE_DESCRIPTION" LANGUAGE="$LANGUAGE" \
  PRIMARY_MODEL="$PRIMARY_MODEL" \
  OPERATOR_ADDRESS="$OPERATOR_ADDRESS" MCP_HOST="$MCP_HOST" \
  SECOND_BRAIN_MEMORY_URL="$SECOND_BRAIN_MEMORY_URL" \
  SECOND_BRAIN_MEMORY_ROUTER_URL="$SECOND_BRAIN_MEMORY_ROUTER_URL" \
  SECOND_BRAIN_AGENT_ROUTER_URL="$SECOND_BRAIN_AGENT_ROUTER_URL" \
  AGENT_BEARER="$AGENT_BEARER" AGENT_SCOPES="$AGENT_SCOPES" \
  bash "$AGENT_TEMPLATE/install.sh"
WORKSPACE="$LAB_DIR/$AGENT_ID/.claude"
[ -d "$WORKSPACE" ] || die "воркспейс не создан: $WORKSPACE"
ok "воркспейс: $WORKSPACE"

# ── 4. Telegram-канал (бот) ─────────────────────────────────────
say "4. Telegram-канал"
if [ -n "$TG_PLUGIN_DIR" ]; then
  STATE_DIR="$LAB_DIR/shared/state/$AGENT_ID/telegram"
  CH_ENV="$STATE_DIR/channel.env"
  if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] && grep -qs '^TELEGRAM_BOT_TOKEN=.\+' "$CH_ENV" 2>/dev/null; then
    # У этого агента уже есть рабочий channel.env (напр. REUSE_EXISTING=1
    # донастройка) — не переспрашиваем токен и не трогаем файл, чтобы не
    # сдвинуть webhook-порт (см. ниже) и не заставлять вводить токен заново.
    ok "Telegram: channel.env уже настроен ($CH_ENV) — переиспользую как есть"
    if [ ! -e "$WORKSPACE/labops-tg-plugin" ]; then
      ln -s "$TG_PLUGIN_DIR" "$WORKSPACE/labops-tg-plugin" && ok "плагин слинкован в воркспейс"
    fi
  else
  if [ -z "${TELEGRAM_BOT_TOKEN:-}" ]; then
    echo "  Нужен отдельный Telegram-бот для этого агента. Если ещё нет:"
    echo "   1) В Telegram откройте @BotFather → /newbot → задайте имя и @username"
    echo "   2) Скопируйте выданный токен (вид 123456789:AAH... — это секрет)"
    echo "   3) Свой user_id узнайте у @userinfobot (число). Для групп chat_id"
    echo "      отрицательный и начинается с -100."
  fi
  ask TELEGRAM_BOT_TOKEN "Токен Telegram-бота (@BotFather → /newbot)" ""
  if [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
    ask TELEGRAM_ALLOWED_USER_IDS "Ваш Telegram user_id (у @userinfobot)" ""
    [ -n "${TELEGRAM_ALLOWED_USER_IDS:-}" ] || DEGRADED+=("allowlist пуст: бот будет отвечать ВСЕМ — впишите user_id в channel.env")
    BOT_ID="${TELEGRAM_BOT_TOKEN%%:*}"
    # Уникальный webhook-порт: если у ЭТОГО агента уже был channel.env (напр.
    # обновление токена при REUSE_EXISTING=1) — берём его же порт, а не ищем
    # новый (иначе порт агента "уезжает" при каждой донастройке). Иначе —
    # первый свободный от 6000.
    if [ -z "${TELEGRAM_WEBHOOK_PORT:-}" ]; then
      TELEGRAM_WEBHOOK_PORT="$(grep -oP '^TELEGRAM_WEBHOOK_PORT=\K[0-9]+' "$CH_ENV" 2>/dev/null || true)"
    fi
    if [ -z "${TELEGRAM_WEBHOOK_PORT:-}" ]; then
      TELEGRAM_WEBHOOK_PORT=6000
      while grep -rqsE "^TELEGRAM_WEBHOOK_PORT=${TELEGRAM_WEBHOOK_PORT}\$" "$LAB_DIR"/shared/state/*/telegram/channel.env 2>/dev/null; do
        TELEGRAM_WEBHOOK_PORT=$((TELEGRAM_WEBHOOK_PORT+1))
      done
    fi
    mkdir -p "$STATE_DIR"
    umask 077
    cat > "$CH_ENV" <<ENV
TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN
TELEGRAM_EXPECTED_BOT_ID=$BOT_ID
TELEGRAM_ALLOWED_USER_IDS=${TELEGRAM_ALLOWED_USER_IDS:-}
TELEGRAM_ALLOWED_CHAT_IDS=${TELEGRAM_ALLOWED_USER_IDS:-}
TELEGRAM_WORKSPACE_ROOT=$WORKSPACE
AGENT_ID=$AGENT_ID
TELEGRAM_STATE_DIR=$STATE_DIR
TELEGRAM_WEBHOOK_HOST=127.0.0.1
TELEGRAM_WEBHOOK_PORT=${TELEGRAM_WEBHOOK_PORT:-6000}
TELEGRAM_MEMORY_ENABLED=true
TELEGRAM_MEMORY_WORKSPACE=$WORKSPACE
TELEGRAM_MEMORY_AGENT_LABEL=$AGENT_NAME
TELEGRAM_MEMORY_SOURCE_TAG=tg
ENV
    chmod 600 "$CH_ENV"
    ok "channel.env: $CH_ENV (chmod 600)"
    # привязать плагин в воркспейс (расположение важно — см. docs tg-plugin)
    if [ ! -e "$WORKSPACE/labops-tg-plugin" ]; then
      ln -s "$TG_PLUGIN_DIR" "$WORKSPACE/labops-tg-plugin" && ok "плагин слинкован в воркспейс"
    fi
  else
    warn "токен бота не задан — Telegram пропущен (агент пока без чата)"
    DEGRADED+=("Telegram не настроен (нет токена) — агент текстовый только локально, в чат не пишет")
  fi
  fi

  # Внутренний HTTP-эндпойнт плагина (/hooks/agent) — то, чем agent-to-agent
  # задачи (second_brain webhook) кладутся прямо в уже запущенную сессию, без
  # спавна отдельного claude-процесса (см. webhook-listener в labops-tg-plugin).
  # Выключен по умолчанию (config.webhook.enabled=false, только через
  # config.json — ENV его не переключает) и требует TELEGRAM_WEBHOOK_TOKEN —
  # ни то, ни другое channel.env выше не пишет. Добавляем отдельно и
  # идемпотентно: не трогаем уже сгенерированный токен при повторном запуске
  # (REUSE_EXISTING=1), работает и для уже настроенного, и для свежего agent.env.
  if [ -f "$CH_ENV" ]; then
    if ! grep -qs '^TELEGRAM_WEBHOOK_TOKEN=.\+' "$CH_ENV"; then
      WEBHOOK_TOKEN_VAL="$(openssl rand -hex 32 2>/dev/null \
        || python3 -c 'import secrets; print(secrets.token_hex(32))' 2>/dev/null \
        || od -An -tx1 -N32 /dev/urandom | tr -d ' \n')"
      umask 077
      printf 'TELEGRAM_WEBHOOK_TOKEN=%s\n' "$WEBHOOK_TOKEN_VAL" >> "$CH_ENV"
      ok "TELEGRAM_WEBHOOK_TOKEN сгенерирован и добавлен в $CH_ENV"
    fi
    # webhook-listener (labops-tg-plugin, отдельный Python-процесс) читает
    # секрет как плоский файл (та же схема, что WEBHOOK_BEARER_FILE и т.п.),
    # не парсит channel.env — дублируем значение туда же, идемпотентно.
    WEBHOOK_TOKEN_FILE="$STATE_DIR/webhook-token"
    if [ ! -f "$WEBHOOK_TOKEN_FILE" ]; then
      umask 077
      grep -oP '^TELEGRAM_WEBHOOK_TOKEN=\K.+' "$CH_ENV" > "$WEBHOOK_TOKEN_FILE"
      chmod 600 "$WEBHOOK_TOKEN_FILE"
      ok "webhook-token (плоский файл для webhook-listener): $WEBHOOK_TOKEN_FILE"
    fi
    CONFIG_JSON="$STATE_DIR/config.json"
    if [ ! -f "$CONFIG_JSON" ]; then
      umask 077
      printf '{"webhook": {"enabled": true}}\n' > "$CONFIG_JSON"
      ok "config.json: webhook.enabled=true ($CONFIG_JSON)"
    elif command -v jq >/dev/null 2>&1; then
      if [ "$(jq -r '.webhook.enabled // false' "$CONFIG_JSON" 2>/dev/null)" != "true" ]; then
        TMP_CFG="$(mktemp)"
        jq '.webhook.enabled = true' "$CONFIG_JSON" > "$TMP_CFG" && mv "$TMP_CFG" "$CONFIG_JSON"
        ok "config.json: webhook.enabled=true обновлён ($CONFIG_JSON)"
      fi
    else
      warn "config.json уже существует и jq недоступен — проверьте вручную, что webhook.enabled=true в $CONFIG_JSON"
    fi
  fi
else
  warn "tg-plugin недоступен — пропускаю Telegram"
  DEGRADED+=("labops-tg-plugin не установлен — у агента НЕТ Telegram-чата; поставьте репозиторий и перезапустите этот шаг")
fi

# ── 5. Голос (groq-voice) ───────────────────────────────────────
say "5. Голос"
ENABLE_VOICE="${ENABLE_VOICE:-1}"
if [ "$ENABLE_VOICE" = "1" ]; then
  GROQ_FILE="$LAB_DIR/shared/secrets/groq-api-key"
  if [ -f "$GROQ_FILE" ] || [ -n "${GROQ_API_KEY:-}" ]; then
    ok "groq-voice: ключ найден — голосовые будут транскрибироваться"
  else
    ask GROQ_API_KEY "Groq API key для голосовых (console.groq.com/keys, пусто — пропустить)" ""
    if [ -n "${GROQ_API_KEY:-}" ]; then
      mkdir -p "$(dirname "$GROQ_FILE")"
      umask 077
      printf '%s' "$GROQ_API_KEY" > "$GROQ_FILE"
      chmod 600 "$GROQ_FILE"
      ok "groq-voice: ключ сохранён в $GROQ_FILE — голосовые будут транскрибироваться"
    else
      warn "нет GROQ_API_KEY — голос подключится позже, текст работает сразу"
      DEGRADED+=("голос выключен (нет GROQ_API_KEY) — голосовые не транскрибируются, текст работает; положите ключ в $GROQ_FILE позже")
    fi
  fi
fi

# ── 6. Автостарт (systemd + watchdog) ───────────────────────────
say "6. Автостарт"
AUTOSTART="${AUTOSTART:-1}"
UNIT_TMPL="$REPO_DIR/systemd/claude-agent.service.template"
if [ "$AUTOSTART" = "1" ] && [ -f "$UNIT_TMPL" ]; then
  UNIT="/tmp/claude-agent-$AGENT_ID.service"
  sed -e "s|__AGENT__|$AGENT_ID|g" -e "s|__USER__|$(id -un)|g" \
      -e "s|__ORCH__|$ORCH_DIR|g" -e "s|__LAB__|$LAB_DIR|g" "$UNIT_TMPL" > "$UNIT"
  mkdir -p "$LAB_DIR/$AGENT_ID/logs"
  # install.sh выдаёт агент-пользователю узко-scoped NOPASSWD sudo ТОЛЬКО на эти
  # три команды (cp юнита + systemctl daemon-reload/enable --now claude-agent-*).
  # "sudo -n true" тут не подходит как проверка — сам "true" не входит в
  # разрешённый список команд, поэтому пробуем реальные команды напрямую.
  if command -v systemctl >/dev/null 2>&1 \
     && sudo -n cp "$UNIT" "/etc/systemd/system/claude-agent-$AGENT_ID.service" 2>/dev/null \
     && sudo -n systemctl daemon-reload 2>/dev/null \
     && sudo -n systemctl enable --now "claude-agent-$AGENT_ID.service" 2>/dev/null; then
    ok "юнит claude-agent-$AGENT_ID активен"
  else
    warn "нет scoped sudo для systemd claude-agent-* (или нет systemctl) — юнит сгенерирован в $UNIT. Установите вручную:"
    echo "    sudo cp $UNIT /etc/systemd/system/ && sudo systemctl enable --now claude-agent-$AGENT_ID"
    DEGRADED+=("автостарт не включён — агент не поднимется сам после перезагрузки; юнит в $UNIT")
  fi
elif ! [ -f "$UNIT_TMPL" ]; then
  warn "шаблон юнита не найден ($UNIT_TMPL) — автостарт пропущен"
  DEGRADED+=("автостарт пропущен: нет $UNIT_TMPL")
else
  warn "автостарт пропущен (AUTOSTART=0)"
fi

# ── 7. Smoke-тест ───────────────────────────────────────────────
say "7. Smoke-тест"
FAIL=0
# 7a. второй мозг отвечает — только если у нас есть настоящий токен. Без него
# (AGENT_BEARER=CHANGE_ME) запрос гарантированно провалится: либо second_brain
# ещё не установлен (штатно, см. шаг 2 — там уже ничего лишнего не пишем),
# либо найден, но токен не выдался (уже отмечено в DEGRADED). Тут — тихо
# пропускаем, без повторного предупреждения.
if [ "$AGENT_BEARER" = "CHANGE_ME" ]; then
  :
elif curl -fsS -H "Authorization: Bearer $AGENT_BEARER" \
        -H "Accept: application/json, text/event-stream" -H "Content-Type: application/json" \
        -X POST "$SECOND_BRAIN_MEMORY_ROUTER_URL" \
        --data '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' >/dev/null 2>&1; then
  ok "second_brain memory_router отвечает"
else
  warn "second_brain memory_router недоступен на $SECOND_BRAIN_MEMORY_ROUTER_URL (проверьте токен/хост)"; FAIL=1
fi
# 7b. Telegram-бот валиден
if [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
  if curl -fsS "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/getMe" 2>/dev/null | grep -q '"ok":true'; then
    ok "Telegram getMe: токен рабочий"
  else
    warn "Telegram getMe не прошёл — проверьте токен"; FAIL=1
  fi
fi
# 7c. сессия поднимается
if [ "${AUTOSTART:-1}" = "1" ] && command -v systemctl >/dev/null; then
  systemctl is-active --quiet "claude-agent-$AGENT_ID.service" && ok "сервис активен" || { warn "сервис не active"; FAIL=1; }
fi
# 7d. полноценная сессия (то, что реально запускает start-agent.sh) авторизована.
# Никакого claude -p здесь: headless-вызовы бьют по отдельному SDK-credit
# биллингу вне подписки, поэтому automation их не использует нигде — см.
# комментарий в шаге 0.
if [ -f "$HOME/.claude/.credentials.json" ]; then
  ok "сессия авторизована (\$HOME/.claude/.credentials.json) — tmux-агент подключится к модели"
else
  warn "нет \$HOME/.claude/.credentials.json — tmux-сессия агента не подключится к модели"; FAIL=1
fi
# 7e. плагин (сам работающий claude-процесс) реально поднял внутренний
# /hooks/agent — чисто сетевая проверка, без единого вызова claude.
if [ -n "${TELEGRAM_WEBHOOK_PORT:-}" ]; then
  if curl -fsS "http://127.0.0.1:${TELEGRAM_WEBHOOK_PORT}/health" >/dev/null 2>&1; then
    ok "плагин слушает /hooks/agent на :${TELEGRAM_WEBHOOK_PORT} (agent-to-agent доставка готова)"
  else
    warn "плагин не отвечает на :${TELEGRAM_WEBHOOK_PORT}/health — agent-to-agent webhook недоступен (проверьте сервис)"; FAIL=1
  fi
fi

echo
if [ "$FAIL" = "0" ] && [ "${#DEGRADED[@]}" -eq 0 ]; then
  printf "${G}✅ Агент '%s' (%s) готов и полностью рабочий. Напишите ему в Telegram.${N}\n" "$AGENT_NAME" "$AGENT_ID"
elif [ "$FAIL" = "0" ]; then
  printf "${Y}⚠ Агент '%s' (%s) создан, но НЕ всё включено:${N}\n" "$AGENT_NAME" "$AGENT_ID"
else
  printf "${Y}⚠ Агент '%s' создан, но часть smoke-проверок не прошла — см. предупреждения выше.${N}\n" "$AGENT_NAME"
fi
# Явно перечисляем, что деградировало — чтобы «зелёная» установка не скрыла дыры.
if [ "${#DEGRADED[@]}" -gt 0 ]; then
  printf "${Y}   Что НЕ работает / не настроено:${N}\n"
  for d in "${DEGRADED[@]}"; do printf "     • %s\n" "$d"; done
fi
printf "   Воркспейс: ${B}%s${N}\n" "$WORKSPACE"
printf "   Запуск вручную:\n     ${B}source %s/agent.env && claude --project %s${N}\n" "$WORKSPACE" "$WORKSPACE"
