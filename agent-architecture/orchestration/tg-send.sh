#!/usr/bin/env bash
# tg-send.sh — надёжная проактивная отправка сообщения Оператору от имени агента.
# Для случаев БЕЗ входящего <channel> (дайджесты, cron-инжекты), где инструмент
# reply недоступен. Возвращает РЕАЛЬНЫЙ статус Telegram API (exit!=0 при ошибке) —
# не выдумывать доставку.
# Usage: tg-send.sh <agent> <text>   |   echo "<text>" | tg-send.sh <agent> -
set -euo pipefail

source "$(dirname "$0")/lib/agents.sh"

AGENT="${1:?agent required}"

# Куда слать: chat_id оператора. Берём из channel.env (первый из allowed-id),
# либо переопределяем через TG_CHAT_ID. Ничего не хардкодим.
CHAT_ID="${TG_CHAT_ID:-}"
# `|| true`: под set -e -o pipefail отсутствующая переменная роняла скрипт молча, не давая
# дойти до запасного TELEGRAM_ALLOWED_USER_IDS.
[ -n "$CHAT_ID" ] || CHAT_ID="$(agent_channel_var "$AGENT" TELEGRAM_ALLOWED_CHAT_IDS 2>/dev/null | cut -d, -f1 || true)"
[ -n "$CHAT_ID" ] || CHAT_ID="$(agent_channel_var "$AGENT" TELEGRAM_ALLOWED_USER_IDS 2>/dev/null | cut -d, -f1 || true)"
[ -n "$CHAT_ID" ] || { echo "no operator chat_id for $AGENT (set TG_CHAT_ID or TELEGRAM_ALLOWED_CHAT_IDS in channel.env)" >&2; exit 2; }

TOK="$(agent_bot_token "$AGENT")" || { echo "Unknown agent: $AGENT" >&2; exit 2; }

if [ "${2:-}" = "-" ]; then TEXT="$(cat)"; else TEXT="${2:?text required}"; fi

# Адрес Bot API — как у плагина: TELEGRAM_API_ROOT из окружения, затем из channel.env агента
# (локальный сервер Bot API, фейковый API песочницы), иначе облако Telegram. Раньше адрес был
# зашит, и итог /doctor из песочницы уходил в настоящий api.telegram.org.
TELEGRAM_API_ROOT_DEFAULT="https://api.telegram.org"
API_ROOT="${TELEGRAM_API_ROOT:-}"
[ -n "$API_ROOT" ] || API_ROOT="$(agent_channel_var "$AGENT" TELEGRAM_API_ROOT 2>/dev/null || true)"
API_ROOT="${API_ROOT:-$TELEGRAM_API_ROOT_DEFAULT}"
API_ROOT="${API_ROOT%/}"

RESP=$(curl -s -X POST "${API_ROOT}/bot${TOK}/sendMessage" \
  --data-urlencode "chat_id=${CHAT_ID}" \
  --data-urlencode "text=${TEXT}" \
  -d "disable_web_page_preview=true")

if echo "$RESP" | grep -q '"ok":true'; then
  MID=$(echo "$RESP" | grep -o '"message_id":[0-9]*' | head -1 | grep -o '[0-9]*')
  echo "OK sent (message_id=$MID)"
  exit 0
else
  echo "SEND FAILED: $RESP" >&2
  exit 1
fi
