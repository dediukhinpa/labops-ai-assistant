#!/usr/bin/env bash
# openai-adapter-wire.sh - переводит ОДНОГО агента на модели OpenAI через адаптер (LiteLLM).
# Архитектуру не трогает: меняются только три файла самого агента, исходные сохраняются.
#
#   bash orchestration/openai-adapter-wire.sh <агент>             перевести на адаптер
#   bash orchestration/openai-adapter-wire.sh <агент> --revert    вернуть как было
#
# Что меняется (установку самого адаптера делает openai-adapter-install.sh):
#   <агент>/.claude/settings.json          "model" = имя модели OpenAI
#   <агент>/.claude/secrets/pii-proxy.env  PII_PROXY_UPSTREAM = адаптер вместо api.anthropic.com
#   channel.env агента                     ANTHROPIC_AUTH_TOKEN = локальный ключ шлюза
# Токен нужен, чтобы Claude Code не отправлял на шлюз OAuth-токен подписки Claude.
# Без pii-proxy (нет его env-файла) вместо UPSTREAM в settings.json пишется
# ANTHROPIC_BASE_URL на адаптер.
#
# Перезапуск агента (sudo systemctl restart claude-agent-<агент>.service) скрипт НЕ делает:
# это решает оператор. Модель, токен и upstream вступят в силу после него.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_LAB="${CLAUDE_LAB:-$HOME/.claude-lab}"
export CLAUDE_LAB
# shellcheck source=lib/agents.sh
. "$HERE/lib/agents.sh"
# shellcheck source=lib/ui.sh
. "$HERE/lib/ui.sh"

SYSTEMCTL="${WIRE_SYSTEMCTL:-systemctl}"
ADAPTER_HOST="127.0.0.1"
BACKUP_NAME="backup-openai-adapter"

AGENT="${1:?использование: openai-adapter-wire.sh <агент> [--revert]}"
MODE="${2:-wire}"
[[ "$AGENT" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || die "недопустимое имя агента: $AGENT"
case "$MODE" in wire|--revert) ;; *) die "неизвестный аргумент: $MODE" ;; esac

WS="$CLAUDE_LAB/$AGENT/.claude"
SETTINGS="$WS/settings.json"
PII_ENV="$WS/secrets/pii-proxy.env"
SHARED_ENV="$CLAUDE_LAB/shared/secrets/openai-adapter.env"
BACKUP_DIR="$WS/$BACKUP_NAME"
CHANNEL_ENV="$(agent_channel_env "$AGENT" 2>/dev/null || true)"

[ -f "$SETTINGS" ] || die "нет $SETTINGS - сначала создайте агента"

# backup_once <файл> - копия оригинала при первом запуске; повторный не затирает оригинал.
backup_once() {
  local f="$1" name
  [ -f "$f" ] || return 0
  name="$(printf '%s' "$f" | tr '/' '_')"
  mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
  [ -e "$BACKUP_DIR/$name" ] || cp -p "$f" "$BACKUP_DIR/$name"
}

restart_pii() {
  [ -f "$PII_ENV" ] || return 0
  XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" \
    "$SYSTEMCTL" --user restart "labops-pii-proxy@$AGENT.service" \
    || warn "pii-proxy не перезапущен вручную: systemctl --user restart labops-pii-proxy@$AGENT"
}

# set_env_line <файл> <ключ> <значение> - заменяет или добавляет KEY=VALUE, права 600.
# Значение идёт через окружение, не через argv.
set_env_line() {
  KEY="$2" VALUE="$3" python3 -I - "$1" <<'PY'
import os, sys
path, key, value = sys.argv[1], os.environ["KEY"], os.environ["VALUE"]
lines = open(path, encoding="utf-8").read().splitlines() if os.path.exists(path) else []
out, done = [], False
for ln in lines:
    if ln.startswith(key + "="):
        if not done:
            out.append(f"{key}={value}")
        done = True
    else:
        out.append(ln)
if not done:
    out.append(f"{key}={value}")
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w", encoding="utf-8") as f:
    f.write("\n".join(out) + "\n")
os.chmod(path, 0o600)
PY
}

# patch_settings <модель> <base_url|""> - "model" и, без pii-proxy, ANTHROPIC_BASE_URL.
patch_settings() {
  MODEL="$1" BASE_URL="$2" python3 -I - "$SETTINGS" <<'PY'
import json, os, sys
path = sys.argv[1]
cfg = json.load(open(path, encoding="utf-8"))
cfg["model"] = os.environ["MODEL"]
if os.environ["BASE_URL"]:
    cfg.setdefault("env", {})["ANTHROPIC_BASE_URL"] = os.environ["BASE_URL"]
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
    f.write("\n")
os.chmod(tmp, os.stat(path).st_mode & 0o777)
os.replace(tmp, path)
PY
}

if [ "$MODE" = "--revert" ]; then
  [ -d "$BACKUP_DIR" ] || die "нет бэкапа $BACKUP_DIR - возвращать нечего"
  for f in "$SETTINGS" "$PII_ENV" "$CHANNEL_ENV"; do
    [ -n "$f" ] || continue
    name="$(printf '%s' "$f" | tr '/' '_')"
    [ -e "$BACKUP_DIR/$name" ] && cp -p "$BACKUP_DIR/$name" "$f" && ok "восстановлен: $f"
  done
  restart_pii
  note "перезапустите агента: sudo systemctl restart claude-agent-$AGENT.service"
  exit 0
fi

[ -r "$SHARED_ENV" ] || die "нет $SHARED_ENV - сначала установите адаптер: install.sh --openai-adapter"
TOKEN="$(sed -n 's/^ANTHROPIC_AUTH_TOKEN=//p' "$SHARED_ENV")"
MODEL="$(sed -n 's/^LABOPS_OPENAI_MODEL=//p' "$SHARED_ENV")"
PORT="$(sed -n 's/^LABOPS_LLM_PORT=//p' "$SHARED_ENV")"
[ -n "$TOKEN" ] && [ -n "$MODEL" ] && [ -n "$PORT" ] || die "$SHARED_ENV неполный (нужны токен, модель, порт)"
[ -n "$CHANNEL_ENV" ] || die "у агента $AGENT нет channel.env - токен шлюза некуда записать"
ADAPTER_URL="http://$ADAPTER_HOST:$PORT"

say "Перевод агента $AGENT на OpenAI ($MODEL)"
backup_once "$SETTINGS"; backup_once "$PII_ENV"; backup_once "$CHANNEL_ENV"
ok "исходные файлы сохранены: $BACKUP_DIR"

if [ -f "$PII_ENV" ]; then
  set_env_line "$PII_ENV" PII_PROXY_UPSTREAM "$ADAPTER_URL"
  patch_settings "$MODEL" ""
  ok "pii-proxy теперь передаёт запросы адаптеру: $ADAPTER_URL"
else
  patch_settings "$MODEL" "$ADAPTER_URL"
  warn "у агента нет pii-proxy - маскирования персональных данных нет, запросы идут напрямую в адаптер"
fi
set_env_line "$CHANNEL_ENV" ANTHROPIC_AUTH_TOKEN "$TOKEN"
ok "settings.json: model=$MODEL; ключ шлюза записан в $CHANNEL_ENV"
restart_pii
note "перезапустите агента: sudo systemctl restart claude-agent-$AGENT.service"
note "вернуть всё обратно: bash orchestration/openai-adapter-wire.sh $AGENT --revert"
