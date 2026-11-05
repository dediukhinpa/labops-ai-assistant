#!/usr/bin/env bash
# Адаптер Claude Code -> OpenAI (LiteLLM). Альтернативный вариант курса: рой работает на моделях
# OpenAI, архитектура репозитория не меняется.
#
# Как это устроено. Claude Code умеет ходить не на api.anthropic.com, а на любой шлюз с форматом
# Anthropic Messages (ANTHROPIC_BASE_URL). Агент и так ходит через pii-proxy, а у того адрес
# апстрима настраивается (PII_PROXY_UPSTREAM). Адаптер - ещё одно звено на 127.0.0.1:
#   claude -> pii-proxy -> адаптер (LiteLLM, /v1/messages) -> OpenAI (Responses API)
# Сюда входит только установка самого адаптера; перевод агентов на него - openai-adapter-wire.sh.
#
# Что ставится (всё вне домашних каталогов, код и ключи - root):
#   /opt/labops-openai-adapter/.venv            LiteLLM по requirements.lock (с хэшами)
#   /etc/labops-openai-adapter/config.yaml      модели, без ключей, 640 root:labops-llm
#   /etc/labops-openai-adapter/adapter.env      OPENAI_API_KEY и локальный ключ шлюза, 640
#   labops-openai-adapter.service               пользователь labops-llm, 127.0.0.1:4000
#   <лаборатория>/shared/secrets/openai-adapter.env   локальный ключ шлюза для агентов, 600
#
# Ключ OpenAI берётся из окружения (OPENAI_API_KEY) или спрашивается без эха; в argv, вывод и
# журналы он не попадает. Имя модели - LABOPS_OPENAI_MODEL (по умолчанию его нет: актуальное
# имя берут на странице моделей OpenAI). Повтор идемпотентен: локальный ключ шлюза остаётся.
#
#   openai_adapter_install <пользователь агентов> <его домашний каталог>  -> 0 адаптер работает

# shellcheck shell=bash

LLM_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Пути и имена переопределяются окружением - так их подменяет юнит-тест.
: "${LABOPS_LLM_SRC:=$LLM_LIB_DIR/../../openai-adapter}"
: "${LABOPS_LLM_DIR:=/opt/labops-openai-adapter}"
: "${LABOPS_LLM_ETC:=/etc/labops-openai-adapter}"
: "${LABOPS_LLM_UNIT_DIR:=/etc/systemd/system}"
: "${LABOPS_LLM_UNIT:=labops-openai-adapter.service}"
: "${LABOPS_LLM_USER:=labops-llm}"
: "${LABOPS_LLM_OWNER:=root}"
: "${LABOPS_LLM_PORT:=4000}"
: "${LABOPS_LLM_HEALTH_URL:=http://127.0.0.1:$LABOPS_LLM_PORT/health/liveliness}"

# venv с LiteLLM и его зависимостями - ~0,7 ГБ, плюс запас на сборку.
LLM_MIN_FREE_MB=2048
LLM_MIN_PYTHON_MINOR=12
LLM_HEALTH_TRIES=60
LLM_HEALTH_POLL_SEC=2
# Потолок памяти юнита: измерение на LiteLLM 1.106.3 без нагрузки - сотни МБ.
LLM_MEMORY_MAX="1500M"
LLM_MASTER_KEY_BYTES=24

# llm_valid_model <имя> - как is_valid_model_name в model-choice.sh: латиница, цифры, . _ -.
llm_valid_model() {
  case "$1" in [A-Za-z0-9]*) ;; *) return 1 ;; esac
  [ -z "$(printf '%s' "$1" | LC_ALL=C tr -d 'A-Za-z0-9._-')" ]
}

# llm_pick_python - путь к python 3.10+ с venv; пусто и 1, если такого нет.
llm_pick_python() {
  local cand
  for cand in "${LABOPS_LLM_PYTHON:-}" python3.13 python3.12 python3; do
    [ -n "$cand" ] && command -v "$cand" >/dev/null 2>&1 || continue
    if "$cand" -c "import sys, venv, ensurepip
sys.exit(0 if sys.version_info[:2] >= (3, $LLM_MIN_PYTHON_MINOR) else 1)" >/dev/null 2>&1; then
      command -v "$cand"
      return 0
    fi
  done
  return 1
}

# llm_ask_inputs - ключ OpenAI и модель: из окружения, иначе вопрос (ключ без эха).
llm_ask_inputs() {
  if [ -z "${OPENAI_API_KEY:-}" ]; then
    [ -t 0 ] || { warn "нет OPENAI_API_KEY и нет терминала - задайте ключ в окружении"; return 1; }
    printf "Ключ OpenAI API (ввод не виден): "
    read -rs OPENAI_API_KEY; echo
    export OPENAI_API_KEY
  fi
  if [ -z "${LABOPS_OPENAI_MODEL:-}" ]; then
    [ -t 0 ] || { warn "нет LABOPS_OPENAI_MODEL и нет терминала"; return 1; }
    printf "Имя модели OpenAI (из списка моделей на platform.openai.com): "
    read -r LABOPS_OPENAI_MODEL
    export LABOPS_OPENAI_MODEL
  fi
  [ -n "$OPENAI_API_KEY" ] || { warn "ключ OpenAI пуст"; return 1; }
  if ! llm_valid_model "$LABOPS_OPENAI_MODEL"; then
    warn "имя модели '$LABOPS_OPENAI_MODEL' содержит недопустимые символы"
    return 1
  fi
}

# llm_ensure_user - системный пользователь без входа и без домашнего каталога.
llm_ensure_user() {
  id "$LABOPS_LLM_USER" >/dev/null 2>&1 && return 0
  $SUDO useradd --system --no-create-home --shell /usr/sbin/nologin "$LABOPS_LLM_USER"
}

# llm_install_code <python> - venv и зависимости строго по lock-файлу с хэшами.
llm_install_code() {
  local py="$1" log
  $SUDO install -d -m 755 -o "$LABOPS_LLM_OWNER" "$LABOPS_LLM_DIR" || return 1
  $SUDO install -m 644 -o "$LABOPS_LLM_OWNER" "$LABOPS_LLM_SRC/requirements.lock" \
    "$LABOPS_LLM_DIR/requirements.lock" || return 1
  if [ ! -x "$LABOPS_LLM_DIR/.venv/bin/python" ]; then
    $SUDO "$py" -m venv "$LABOPS_LLM_DIR/.venv" || return 1
  fi
  log="$(mktemp)"
  # --require-hashes: пакет с другим хэшем не встанет. Так закрывается подмена релиза в PyPI.
  if ! $SUDO "$LABOPS_LLM_DIR/.venv/bin/pip" install --quiet --disable-pip-version-check \
       --require-hashes -r "$LABOPS_LLM_DIR/requirements.lock" >"$log" 2>&1; then
    warn "pip install адаптера не прошёл. Последние строки:"
    tail -n 15 "$log" | sed 's/^/      /'
    rm -f "$log"
    return 1
  fi
  rm -f "$log"
  ok "LiteLLM установлен: $LABOPS_LLM_DIR"
}

# llm_write_config - config.yaml из шаблона; ключей в нём нет.
llm_write_config() {
  local tmp
  tmp="$(mktemp)"
  sed "s|__MODEL__|$LABOPS_OPENAI_MODEL|g" "$LABOPS_LLM_SRC/config.template.yaml" > "$tmp"
  $SUDO install -d -m 750 -o "$LABOPS_LLM_OWNER" -g "$LABOPS_LLM_USER" "$LABOPS_LLM_ETC" \
    || { rm -f "$tmp"; return 1; }
  $SUDO install -m 640 -o "$LABOPS_LLM_OWNER" -g "$LABOPS_LLM_USER" "$tmp" \
    "$LABOPS_LLM_ETC/config.yaml" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
}

# llm_master_key - локальный ключ шлюза: прежний, если env-файл уже есть, иначе новый.
llm_master_key() {
  local key=""
  if $SUDO test -f "$LABOPS_LLM_ETC/adapter.env"; then
    key="$($SUDO sed -n 's/^LITELLM_MASTER_KEY=//p' "$LABOPS_LLM_ETC/adapter.env")"
  fi
  [ -n "$key" ] || key="sk-$(openssl rand -hex "$LLM_MASTER_KEY_BYTES")"
  printf '%s' "$key"
}

# llm_write_env - env-файл юнита. Права 640 root:labops-llm: читает только сам юнит.
llm_write_env() {
  local tmp key
  key="$(llm_master_key)" || return 1
  tmp="$(mktemp)"
  {
    echo "OPENAI_API_KEY=$OPENAI_API_KEY"
    echo "LITELLM_MASTER_KEY=$key"
    # Не качать таблицу цен из интернета при каждом старте: адаптер ходит только к OpenAI.
    echo "LITELLM_LOCAL_MODEL_COST_MAP=True"
  } > "$tmp"
  $SUDO install -m 640 -o "$LABOPS_LLM_OWNER" -g "$LABOPS_LLM_USER" "$tmp" \
    "$LABOPS_LLM_ETC/adapter.env" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
}

# llm_install_unit - юнит с песочницей; слушает только 127.0.0.1.
llm_install_unit() {
  local tmp
  tmp="$(mktemp)"
  cat > "$tmp" <<EOF
[Unit]
Description=LabOps OpenAI adapter (LiteLLM: Anthropic Messages -> OpenAI)
After=network-online.target
Wants=network-online.target

[Service]
User=$LABOPS_LLM_USER
EnvironmentFile=$LABOPS_LLM_ETC/adapter.env
ExecStart=$LABOPS_LLM_DIR/.venv/bin/litellm --config $LABOPS_LLM_ETC/config.yaml --host 127.0.0.1 --port $LABOPS_LLM_PORT
Restart=on-failure
RestartSec=5
MemoryMax=$LLM_MEMORY_MAX
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
  $SUDO install -m 644 -o "$LABOPS_LLM_OWNER" "$tmp" "$LABOPS_LLM_UNIT_DIR/$LABOPS_LLM_UNIT" \
    || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  $SUDO systemctl daemon-reload || return 1
  $SUDO systemctl enable "$LABOPS_LLM_UNIT" >/dev/null 2>&1 || true
  # enable --now не трогает работающий юнит, а ключ или модель могли смениться - restart.
  $SUDO systemctl restart "$LABOPS_LLM_UNIT" || return 1
}

# llm_wait_ready - ждёт ответа /health/liveliness (первый старт LiteLLM - секунды).
llm_wait_ready() {
  local i
  for ((i = 0; i < LLM_HEALTH_TRIES; i++)); do
    if curl -fsS -m 3 "$LABOPS_LLM_HEALTH_URL" >/dev/null 2>&1; then
      ok "адаптер отвечает: 127.0.0.1:$LABOPS_LLM_PORT"
      return 0
    fi
    sleep "$LLM_HEALTH_POLL_SEC"
  done
  warn "адаптер не ответил за $((LLM_HEALTH_TRIES * LLM_HEALTH_POLL_SEC)) с: journalctl -u $LABOPS_LLM_UNIT"
  return 1
}

# llm_share_key <пользователь> <дом> - локальный ключ шлюза агентам: файл 600 у пользователя.
llm_share_key() {
  local user="$1" home="$2" lab="${CLAUDE_LAB:-$2/.claude-lab}" key tmp group
  key="$($SUDO sed -n 's/^LITELLM_MASTER_KEY=//p' "$LABOPS_LLM_ETC/adapter.env")"
  [ -n "$key" ] || return 1
  group="$(id -gn "$user")"
  $SUDO install -d -m 700 -o "$user" -g "$group" "$lab/shared/secrets" || return 1
  tmp="$(mktemp)"
  printf 'ANTHROPIC_AUTH_TOKEN=%s\nLABOPS_OPENAI_MODEL=%s\nLABOPS_LLM_PORT=%s\n' \
    "$key" "$LABOPS_OPENAI_MODEL" "$LABOPS_LLM_PORT" > "$tmp"
  $SUDO install -m 600 -o "$user" -g "$group" "$tmp" "$lab/shared/secrets/openai-adapter.env" \
    || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  ok "ключ шлюза для агентов: $lab/shared/secrets/openai-adapter.env"
}

# openai_adapter_install <пользователь> <дом> - вся установка; на первом сбое возвращает 1.
openai_adapter_install() {
  local user="$1" home="$2" py free
  if [ ! -f "$LABOPS_LLM_SRC/requirements.lock" ]; then
    warn "нет $LABOPS_LLM_SRC/requirements.lock - адаптер не ставлю"
    return 1
  fi
  command -v systemctl >/dev/null 2>&1 || { warn "нет systemd - адаптер не поставить"; return 1; }
  if [ "$(id -u)" -ne 0 ] && [ -z "${SUDO:-}" ]; then
    warn "нет sudo - адаптер не поставить (нужен root)"; return 1
  fi
  if ! py="$(llm_pick_python)"; then
    warn "нужен Python 3.$LLM_MIN_PYTHON_MINOR+ с venv (lock собран под 3.12) - адаптер не поставлен"; return 1
  fi
  free="$(df -Pm "$(dirname "$LABOPS_LLM_DIR")" 2>/dev/null | awk 'NR==2{print $4}')"
  if [ "${free:-0}" -lt "$LLM_MIN_FREE_MB" ]; then
    warn "мало места на диске (${free:-?} МБ, нужно $LLM_MIN_FREE_MB) - адаптер не поставлен"; return 1
  fi
  llm_ask_inputs || return 1
  llm_ensure_user || { warn "не создан пользователь $LABOPS_LLM_USER"; return 1; }
  llm_install_code "$py" || return 1
  llm_write_config || { warn "не записан config.yaml"; return 1; }
  llm_write_env || { warn "не записан env-файл адаптера"; return 1; }
  llm_install_unit || { warn "юнит $LABOPS_LLM_UNIT не запущен"; return 1; }
  llm_wait_ready || return 1
  llm_share_key "$user" "$home" || { warn "ключ шлюза не передан агентам"; return 1; }
  note "модель: $LABOPS_OPENAI_MODEL. Перевести агентов на адаптер: bash orchestration/openai-adapter-wire.sh <агент>"
}
