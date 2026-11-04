#!/usr/bin/env bash
set -euo pipefail

# Локальная расшифровка голоса: сервис voice-transcriber (faster-whisper) на этом же хосте.
# Аудио уходит ТОЛЬКО на loopback-адрес; внешних провайдеров нет.
# Использование: transcribe.sh /path/to/file.ogg [язык|auto]

DEFAULT_URL="http://127.0.0.1:8310"
MAX_TIME_SEC=180

FILE_PATH="${1:-}"
LANGUAGE="${2:-ru}"

if [ -z "$FILE_PATH" ]; then
  echo "ERROR: не указан путь к файлу" >&2
  echo "Usage: transcribe.sh /path/to/file.ogg [язык|auto]" >&2
  exit 1
fi
if [ ! -f "$FILE_PATH" ]; then
  echo "ERROR: файл не найден: $FILE_PATH" >&2
  exit 1
fi
case "$LANGUAGE" in
  auto|[a-z][a-z]|[a-z][a-z][a-z]) ;;
  *) echo "ERROR: язык — код вроде ru или auto" >&2; exit 1 ;;
esac

URL="${VOICE_TRANSCRIBER_URL:-$DEFAULT_URL}"
URL="${URL%/}"
# Адрес обязан вести на этот же хост, иначе аудио ушло бы наружу
case "$URL" in
  http://127.0.0.1|http://127.0.0.1:*) ;;
  http://localhost|http://localhost:*) ;;
  "http://[::1]"|"http://[::1]:"*) ;;
  *) echo "ERROR: VOICE_TRANSCRIBER_URL должен быть loopback-адресом (http://127.0.0.1:порт)" >&2; exit 1 ;;
esac

# Токен: из окружения (его кладёт agent-env.sh) или из общего файла секретов
SECRETS_DIR="${SHARED_SECRETS:-$HOME/.claude-lab/shared/secrets}"
if [ -n "${VOICE_TRANSCRIBER_TOKEN:-}" ]; then
  TOKEN="$VOICE_TRANSCRIBER_TOKEN"
elif [ -f "$SECRETS_DIR/voice-transcriber-token" ]; then
  TOKEN="$(cat "$SECRETS_DIR/voice-transcriber-token")"
else
  echo "ERROR: нет токена. Задайте VOICE_TRANSCRIBER_TOKEN или положите его в $SECRETS_DIR/voice-transcriber-token" >&2
  exit 1
fi

RESPONSE_FILE="$(mktemp)"
trap 'rm -f "$RESPONSE_FILE"' EXIT

# Заголовок с токеном передаётся через stdin, чтобы токен не светился в `ps`
HTTP_CODE="$(printf 'Authorization: Bearer %s\n' "$TOKEN" | curl -s -o "$RESPONSE_FILE" \
  -w '%{http_code}' --max-time "$MAX_TIME_SEC" \
  -X POST "$URL/transcribe?language=$LANGUAGE" \
  -H @- -H 'Content-Type: application/octet-stream' \
  --data-binary "@$FILE_PATH")" || HTTP_CODE="000"

if [ "$HTTP_CODE" = "200" ]; then
  python3 -c 'import json,sys; print("Transcript: " + json.load(open(sys.argv[1]))["text"])' "$RESPONSE_FILE"
else
  echo "ERROR: voice-transcriber вернул HTTP $HTTP_CODE (000 — сервис не отвечает)" >&2
  exit 1
fi
