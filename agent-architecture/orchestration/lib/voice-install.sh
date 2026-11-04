#!/usr/bin/env bash
# Установка сервиса расшифровки голоса (voice-transcriber, faster-whisper на CPU).
#
# Раньше сервис ставили только руками по его README, а new-agent.sh спрашивал
# «токен сервиса voice-transcriber»: клиенту по курсу взять его было неоткуда, и голос
# оставался выключенным. Теперь install.sh ставит сервис сам, пока у него есть root
# (до перехода на пользователя агентов), и кладёт токен в общие секреты роя — каждый
# следующий агент находит его там и вопроса про голос не получает.
#
# Что ставится (всё вне домашних каталогов, код и веса — root, только чтение):
#   /opt/labops-voice-transcriber          код и .venv
#   /var/lib/labops-voice/models           веса faster-whisper (закреплённая ревизия)
#   /etc/labops-voice/voice-transcriber.env  токен и настройки, 640 root:labops-voice
#   labops-voice-transcriber.service       системный пользователь labops-voice, 127.0.0.1:8310
#   <лаборатория>/shared/secrets/voice-transcriber-token  токен для агентов, 600
#
# Повторный запуск идемпотентен: код и .venv обновляются, веса и токен остаются.
# Подключается через source; ждёт ok/warn/step/note из ui.sh и $SUDO (пусто под root).
#
#   voice_install <пользователь агентов> <его домашний каталог>  -> 0 голос работает

# shellcheck shell=bash

VOICE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Пути и имена переопределяются окружением — так их подменяет юнит-тест.
: "${LABOPS_VOICE_SRC:=$VOICE_LIB_DIR/../../../voice-transcriber}"
: "${LABOPS_VOICE_DIR:=/opt/labops-voice-transcriber}"
: "${LABOPS_VOICE_ETC:=/etc/labops-voice}"
: "${LABOPS_VOICE_MODELS:=/var/lib/labops-voice/models}"
: "${LABOPS_VOICE_UNIT_DIR:=/etc/systemd/system}"
: "${LABOPS_VOICE_UNIT:=labops-voice-transcriber.service}"
: "${LABOPS_VOICE_USER:=labops-voice}"
: "${LABOPS_VOICE_OWNER:=root}"
: "${LABOPS_VOICE_HEALTH_URL:=http://127.0.0.1:8310/health}"
# Каталог с уже скачанными весами — вместо загрузки (офлайн-установка, тест).
: "${LABOPS_VOICE_MODEL_SOURCE:=}"

# Модель по замеру из voice-transcriber/README («Замеры»): small укладывается в реальное
# время и в 900 МБ. Ревизия закреплена: веса не сменятся молча между установками.
VOICE_MODEL_NAME="small"
VOICE_MODEL_REPO="Systran/faster-whisper-small"
VOICE_MODEL_REVISION="536b0662742c02347bc0e980a01041f333bce120"
# Загрузка и прогрев модели — десятки секунд; юнит даёт себе 120 с на старт.
VOICE_HEALTH_TIMEOUT_SEC=180
VOICE_HEALTH_POLL_SEC=2
# Веса ~0,5 ГБ + .venv ~0,6 ГБ + запас на сборку колёс.
VOICE_MIN_FREE_MB=2048
# Зависимости закреплены в constraints.txt на Python 3.12.
VOICE_MIN_PYTHON_MINOR=12

# voice_pick_python — путь к python 3.12+ с модулем venv; пусто и 1, если такого нет.
voice_pick_python() {
  local cand
  for cand in "${LABOPS_VOICE_PYTHON:-}" python3.12 python3.13 python3.14 python3; do
    [ -n "$cand" ] && command -v "$cand" >/dev/null 2>&1 || continue
    if "$cand" -c "import sys, venv, ensurepip
sys.exit(0 if sys.version_info[:2] >= (3, $VOICE_MIN_PYTHON_MINOR) else 1)" >/dev/null 2>&1; then
      command -v "$cand"
      return 0
    fi
  done
  return 1
}

# voice_free_mb <каталог> — свободное место (МБ) на ФС ближайшего существующего предка.
voice_free_mb() {
  local dir="$1"
  while [ ! -d "$dir" ]; do dir="$(dirname "$dir")"; done
  df -Pm "$dir" | awk 'NR == 2 { print $4 }'
}

# voice_ensure_user — системный пользователь сервиса (без входа и без дома).
voice_ensure_user() {
  id "$LABOPS_VOICE_USER" >/dev/null 2>&1 && return 0
  $SUDO useradd --system --user-group --no-create-home --shell /usr/sbin/nologin "$LABOPS_VOICE_USER"
}

# voice_install_code <python> — код подпроекта и .venv с закреплёнными зависимостями.
voice_install_code() {
  local py="$1" log
  $SUDO install -d -m 755 -o "$LABOPS_VOICE_OWNER" "$LABOPS_VOICE_DIR" || return 1
  $SUDO rm -rf "$LABOPS_VOICE_DIR/voice_transcriber" || return 1
  $SUDO cp -R "$LABOPS_VOICE_SRC/voice_transcriber" "$LABOPS_VOICE_DIR/" || return 1
  $SUDO install -m 644 -o "$LABOPS_VOICE_OWNER" "$LABOPS_VOICE_SRC/pyproject.toml" \
    "$LABOPS_VOICE_SRC/constraints.txt" "$LABOPS_VOICE_DIR/" || return 1
  if [ ! -x "$LABOPS_VOICE_DIR/.venv/bin/python" ]; then
    $SUDO "$py" -m venv "$LABOPS_VOICE_DIR/.venv" || return 1
  fi
  log="$(mktemp)"
  if ! $SUDO "$LABOPS_VOICE_DIR/.venv/bin/pip" install --quiet --disable-pip-version-check \
       -c "$LABOPS_VOICE_DIR/constraints.txt" "$LABOPS_VOICE_DIR" >"$log" 2>&1; then
    warn "pip install сервиса голоса не прошёл. Последние строки:"
    tail -n 15 "$log" | sed 's/^/      /'
    rm -f "$log"
    return 1
  fi
  rm -f "$log"
  ok "код сервиса голоса: $LABOPS_VOICE_DIR"
}

# voice_fetch_model — веса в <models>/faster-whisper-<модель>; уже лежащие не трогает.
voice_fetch_model() {
  local target="$LABOPS_VOICE_MODELS/faster-whisper-$VOICE_MODEL_NAME"
  if $SUDO test -f "$target/model.bin"; then
    ok "модель $VOICE_MODEL_NAME уже на месте: $target"
    return 0
  fi
  $SUDO install -d -m 755 -o "$LABOPS_VOICE_OWNER" "$LABOPS_VOICE_MODELS" || return 1
  $SUDO rm -rf "$target.part" || return 1
  if [ -n "$LABOPS_VOICE_MODEL_SOURCE" ]; then
    $SUDO cp -R "$LABOPS_VOICE_MODEL_SOURCE" "$target.part" || return 1
  else
    step "скачиваю модель $VOICE_MODEL_REPO (~0,5 ГБ, huggingface.co)"
    # Скачиваем во временный каталог: оборванная загрузка не выглядит готовой моделью.
    if ! $SUDO env HF_HUB_DISABLE_TELEMETRY=1 "$LABOPS_VOICE_DIR/.venv/bin/python" - \
         "$VOICE_MODEL_REPO" "$VOICE_MODEL_REVISION" "$target.part" <<'PY'
import sys
from huggingface_hub import snapshot_download

snapshot_download(sys.argv[1], revision=sys.argv[2], local_dir=sys.argv[3])
PY
    then
      warn "модель не скачалась — проверьте доступ к huggingface.co"
      return 1
    fi
  fi
  $SUDO chmod -R a+rX "$target.part" && $SUDO mv "$target.part" "$target" || return 1
  ok "модель $VOICE_MODEL_NAME: $target"
}

# voice_write_env — env-файл сервиса; токен прежний, если сервис уже ставили.
voice_write_env() {
  local env="$LABOPS_VOICE_ETC/voice-transcriber.env" group
  group="$(id -gn "$LABOPS_VOICE_USER")" || return 1
  $SUDO install -d -m 750 -o "$LABOPS_VOICE_OWNER" -g "$group" "$LABOPS_VOICE_ETC" || return 1
  $SUDO python3 "$VOICE_LIB_DIR/voice_env.py" render \
    "$LABOPS_VOICE_SRC/deploy/voice-transcriber.env.example" "$env.new" \
    "$LABOPS_VOICE_MODELS" "$env" || return 1
  $SUDO chown "$LABOPS_VOICE_OWNER:$group" "$env.new" || return 1
  $SUDO chmod 640 "$env.new" || return 1
  $SUDO mv "$env.new" "$env"
}

# voice_install_unit — юнит из шаблона подпроекта; рестарт, чтобы подхватить новый код
# (enable --now не трогает уже работающий юнит).
voice_install_unit() {
  local tmp
  tmp="$(mktemp)"
  sed -e "s|__USER__|$LABOPS_VOICE_USER|g" \
      -e "s|__INSTALL_DIR__|$LABOPS_VOICE_DIR|g" \
      -e "s|__ENV_FILE__|$LABOPS_VOICE_ETC/voice-transcriber.env|g" \
      "$LABOPS_VOICE_SRC/deploy/voice-transcriber.service.template" > "$tmp"
  if grep -q '__[A-Z_]*__' "$tmp"; then
    warn "в шаблоне юнита голоса остались плейсхолдеры"
    rm -f "$tmp"
    return 1
  fi
  $SUDO install -m 644 "$tmp" "$LABOPS_VOICE_UNIT_DIR/$LABOPS_VOICE_UNIT" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  $SUDO systemctl daemon-reload || return 1
  $SUDO systemctl enable "$LABOPS_VOICE_UNIT" >/dev/null 2>&1 || return 1
  $SUDO systemctl restart "$LABOPS_VOICE_UNIT"
}

# voice_wait_ready — ждём /health: ready после загрузки и прогрева модели.
voice_wait_ready() {
  local waited=0 body
  while [ "$waited" -lt "$VOICE_HEALTH_TIMEOUT_SEC" ]; do
    body="$(curl -sS --max-time 5 "$LABOPS_VOICE_HEALTH_URL" 2>/dev/null || true)"
    case "$body" in
      *'"ready"'*) ok "сервис голоса готов ($LABOPS_VOICE_HEALTH_URL)"; return 0 ;;
      *'"failed"'*) warn "сервис голоса не загрузил модель: journalctl -u $LABOPS_VOICE_UNIT"; return 1 ;;
    esac
    sleep "$VOICE_HEALTH_POLL_SEC"
    waited=$((waited + VOICE_HEALTH_POLL_SEC))
  done
  warn "сервис голоса не ответил ready за ${VOICE_HEALTH_TIMEOUT_SEC} с: journalctl -u $LABOPS_VOICE_UNIT"
  return 1
}

# voice_share_token <пользователь> <дом> — токен в общие секреты роя этого пользователя.
voice_share_token() {
  local user="$1" home="$2" group lab dir
  group="$(id -gn "$user")" || return 1
  lab="${CLAUDE_LAB:-$home/.claude-lab}"
  # Каталоги по одному: install -d с -o на всю цепочку ведёт себя по-разному в
  # GNU coreutils и uutils (Ubuntu 26.04), а корень лаборатории должен остаться за агентом.
  for dir in "$lab" "$lab/shared"; do
    $SUDO test -d "$dir" || $SUDO install -d -m 755 -o "$user" -g "$group" "$dir" || return 1
  done
  $SUDO install -d -m 700 -o "$user" -g "$group" "$lab/shared/secrets" || return 1
  $SUDO python3 "$VOICE_LIB_DIR/voice_env.py" export-token \
    "$LABOPS_VOICE_ETC/voice-transcriber.env" "$lab/shared/secrets/voice-transcriber-token" \
    || return 1
  $SUDO chown "$user:$group" "$lab/shared/secrets/voice-transcriber-token" || return 1
  ok "токен голоса для агентов: $lab/shared/secrets/voice-transcriber-token"
}

# voice_install <пользователь агентов> <его дом> — весь шаг; 1 — голос не поставлен
# (причина уже напечатана), текстовый канал от этого не зависит.
voice_install() {
  local user="$1" home="$2" py free
  if [ ! -f "$LABOPS_VOICE_SRC/pyproject.toml" ]; then
    warn "нет подпроекта voice-transcriber рядом ($LABOPS_VOICE_SRC) — голос не ставлю"
    return 1
  fi
  command -v systemctl >/dev/null 2>&1 || { warn "нет systemd — сервис голоса не поставить"; return 1; }
  if ! py="$(voice_pick_python)"; then
    warn "нужен Python 3.$VOICE_MIN_PYTHON_MINOR+ с venv — сервис голоса не поставлен"
    return 1
  fi
  free="$(voice_free_mb "$LABOPS_VOICE_DIR")"
  if [ "${free:-0}" -lt "$VOICE_MIN_FREE_MB" ]; then
    warn "мало места на диске (${free} МБ, нужно ${VOICE_MIN_FREE_MB}) — сервис голоса не поставлен"
    return 1
  fi
  voice_ensure_user || { warn "не создан пользователь $LABOPS_VOICE_USER"; return 1; }
  voice_install_code "$py" || return 1
  voice_fetch_model || return 1
  voice_write_env || { warn "не записан env-файл сервиса голоса"; return 1; }
  voice_install_unit || { warn "юнит $LABOPS_VOICE_UNIT не запущен"; return 1; }
  voice_wait_ready || return 1
  voice_share_token "$user" "$home" || { warn "токен голоса не передан агентам"; return 1; }
}
