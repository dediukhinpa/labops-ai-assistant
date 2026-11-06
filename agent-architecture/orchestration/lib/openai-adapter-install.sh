#!/usr/bin/env bash
# Адаптер Claude Code -> ChatGPT (LiteLLM). Альтернативный вариант курса: рой работает на моделях
# OpenAI по ПОДПИСКЕ ChatGPT (Plus/Pro), а не по ключу API. Архитектура репозитория не меняется.
#
# Как это устроено. Claude Code умеет ходить не на api.anthropic.com, а на любой шлюз с форматом
# Anthropic Messages (ANTHROPIC_BASE_URL). Агент и так ходит через pii-proxy, а у того адрес
# апстрима настраивается (PII_PROXY_UPSTREAM). Адаптер - ещё одно звено на 127.0.0.1:
#   claude -> pii-proxy -> адаптер (LiteLLM, /v1/messages) -> бэкенд подписки ChatGPT
# Сюда входит только установка самого адаптера; перевод агентов на него - openai-adapter-wire.sh.
#
# Вход в подписку. LiteLLM входит по коду устройства (как Codex CLI): установщик печатает
# ссылку и код, человек подтверждает вход в браузере. Это делается ОДИН раз и отдельно от
# службы (внутри неё вход невозможен): токены ложатся в каталог службы, дальше она сама их
# обновляет. Если OpenAI отзовёт доступ - повторить `install.sh --openai-adapter`.
#
# Что ставится (всё вне домашних каталогов, код - root):
#   /opt/labops-openai-adapter/.venv            LiteLLM по requirements.lock (с хэшами)
#   /etc/labops-openai-adapter/config.yaml      модели, без секретов, 640 root:labops-llm
#   /etc/labops-openai-adapter/adapter.env      локальный ключ шлюза, 640
#   /var/lib/labops-openai-adapter/auth.json    токены входа в ChatGPT, 700 labops-llm
#   labops-openai-adapter.service               пользователь labops-llm, 127.0.0.1:4000
#   <лаборатория>/shared/secrets/openai-adapter.env   локальный ключ шлюза для агентов, 600
#
# Имя модели - LABOPS_OPENAI_MODEL или выбор из короткого списка. В argv, вывод и журналы
# токены не попадают. Повтор идемпотентен: ключ шлюза и вход остаются.
#
#   openai_adapter_install <пользователь агентов> <его домашний каталог>  -> 0 адаптер работает

# shellcheck shell=bash

LLM_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Пути и имена переопределяются окружением - так их подменяет юнит-тест.
: "${LABOPS_LLM_SRC:=$LLM_LIB_DIR/../../openai-adapter}"
: "${LABOPS_LLM_DIR:=/opt/labops-openai-adapter}"
: "${LABOPS_LLM_ETC:=/etc/labops-openai-adapter}"
# Каталог токенов входа в ChatGPT: принадлежит пользователю службы, остальным закрыт.
: "${LABOPS_LLM_STATE:=/var/lib/labops-openai-adapter}"
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

# Рекомендуемая модель и короткий список для выбора. Названия из справочника LiteLLM
# (chatgpt/*); какие из них доступны на конкретном тарифе, решает OpenAI.
LLM_DEFAULT_MODEL="gpt-5.5"
LLM_MODEL_CHOICES=("gpt-5.5" "gpt-5.4" "gpt-5.3-codex")

# llm_ask_inputs - модель: из окружения, иначе выбор цифрой (Enter - рекомендуемая).
# Без терминала берётся рекомендуемая: вопрос там задать некому.
llm_ask_inputs() {
  local answer i
  if [ -z "${LABOPS_OPENAI_MODEL:-}" ]; then
    if [ -t 0 ]; then
      echo "Какую модель ChatGPT использовать?"
      for i in "${!LLM_MODEL_CHOICES[@]}"; do
        echo "  $((i + 1))) ${LLM_MODEL_CHOICES[$i]}$([ "${LLM_MODEL_CHOICES[$i]}" = "$LLM_DEFAULT_MODEL" ] && echo '  (рекомендуется)')"
      done
      printf "Номер или Enter: "
      read -r answer
      case "$answer" in
        ""|*[!0-9]*) LABOPS_OPENAI_MODEL="$LLM_DEFAULT_MODEL" ;;
        *) LABOPS_OPENAI_MODEL="${LLM_MODEL_CHOICES[$((answer - 1))]:-$LLM_DEFAULT_MODEL}" ;;
      esac
    else
      LABOPS_OPENAI_MODEL="$LLM_DEFAULT_MODEL"
    fi
    export LABOPS_OPENAI_MODEL
  fi
  if ! llm_valid_model "$LABOPS_OPENAI_MODEL"; then
    warn "имя модели '$LABOPS_OPENAI_MODEL' содержит недопустимые символы"
    return 1
  fi
}

# llm_ensure_user - системный пользователь без входа и без домашнего каталога.
llm_ensure_user() {
  id "$LABOPS_LLM_USER" >/dev/null 2>&1 \
    || $SUDO useradd --system --no-create-home --shell /usr/sbin/nologin "$LABOPS_LLM_USER" \
    || return 1
  # Токены входа в ChatGPT: каталог только для пользователя службы.
  $SUDO install -d -m 700 -o "$LABOPS_LLM_USER" "$LABOPS_LLM_STATE"
}

# llm_as_service_user <команда...> - запуск от пользователя службы (у него нет оболочки входа).
llm_as_service_user() {
  if [ -n "${SUDO:-}" ]; then
    $SUDO -u "$LABOPS_LLM_USER" "$@"
  else
    runuser -u "$LABOPS_LLM_USER" -- "$@"
  fi
}

# llm_login - вход в ChatGPT по коду устройства. Если токены уже есть и живы, вопросов нет.
# Печать ссылки и кода делает сам LiteLLM; вывод не перехватываем - его читает человек.
LLM_LOGIN_PY="from litellm.llms.chatgpt.authenticator import Authenticator; Authenticator().get_access_token()"
llm_login() {
  echo
  echo "  Сейчас нужно один раз подтвердить вход в ChatGPT. Ниже появятся ссылка и код:"
  echo "  откройте ссылку в браузере, где вы вошли в свой аккаунт OpenAI, и введите код."
  echo "  Ждать подтверждения установщик будет до 15 минут."
  echo
  if ! llm_as_service_user env CHATGPT_TOKEN_DIR="$LABOPS_LLM_STATE" HOME="$LABOPS_LLM_STATE" \
       LITELLM_LOCAL_MODEL_COST_MAP=True \
       "$LABOPS_LLM_DIR/.venv/bin/python" -c "$LLM_LOGIN_PY"; then
    warn "вход в ChatGPT не завершён - запустите установку ещё раз"
    return 1
  fi
  if ! $SUDO test -s "$LABOPS_LLM_STATE/auth.json"; then
    warn "после входа нет файла токенов $LABOPS_LLM_STATE/auth.json"
    return 1
  fi
  $SUDO chmod 600 "$LABOPS_LLM_STATE/auth.json" || true
  ok "вход в ChatGPT выполнен"
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
    echo "LITELLM_MASTER_KEY=$key"
    echo "CHATGPT_TOKEN_DIR=$LABOPS_LLM_STATE"
    # Не качать таблицу цен из интернета при каждом старте: адаптер ходит только в ChatGPT.
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
Description=LabOps OpenAI adapter (LiteLLM: Anthropic Messages -> ChatGPT subscription)
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
  llm_ensure_user || { warn "не создан пользователь или каталог токенов $LABOPS_LLM_USER"; return 1; }
  llm_install_code "$py" || return 1
  llm_login || return 1
  llm_write_config || { warn "не записан config.yaml"; return 1; }
  llm_write_env || { warn "не записан env-файл адаптера"; return 1; }
  llm_install_unit || { warn "юнит $LABOPS_LLM_UNIT не запущен"; return 1; }
  llm_wait_ready || return 1
  llm_share_key "$user" "$home" || { warn "ключ шлюза не передан агентам"; return 1; }
  note "модель: $LABOPS_OPENAI_MODEL. Перевести агентов на адаптер: bash orchestration/openai-adapter-wire.sh <агент>"
}
