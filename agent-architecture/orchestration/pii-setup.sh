#!/usr/bin/env bash
# pii-setup.sh — установка маскирования ПДн (сервис псевдонимизации + pii-proxy) для агентов роя.
# Сервис и media-masker - вендоренная библиотека labops-pii (vendor/labops-pii), профиль labops.
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
#   PII_SRC_DIR       корень монорепо с pii-proxy/ и vendor/labops-pii/ (по умолчанию - рядом)
#   PII_RUNTIME_DIR   рабочая копия кода (по умолчанию ~/labops-pii-runtime)
#   PII_CONFIG_DIR    секреты сервиса (по умолчанию ~/.config/labops-pii)
#   PII_UNIT_DIR      каталог user-юнитов (по умолчанию ~/.config/systemd/user)
#   PII_SYSTEMCTL     команда systemctl (в тестах - заглушка)
#   PII_SKIP_BUILD=1  не ставить зависимости (bun install, pip) - для тестов
#   PII_TESSERACT_CMD         путь к tesseract (по умолчанию - из PATH)
#   PII_TESSDATA_PREFIX       каталог языковых данных Tesseract (хост без sudo)
#   PII_TESSERACT_LD_LIBRARY_PATH  LD_LIBRARY_PATH для распакованного без sudo Tesseract
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
# Адрес и порт media-masker (OCR для фото и PDF); 8310 занят voice-transcriber.
MEDIA_MASKER_URL_DEFAULT="http://127.0.0.1:8320"
MEDIA_MASKER_PORT=8320
# Рабочая копия вендоренной библиотеки: labops_pii/ + общий venv сервиса и media-masker.
LIB_NAME="labops-pii"
LIB_DIR="$RUNTIME_DIR/$LIB_NAME"
# Список зависимостей и закреплённые версии лежат рядом с шаблонами юнитов в pii-proxy/deploy.
DEPLOY_DIR="$RUNTIME_DIR/pii-proxy/deploy"

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

find_python() {   # labops-pii требует Python >= 3.12
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
  mkdir -p "$RUNTIME_DIR"
  # Агент создаётся из копии роя без pii-*: код уже лежит в рабочей копии после шага host.
  if [ -d "$SRC_DIR/pii-proxy" ] || [ ! -d "$RUNTIME_DIR/pii-proxy/deploy" ]; then
    [ -d "$SRC_DIR/pii-proxy" ] || die "нет $SRC_DIR/pii-proxy - установка идёт не из монорепо?"
    mkdir -p "$RUNTIME_DIR/pii-proxy"
    (cd "$SRC_DIR/pii-proxy" && tar --exclude=node_modules --exclude=.venv --exclude=__pycache__ \
        --exclude=data -cf - .) | (cd "$RUNTIME_DIR/pii-proxy" && tar -xf -)
  fi
  local vendor="$SRC_DIR/vendor/$LIB_NAME"
  if [ ! -d "$vendor/labops_pii" ] && [ -d "$LIB_DIR/labops_pii" ]; then return 0; fi
  [ -d "$vendor/labops_pii" ] || die "нет $vendor/labops_pii - вендоренная библиотека не найдена"
  mkdir -p "$LIB_DIR"
  # Пакет заменяем целиком (без tar поверх): файлы, пропавшие в новом теге, не должны остаться.
  rm -rf "$LIB_DIR/labops_pii"
  (cd "$vendor" && tar --exclude=__pycache__ -cf - .) | (cd "$LIB_DIR" && tar -xf -)
}

# Зависимости библиотеки в общий venv (код подключает PYTHONPATH юнита, pip-пакета нет).
install_lib_deps() {
  local py
  [ "${PII_SKIP_BUILD:-0}" = "1" ] && return 0
  py="$(find_python)" || die "нужен Python >= 3.12 для labops-pii (apt install python3.12-venv)"
  if [ ! -x "$LIB_DIR/.venv/bin/python" ]; then
    step "venv и зависимости labops-pii (несколько минут: natasha, pymorphy3, opencv)"
    "$py" -m venv "$LIB_DIR/.venv"
  fi
  "$LIB_DIR/.venv/bin/pip" install -q -r "$DEPLOY_DIR/labops-pii.requirements.txt" \
    -c "$DEPLOY_DIR/labops-pii.constraints.txt"
}

# Добавляет KEY=VALUE в env-файл, если ключа ещё нет (оператор мог задать своё значение).
# Так обновляются env-файлы, созданные до перехода на labops-pii: прежние имена переменных
# библиотека читает как есть, нужно лишь дописать новые настройки.
ensure_env_key() {   # <env-file> <KEY> <VALUE>
  if ! grep -q "^$2=" "$1"; then
    echo "$2=$3" >> "$1"
    ok "env сервиса: добавлено $2=$3"
  fi
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
  local token_file env_file
  token_file="$CONFIG_DIR/pseudonymizer.token"
  env_file="$CONFIG_DIR/pseudonymizer.env"
  mkdir -p "$CONFIG_DIR"; chmod 700 "$CONFIG_DIR"
  install_lib_deps
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
      # Адреса маскируются по решению владельца (этап Г плана 152-ФЗ): профиль labops их не включает
      echo "PSEUDONYMIZER_ADDRESS_MASK=true"
      echo "PSEUDONYMIZER_HOST=127.0.0.1"
      echo "PSEUDONYMIZER_PORT=8300"
    } > "$env_file"
  fi
  chmod 600 "$env_file"
  ensure_env_key "$env_file" PSEUDONYMIZER_ADDRESS_MASK true
  INSTALL_DIR_FOR_UNIT="$LIB_DIR" ENV_FILE_FOR_UNIT="$env_file" \
    render_unit "$DEPLOY_DIR/pseudonymizer.user.service.template" \
      "$UNIT_DIR/labops-pseudonymizer.service"
  ucmd daemon-reload
  ucmd enable --now labops-pseudonymizer.service \
    || warn "не удалось запустить labops-pseudonymizer (нет systemctl --user?)"
  ensure_linger
  wait_health "$PII_PSEUDONYMIZER_URL_DEFAULT" "pseudonymizer" "labops-pseudonymizer" || true
  install_media_masker
}

# Есть ли рабочий Tesseract с языками rus и eng (иначе media-masker не стартует).
tesseract_ready() {
  local cmd="${PII_TESSERACT_CMD:-tesseract}" langs
  command -v "$cmd" >/dev/null 2>&1 || [ -x "$cmd" ] || return 1
  langs="$(TESSDATA_PREFIX="${PII_TESSDATA_PREFIX:-${TESSDATA_PREFIX:-}}" \
    LD_LIBRARY_PATH="${PII_TESSERACT_LD_LIBRARY_PATH:-${LD_LIBRARY_PATH:-}}" \
    "$cmd" --list-langs 2>&1)" || return 1
  grep -qx 'rus' <<< "$langs" && grep -qx 'eng' <<< "$langs"
}

warn_no_tesseract() {
  warn "Tesseract (rus+eng) не найден: media-masker НЕ установлен."
  warn "Фото и PDF не будут маскироваться: прокси агентов получит PII_PROXY_IMAGE_POLICY=strip"
  warn "(вложения заменяются пометкой и модели не передаются)."
  warn "Установить: sudo apt-get install tesseract-ocr tesseract-ocr-rus tesseract-ocr-eng"
  warn "tesseract-ocr-osd, затем повторить: pii-setup.sh host (см. pii-proxy/docs/media-masker.md)."
}

# media-masker: OCR-маскирование вложений. Нет Tesseract - предупреждаем и идём дальше
# (политика агентов станет strip), чтобы установка псевдонимизации не ломалась целиком.
install_media_masker() {
  local token_file env_file
  token_file="$CONFIG_DIR/media-masker.token"
  env_file="$CONFIG_DIR/media-masker.env"
  if ! tesseract_ready; then warn_no_tesseract; return 0; fi
  say "media-masker (OCR фото и PDF, один на хост)"
  if [ ! -s "$token_file" ]; then
    umask 077
    python3 -c "import secrets; print(secrets.token_urlsafe($TOKEN_BYTES))" > "$token_file"
    ok "создан токен media-masker: $token_file (600)"
  fi
  chmod 600 "$token_file"
  umask 077
  {
    echo "MEDIA_MASKER_API_TOKEN=$(tr -d '\n' < "$token_file")"
    echo "MEDIA_MASKER_HOST=127.0.0.1"
    echo "MEDIA_MASKER_PORT=$MEDIA_MASKER_PORT"
    echo "MEDIA_MASKER_MASK_LEGAL_ENTITY=true"
    [ -z "${PII_TESSERACT_CMD:-}" ] || echo "MEDIA_MASKER_TESSERACT_CMD=$PII_TESSERACT_CMD"
    [ -z "${PII_TESSDATA_PREFIX:-}" ] || echo "TESSDATA_PREFIX=$PII_TESSDATA_PREFIX"
    [ -z "${PII_TESSERACT_LD_LIBRARY_PATH:-}" ] \
      || echo "LD_LIBRARY_PATH=$PII_TESSERACT_LD_LIBRARY_PATH"
  } > "$env_file"
  chmod 600 "$env_file"
  INSTALL_DIR_FOR_UNIT="$LIB_DIR" ENV_FILE_FOR_UNIT="$env_file" \
    render_unit "$DEPLOY_DIR/media-masker.user.service.template" \
      "$UNIT_DIR/labops-media-masker.service"
  ucmd daemon-reload
  ucmd enable --now labops-media-masker.service \
    || warn "не удалось запустить labops-media-masker (нет systemctl --user?)"
  wait_health "$MEDIA_MASKER_URL_DEFAULT" "media-masker" "labops-media-masker" || true
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

# Строки env прокси про вложения. Есть токен media-masker - mask, иначе strip: прокси с
# политикой mask без токена не стартует, а passthrough пустил бы ПДн с картинок к модели.
media_env_lines() {
  local token_file="$CONFIG_DIR/media-masker.token"
  if [ -s "$token_file" ]; then
    echo "PII_PROXY_IMAGE_POLICY=mask"
    echo "MEDIA_MASKER_URL=$MEDIA_MASKER_URL_DEFAULT"
    echo "MEDIA_MASKER_API_TOKEN=$(tr -d '\n' < "$token_file")"
  else
    echo "PII_PROXY_IMAGE_POLICY=strip"
  fi
}

# Старый env-файл (политика passthrough/strip, нет токена маскера): если media-masker уже
# установлен - переводим на mask; иначе оставляем и предупреждаем про strip.
upgrade_media_policy() {   # <env-file>
  local f="$1" token_file="$CONFIG_DIR/media-masker.token"
  if grep -qs '^MEDIA_MASKER_API_TOKEN=.' "$f"; then return 0; fi
  if [ -s "$token_file" ]; then
    sed -i '/^PII_PROXY_IMAGE_POLICY=/d' "$f"
    media_env_lines >> "$f"
    ok "env прокси: вложения теперь через media-masker (mask)"
  else
    warn "media-masker не установлен: вложения в $f не маскируются (политика: $(sed -n 's/^PII_PROXY_IMAGE_POLICY=//p' "$f"))"
  fi
}

warn_no_tesseract_agent() {
  warn "агент $1: media-masker не подключён, фото и PDF модели не передаются (strip)."
  warn "Поставьте Tesseract и выполните pii-setup.sh host, затем повторите agent $1."
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
    upgrade_media_policy "$env_file"
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
      media_env_lines
    } > "$env_file"
    ok "env прокси: $env_file (порт $port, 600)"
  fi
  chmod 600 "$env_file"
  if grep -qsx 'PII_PROXY_IMAGE_POLICY=strip' "$env_file"; then
    warn_no_tesseract_agent "$agent"
  fi
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
