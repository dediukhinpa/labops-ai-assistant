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
[ -n "$CHAT_ID" ] || CHAT_ID="$(agent_channel_var "$AGENT" TELEGRAM_ALLOWED_CHAT_IDS 2>/dev/null | cut -d, -f1)"
[ -n "$CHAT_ID" ] || CHAT_ID="$(agent_channel_var "$AGENT" TELEGRAM_ALLOWED_USER_IDS 2>/dev/null | cut -d, -f1)"
[ -n "$CHAT_ID" ] || { echo "no operator chat_id for $AGENT (set TG_CHAT_ID or TELEGRAM_ALLOWED_CHAT_IDS in channel.env)" >&2; exit 2; }

TOK="$(agent_bot_token "$AGENT")" || { echo "Unknown agent: $AGENT" >&2; exit 2; }

if [ "${2:-}" = "-" ]; then TEXT="$(cat)"; else TEXT="${2:?text required}"; fi

RESP=$(curl -s -X POST "https://api.telegram.org/bot${TOK}/sendMessage" \
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
