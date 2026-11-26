#!/usr/bin/env bash
# Ответы new-agent.sh, когда спросить некого.
#
# Скилл create-agent запускает new-agent.sh из Bash-инструмента агента: stdin
# там не терминал, и каждый вопрос, для которого агент забыл передать
# переменную, молча получал значение по умолчанию. Опаснее всего — пустой
# TELEGRAM_ALLOWED_USER_IDS: бот отвечает любому, кто его найдёт, а агент
# работает с --dangerously-skip-permissions, то есть выполняет команды на
# сервере. Установка при этом заканчивалась строкой в сводке «не всё включено».
# Забытый AGENT_NAME давал Developer и падение на «уже существует».
#
# Поэтому без живого ввода недостающие ответы проверяются до того, как создано
# хоть что-то (токен в памяти, воркспейс, канал), и скрипт останавливается.

# shellcheck shell=bash

# shellcheck source=ui.sh
. "$(dirname "${BASH_SOURCE[0]}")/ui.sh"

# input_is_live — вопросы есть кому задать: не NONINTERACTIVE и stdin — терминал.
input_is_live() {
  [ "${NONINTERACTIVE:-0}" != "1" ] && [ -t 0 ]
}

# valid_allowlist <ids> — Telegram id через запятую; у групп отрицательные (-100…).
valid_allowlist() {
  printf '%s' "$1" | grep -qE '^-?[0-9]+(,-?[0-9]+)*$'
}

# valid_agent_id <id> — служебный id агента: латиница, цифры, дефис, до 31 символа (папки,
# юнит, tmux). Под LC_ALL=C: в UTF-8 диапазон [a-z] у некоторых локалей ловит и не-латиницу.
valid_agent_id() {
  printf '%s' "$1" | LC_ALL=C grep -qxE '[a-z0-9][a-z0-9-]{0,30}'
}

# valid_agent_name <имя> — как агента зовут в заголовке идентичности: хоть по-русски, до 40
# символов, без | & \ и переводов строк (установщик подставляет имя через sed).
valid_agent_name() {
  local n="$1"
  [ -n "$n" ] && [ "${#n}" -le 40 ] || return 1
  case "$n" in *'|'*|*'&'*|*'\'*|*$'\n'*|*$'\r'*) return 1 ;; esac
  return 0
}

# derive_agent_id <имя> — id из имени (нижний регистр, пробел → дефис); пусто, если так он
# не получается (кириллица, знаки): тогда оператор называет id сам, NEW_AGENT_ID. Раньше id
# выводился из имени всегда, и агента нельзя было назвать «Игорь».
derive_agent_id() {
  local id
  id="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')"
  if valid_agent_id "$id"; then printf '%s\n' "$id"; fi
  return 0
}

# Webhook-порты плагина: первый свободный начиная с 6000, не дальше диапазона.
WEBHOOK_PORT_BASE=6000
WEBHOOK_PORT_SPAN=100

# webhook_port_listening <port> — порт уже кто-то слушает на хосте (любой адрес). Без ss — нет.
webhook_port_listening() {
  command -v ss >/dev/null 2>&1 || return 1
  ss -ltnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${1}\$"
}

# pick_webhook_port <lab-dir> [base] — первый порт, не записанный ни в один channel.env роя и
# не занятый на хосте. Раньше смотрели только channel.env: порт, занятый чужим процессом
# (песочница, другой сервис), доставался новому агенту, и его канал не поднимался.
pick_webhook_port() {
  local lab="$1" base="${2:-$WEBHOOK_PORT_BASE}" port i
  for i in $(seq 0 "$WEBHOOK_PORT_SPAN"); do
    port=$(( base + i ))
    if grep -rqsE "^TELEGRAM_WEBHOOK_PORT=${port}\$" "$lab"/shared/state/*/telegram/channel.env \
      2>/dev/null; then
      continue
    fi
    webhook_port_listening "$port" && continue
    printf '%s\n' "$port"
    return 0
  done
  return 1
}

# unattended_input_errors — по строке на каждый недостающий ответ; пусто — всё есть.
unattended_input_errors() {
  [ -n "${AGENT_NAME:-}" ] \
    || echo "AGENT_NAME — имя агента (иначе возьмётся Developer)"
  if [ -n "${AGENT_NAME:-}" ]; then
    valid_agent_name "$AGENT_NAME" \
      || echo "AGENT_NAME — до 40 символов, без | & \\ и переводов строк"
    if [ -n "${NEW_AGENT_ID:-}" ]; then
      valid_agent_id "$NEW_AGENT_ID" \
        || echo "NEW_AGENT_ID — только латиница, цифры и дефис, до 31 символа"
    elif [ -z "$(derive_agent_id "$AGENT_NAME")" ]; then
      echo "NEW_AGENT_ID — служебный id латиницей (папка, юнит): из имени «$AGENT_NAME» он не получается"
    fi
  fi
  if [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
    if [ -z "${TELEGRAM_ALLOWED_USER_IDS:-}" ]; then
      echo "TELEGRAM_ALLOWED_USER_IDS — Telegram user_id оператора (без него бот ответит всем)"
    elif ! valid_allowlist "$TELEGRAM_ALLOWED_USER_IDS"; then
      echo "TELEGRAM_ALLOWED_USER_IDS — значение не похоже на id (цифры через запятую, у групп -100…)"
    fi
  fi
  return 0
}

# require_unattended_inputs — без живого ввода останавливает скрипт, если
# недостаёт ответов, которые нельзя подставить по умолчанию.
require_unattended_inputs() {
  local errors
  input_is_live && return 0
  errors="$(unattended_input_errors)"
  [ -z "$errors" ] && return 0
  err "вопросы задать некому (NONINTERACTIVE=1 или stdin не терминал), а этих переменных нет:"
  printf '%s\n' "$errors" | sed 's/^/    • /' >&2
  die "передайте их в окружении и запустите снова — ничего не создано"
}
