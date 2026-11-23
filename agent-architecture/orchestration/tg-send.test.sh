#!/usr/bin/env bash
# Юнит-тест tg-send.sh: адрес Bot API — TELEGRAM_API_ROOT из окружения, затем из channel.env,
# иначе api.telegram.org. Сети нет: curl подменён и пишет, куда его позвали.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

export CLAUDE_LAB="$TMP/lab"
CH_DIR="$CLAUDE_LAB/shared/state/dev/telegram"
mkdir -p "$CH_DIR" "$TMP/bin"
FAKE_TOKEN="123456:TEST"
printf 'TELEGRAM_BOT_TOKEN=%s\nTELEGRAM_ALLOWED_USER_IDS=42\n' "$FAKE_TOKEN" > "$CH_DIR/channel.env"

cat > "$TMP/bin/curl" <<'MOCK'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in http*) printf '%s\n' "$a" >> "$CURL_LOG" ;; esac; done
echo '{"ok":true,"result":{"message_id":7}}'
MOCK
chmod +x "$TMP/bin/curl"
export CURL_LOG="$TMP/curl.log"

# send [api-root] — отправить через tg-send.sh; без аргумента TELEGRAM_API_ROOT в окружении нет.
send() {
  if [ -n "${1:-}" ]; then
    env TELEGRAM_API_ROOT="$1" PATH="$TMP/bin:$PATH" bash "$HERE/tg-send.sh" dev "привет"
  else
    env -u TELEGRAM_API_ROOT PATH="$TMP/bin:$PATH" bash "$HERE/tg-send.sh" dev "привет"
  fi >/dev/null
  tail -n1 "$CURL_LOG"
}

: > "$CURL_LOG"
[ "$(send)" = "https://api.telegram.org/bot$FAKE_TOKEN/sendMessage" ] \
  || fail "по умолчанию — облако Telegram: $(send)"

printf 'TELEGRAM_API_ROOT=http://127.0.0.1:28081/\n' >> "$CH_DIR/channel.env"
[ "$(send)" = "http://127.0.0.1:28081/bot$FAKE_TOKEN/sendMessage" ] || fail "адрес из channel.env"

[ "$(send http://127.0.0.1:29090)" = "http://127.0.0.1:29090/bot$FAKE_TOKEN/sendMessage" ] \
  || fail "окружение главнее channel.env"

echo "OK: tg-send.test.sh"
