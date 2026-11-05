#!/usr/bin/env bash
# Unit tests for openai-adapter-wire.sh - перевод агента на адаптер и откат.
# Лаборатория во временном каталоге, systemctl подменён; настоящие агенты не затрагиваются.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

LAB="$TMP/lab"; AGENT="dev"
WS="$LAB/$AGENT/.claude"
CHANNEL="$LAB/shared/state/$AGENT/telegram/channel.env"
PII="$WS/secrets/pii-proxy.env"
SHARED="$LAB/shared/secrets/openai-adapter.env"
TOKEN="sk-0011223344556677"
CALLS="$TMP/calls.log"; : > "$CALLS"
printf '#!/usr/bin/env bash\necho "systemctl $*" >> "%s"\n' "$CALLS" > "$TMP/systemctl"
chmod +x "$TMP/systemctl"

mkdir -p "$WS/secrets" "$(dirname "$CHANNEL")" "$(dirname "$SHARED")"
cat > "$WS/settings.json" <<'E'
{
  "model": "sonnet",
  "env": {"ANTHROPIC_BASE_URL": "http://127.0.0.1:6300", "DISABLE_ERROR_REPORTING": "1"},
  "permissions": {"deny": ["Bash(sudo *)"]}
}
E
chmod 600 "$WS/settings.json"
printf 'PII_PROXY_PORT=6300\nPII_PROXY_UPSTREAM=https://api.anthropic.com\nPII_PROXY_AGENT_ID=dev\n' > "$PII"
printf 'TELEGRAM_BOT_TOKEN=123:abc\n' > "$CHANNEL"
printf 'ANTHROPIC_AUTH_TOKEN=%s\nLABOPS_OPENAI_MODEL=gpt-test-1\nLABOPS_LLM_PORT=4000\n' "$TOKEN" > "$SHARED"

wire() { CLAUDE_LAB="$LAB" WIRE_SYSTEMCTL="$TMP/systemctl" bash "$HERE/openai-adapter-wire.sh" "$@"; }
jget() { python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$WS/settings.json" "$1"; }

ORIG_SETTINGS="$(cat "$WS/settings.json")"; ORIG_PII="$(cat "$PII")"; ORIG_CH="$(cat "$CHANNEL")"

# 1. Перевод на адаптер.
OUT="$(wire "$AGENT" 2>&1)" || fail "перевод не прошёл: $OUT"
[ "$(jget 'd["model"]')" = "gpt-test-1" ] || fail "модель не сменилась"
[ "$(jget 'd["env"]["DISABLE_ERROR_REPORTING"]')" = "1" ] || fail "чужие ключи env потеряны"
[ "$(jget 'd["permissions"]["deny"][0]')" = "Bash(sudo *)" ] || fail "потеряны permissions"
[ "$(jget 'd["env"]["ANTHROPIC_BASE_URL"]')" = "http://127.0.0.1:6300" ] \
  || fail "при наличии pii-proxy ANTHROPIC_BASE_URL агента менять нельзя"
grep -qx 'PII_PROXY_UPSTREAM=http://127.0.0.1:4000' "$PII" || fail "upstream pii-proxy не переключён"
grep -qx 'PII_PROXY_PORT=6300' "$PII" || fail "потеряны остальные строки env pii-proxy"
grep -qx "ANTHROPIC_AUTH_TOKEN=$TOKEN" "$CHANNEL" || fail "токен шлюза не записан в channel.env"
grep -qx 'TELEGRAM_BOT_TOKEN=123:abc' "$CHANNEL" || fail "потерян токен бота в channel.env"
[ "$(stat -c %a "$CHANNEL")" = "600" ] || fail "права channel.env не 600"
[ "$(stat -c %a "$PII")" = "600" ] || fail "права env pii-proxy не 600"
grep -qx 'systemctl --user restart labops-pii-proxy@dev.service' "$CALLS" || fail "pii-proxy не перезапущен"
echo "$OUT" | grep -qF "$TOKEN" && fail "токен шлюза попал в вывод"
grep -qF "$TOKEN" "$CALLS" && fail "токен шлюза попал в командную строку"
[ -d "$WS/backup-openai-adapter" ] || fail "нет каталога бэкапа"

# 2. Повтор идемпотентен и не затирает оригиналы в бэкапе.
wire "$AGENT" >/dev/null 2>&1 || fail "повторный перевод не прошёл"
[ "$(grep -c '^ANTHROPIC_AUTH_TOKEN=' "$CHANNEL")" = "1" ] || fail "токен дублируется"
[ "$(grep -c '^PII_PROXY_UPSTREAM=' "$PII")" = "1" ] || fail "upstream дублируется"

# 3. Откат возвращает исходные файлы байт в байт.
wire "$AGENT" --revert >/dev/null 2>&1 || fail "откат не прошёл"
[ "$(cat "$WS/settings.json")" = "$ORIG_SETTINGS" ] || fail "settings.json не восстановлен"
[ "$(cat "$PII")" = "$ORIG_PII" ] || fail "env pii-proxy не восстановлен"
[ "$(cat "$CHANNEL")" = "$ORIG_CH" ] || fail "channel.env не восстановлен"

# 4. Агент без pii-proxy: ANTHROPIC_BASE_URL в settings.json указывает на адаптер.
rm -rf "$WS/backup-openai-adapter"; rm -f "$PII"
OUT="$(wire "$AGENT" 2>&1)" || fail "перевод без pii-proxy не прошёл"
[ "$(jget 'd["env"]["ANTHROPIC_BASE_URL"]')" = "http://127.0.0.1:4000" ] || fail "нет base_url адаптера"
echo "$OUT" | grep -q "нет pii-proxy" || fail "нет предупреждения про отсутствие маскирования"

# 5. Защита от ошибок: чужое имя, нет адаптера, откат без бэкапа.
wire '../etc' >/dev/null 2>&1 && fail "принято недопустимое имя агента"
rm -f "$SHARED"
wire "$AGENT" >/dev/null 2>&1 && fail "перевод без установленного адаптера"
rm -rf "$WS/backup-openai-adapter"
wire "$AGENT" --revert >/dev/null 2>&1 && fail "откат без бэкапа должен падать"

echo "OK: openai-adapter-wire.sh - все проверки пройдены"
