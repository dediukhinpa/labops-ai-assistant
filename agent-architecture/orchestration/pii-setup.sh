#!/usr/bin/env bash
# pii-setup.sh — установка маскирования ПДн (pseudonymizer + pii-proxy) для агентов роя.
#
#   pii-setup.sh host            # один раз на хост: сервис псевдонимизации
#   pii-setup.sh agent <agent>   # на каждого агента: свой pii-proxy + settings.json
#
# Зачем: агент должен ходить в модель ТОЛЬКО через локальный pii-proxy, иначе ПДн уходят
# провайдеру немаскированными (152-ФЗ). По умолчанию включено; отключение - SKIP_PII_PROXY=1
# (громкое предупреждение, ответственность на операторе). Идемпотентно.
#
# Развёртка - user-юниты systemd (без root, как на образцовом агенте developer). Они переживают
# перезагрузку только при linger (loginctl enable-linger); если не вышло - предупреждаем,
# а watchdog при каждом старте агента сам пытается поднять прокси (fail closed, см. watchdog.sh).
#
# Переменные (для тестов и нестандартных хостов):
#   PII_SRC_DIR       корень монорепо с pii-proxy/ и pseudonymizer/ (по умолчанию - рядом)
#   PII_RUNTIME_DIR   рабочая копия кода (по умолчанию ~/labops-pii-runtime)
#   PII_CONFIG_DIR    секреты сервиса (по умолчанию ~/.config/labops-pii)
#   PII_UNIT_DIR      каталог user-юнитов (по умолчанию ~/.config/systemd/user)
#   PII_SYSTEMCTL     команда systemctl (в тестах - заглушка)
#   PII_SKIP_BUILD=1  не ставить зависимости (bun install, pip) - для тестов
set -euo pipefail

HERE="$(cd "$(dirname "$(realpath "$0")")" && pwd)"
# shellcheck source=lib/ui.sh
. "$HERE/lib/ui.sh"
# shellcheck source=lib/pii.sh
. "$HERE/lib/pii.sh"

SRC_DIR="${PII_SRC_DIR:-$(cd "$HERE/../.." && pwd)}"
RUNTIME_DIR="${PII_RUNTIME_DIR:-$HOME/labops-pii-runtime}"
CONFIG_DIR="${PII_CONFIG_DIR:-$HOME/.config/labops-pii}"
UNIT_DIR="${PII_UNIT_DIR:-$HOME/.config/systemd/user}"
SYSTEMCTL="${PII_SYSTEMCTL:-systemctl}"
# Сколько секунд ждём /health после запуска сервиса.
HEALTH_WAIT_SEC=20
# Пароль HTTP-токена: байт случайности для secrets.token_urlsafe (>= 32 по README сервиса).
TOKEN_BYTES=32

warn_disabled() {
  warn "SKIP_PII_PROXY=1: маскирование ПДн ОТКЛЮЧЕНО - агент пойдёт в модель напрямую,"
  warn "персональные данные уйдут провайдеру модели без псевдонимизации (152-ФЗ)."
  warn "Включить: запускать без SKIP_PII_PROXY."
}

ucmd() {   # systemctl --user с рабочим XDG_RUNTIME_DIR (из sudo/su его может не быть)
  XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" "$SYSTEMCTL" --user "$@"
}

find_bun() {
  local c
  for c in "$(command -v bun 2>/dev/null || true)" "$HOME/.local/bin/bun" "$HOME/.bun/bin/bun"; do
    if [ -n "$c" ] && [ -x "$c" ]; then printf '%s' "$c"; return 0; fi
  done
  return 1
}

find_python() {   # pseudonymizer требует Python >= 3.12
  local c
  for c in python3.12 python3.13 python3; do
    if command -v "$c" >/dev/null 2>&1 \
       && "$c" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 12) else 1)' 2>/dev/null; then
      command -v "$c"; return 0
    fi
  done
  return 1
}

# Копия кода в стабильное место: юниты не должны исполнять код из рабочего checkout, где
# ветки переключают и деревья переносят.
sync_sources() {
  local sub
  mkdir -p "$RUNTIME_DIR"
  for sub in pii-proxy pseudonymizer; do
    [ -d "$SRC_DIR/$sub" ] || die "нет каталога $SRC_DIR/$sub - установка идёт не из монорепо?"
    mkdir -p "$RUNTIME_DIR/$sub"
    (cd "$SRC_DIR/$sub" && tar --exclude=node_modules --exclude=.venv --exclude=__pycache__ \
        --exclude=data -cf - .) | (cd "$RUNTIME_DIR/$sub" && tar -xf -)
  done
}

render_unit() {   # <template> <dest> - подстановка путей
  local tpl="$1" dst="$2" bun_bin="${3:-}"
  mkdir -p "$(dirname "$dst")"
  sed -e "s|__INSTALL_DIR__|${INSTALL_DIR_FOR_UNIT}|g" \
      -e "s|__ENV_FILE__|${ENV_FILE_FOR_UNIT:-}|g" \
      -e "s|__AGENT_HOME__|$(pii_lab)|g" -e "s|__BUN_BIN__|$bun_bin|g" "$tpl" > "$dst"
}

ensure_linger() {
  command -v loginctl >/dev/null 2>&1 || return 0
  if loginctl show-user "$(id -un)" -p Linger 2>/dev/null | grep -q 'Linger=yes'; then return 0; fi
  loginctl enable-linger "$(id -un)" 2>/dev/null \
    || warn "linger не включён: сервисы маскирования не поднимутся после перезагрузки. Выполните: sudo loginctl enable-linger $(id -un)"
}

wait_health() {   # <url> <name>
  local i
  [ "${PII_SKIP_BUILD:-0}" = "1" ] && return 0
  for i in $(seq 1 "$HEALTH_WAIT_SEC"); do
    if pii_proxy_healthy "$1"; then ok "$2: /health отвечает"; return 0; fi
    sleep 1
  done
  warn "$2: /health не ответил за ${HEALTH_WAIT_SEC}с: systemctl --user status ${3:-$2}"
  return 1
}

cmd_host() {
  if ! pii_enabled; then warn_disabled; return 0; fi
  say "Сервис псевдонимизации (один на хост)"
  sync_sources
  local py token_file env_file
  token_file="$CONFIG_DIR/pseudonymizer.token"
  env_file="$CONFIG_DIR/pseudonymizer.env"
  mkdir -p "$CONFIG_DIR"; chmod 700 "$CONFIG_DIR"
  if [ "${PII_SKIP_BUILD:-0}" != "1" ]; then
    py="$(find_python)" || die "нужен Python >= 3.12 для pseudonymizer (apt install python3.12-venv)"
    if [ ! -x "$RUNTIME_DIR/pseudonymizer/.venv/bin/python" ]; then
      step "venv и зависимости pseudonymizer (несколько минут: natasha, pymorphy3)"
      "$py" -m venv "$RUNTIME_DIR/pseudonymizer/.venv"
    fi
    "$RUNTIME_DIR/pseudonymizer/.venv/bin/pip" install -q -e "$RUNTIME_DIR/pseudonymizer"
  fi
  if [ ! -s "$token_file" ]; then
    # Токен общий для сервиса и всех прокси хоста; в argv не попадает.
    umask 077
    python3 -c "import secrets; print(secrets.token_urlsafe($TOKEN_BYTES))" > "$token_file"
    ok "создан токен сервиса: $token_file (600)"
  fi
  chmod 600 "$token_file"
  if [ ! -s "$env_file" ]; then
    umask 077
    {
      echo "PSEUDONYMIZER_API_TOKEN=$(tr -d '\n' < "$token_file")"
      echo "PSEUDONYMIZER_STORE=memory"
      echo "PSEUDONYMIZER_RETENTION_HOURS=24"
      echo "PSEUDONYMIZER_MASK_LEGAL_ENTITY=true"
      echo "PSEUDONYMIZER_HOST=127.0.0.1"
      echo "PSEUDONYMIZER_PORT=8300"
    } > "$env_file"
  fi
  chmod 600 "$env_file"
  INSTALL_DIR_FOR_UNIT="$RUNTIME_DIR/pseudonymizer" ENV_FILE_FOR_UNIT="$env_file" \
    render_unit "$RUNTIME_DIR/pseudonymizer/deploy/pseudonymizer.user.service.template" \
      "$UNIT_DIR/labops-pseudonymizer.service"
  ucmd daemon-reload
  ucmd enable --now labops-pseudonymizer.service \
    || warn "не удалось запустить labops-pseudonymizer (нет systemctl --user?)"
  ensure_linger
  wait_health "$PII_PSEUDONYMIZER_URL_DEFAULT" "pseudonymizer" "labops-pseudonymizer" || true
}

# Идемпотентная правка settings.json агента: ANTHROPIC_BASE_URL и второй SessionEnd-хук.
patch_settings() {   # <settings.json> <url> <agent>
  local hook_cmd
  hook_cmd="AGENT_ID=$3 PSEUDONYMIZER_URL=$PII_PSEUDONYMIZER_URL_DEFAULT"
  hook_cmd+=" PSEUDONYMIZER_TOKEN_FILE=$CONFIG_DIR/pseudonymizer.token"
  hook_cmd+=" bash $RUNTIME_DIR/pii-proxy/hooks/session-end.sh"
  python3 - "$1" "$2" "$hook_cmd" <<'PY'
import json, os, sys
path, url, hook_cmd = sys.argv[1:4]
d = json.load(open(path))
d.setdefault("env", {})["ANTHROPIC_BASE_URL"] = url
# Хук SessionEnd удаляет тред сессии в сервисе: без него таблица замен живёт до срока хранения.
groups = d.setdefault("hooks", {}).setdefault("SessionEnd", [{"matcher": "*", "hooks": []}])
entries = [h for g in groups for h in g.get("hooks", [])]
if not any("pii-proxy/hooks/session-end.sh" in h.get("command", "") for h in entries):
    groups[0].setdefault("hooks", []).append(
        {"type": "command", "timeout": 8, "command": hook_cmd})
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(d, f, indent=2, ensure_ascii=False)
    f.write("\n")
os.replace(tmp, path)
PY
}

cmd_agent() {
  local agent="${1:?использование: pii-setup.sh agent <agent-id>}" env_file port token_file ws settings
  if ! pii_enabled; then warn_disabled; return 0; fi
  [[ "$agent" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || die "недопустимое имя агента: $agent"
  ws="$(pii_lab)/$agent/.claude"
  settings="$ws/settings.json"
  [ -f "$settings" ] || die "нет $settings - сначала создайте воркспейс агента"
  token_file="$CONFIG_DIR/pseudonymizer.token"
  [ -s "$token_file" ] || die "нет токена сервиса ($token_file) - сначала: pii-setup.sh host"
  say "pii-proxy агента $agent"
  env_file="$(pii_proxy_env_file "$agent")"
  mkdir -p "$ws/secrets" "$ws/state"; chmod 700 "$ws/secrets" 2>/dev/null || true
  if [ -s "$env_file" ]; then
    note "env-файл прокси уже есть - оставляю: $env_file"
  else
    port="$(pii_pick_port "$agent")" || die "нет свободного порта в диапазоне ${PII_PROXY_BASE_PORT}+"
    umask 077
    {
      echo "PII_PROXY_PORT=$port"
      echo "PII_PROXY_HOST=127.0.0.1"
      echo "PII_PROXY_UPSTREAM=https://api.anthropic.com"
      echo "PII_PROXY_AGENT_ID=$agent"
      echo "PII_PROXY_ALERT_FILE=$(pii_stuck_file "$agent")"
      echo "PSEUDONYMIZER_URL=$PII_PSEUDONYMIZER_URL_DEFAULT"
      echo "PSEUDONYMIZER_API_TOKEN=$(tr -d '\n' < "$token_file")"
      echo "PSEUDONYMIZER_TIMEOUT_MS=10000"
      echo "PII_PROXY_IMAGE_POLICY=passthrough"
    } > "$env_file"
    ok "env прокси: $env_file (порт $port, 600)"
  fi
  chmod 600 "$env_file"
  port="$(pii_proxy_port "$agent")"
  sync_sources
  if [ "${PII_SKIP_BUILD:-0}" != "1" ] && [ ! -d "$RUNTIME_DIR/pii-proxy/node_modules" ]; then
    (cd "$RUNTIME_DIR/pii-proxy" && "$(find_bun)" install --frozen-lockfile) \
      || die "bun install для pii-proxy не удался (нужен bun в PATH)"
  fi
  INSTALL_DIR_FOR_UNIT="$RUNTIME_DIR/pii-proxy" ENV_FILE_FOR_UNIT="" \
    render_unit "$RUNTIME_DIR/pii-proxy/deploy/pii-proxy@.user.service.template" \
      "$UNIT_DIR/labops-pii-proxy@.service" "$(find_bun || echo bun)"
  ucmd daemon-reload
  ucmd enable --now "labops-pii-proxy@$agent.service" \
    || warn "не удалось запустить labops-pii-proxy@$agent (watchdog попробует сам)"
  # ANTHROPIC_BASE_URL пишем в settings.json ПОСЛЕ создания юнита: если установка оборвётся
  # раньше, агент не окажется настроенным на несуществующий прокси.
  patch_settings "$settings" "http://127.0.0.1:$port" "$agent"
  ok "settings.json: ANTHROPIC_BASE_URL=http://127.0.0.1:$port, хук SessionEnd"
  wait_health "http://127.0.0.1:$port" "pii-proxy $agent" "labops-pii-proxy@$agent" || true
}

case "${1:-}" in
  host)  cmd_host ;;
  agent) shift; cmd_agent "${1:-}" ;;
  *) echo "использование: pii-setup.sh host | agent <agent-id>" >&2; exit 2 ;;
esac
