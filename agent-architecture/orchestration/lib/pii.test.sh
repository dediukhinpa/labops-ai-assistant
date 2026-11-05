#!/usr/bin/env bash
# Юнит-тесты lib/pii.sh: порты, определение прокси по settings.json, gate, опрос session_stuck.
# Сеть не нужна: /health отвечает локальный python-сервер на случайном порту.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
SRV_PID=""
trap 'rm -rf "$TMP"; [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null' EXIT
export CLAUDE_LAB="$TMP/lab"
mkdir -p "$CLAUDE_LAB/alpha/.claude/secrets" "$CLAUDE_LAB/beta/.claude/secrets" \
  "$CLAUDE_LAB/alpha/.claude/state"
# shellcheck disable=SC1091
source "$HERE/pii.sh"

fail() { echo "FAIL: $1"; exit 1; }
eq() { [ "$1" = "$2" ] || fail "$3: ожидали '$2', получили '$1'"; }

# 1. pii_enabled
SKIP_PII_PROXY=1 pii_enabled && fail "SKIP_PII_PROXY=1 должен выключать"
pii_enabled || fail "по умолчанию включено"

# 2. порт из env-файла, занятые порты пропускаются
echo "PII_PROXY_PORT=6311" > "$(pii_proxy_env_file alpha)"
eq "$(pii_proxy_port alpha)" 6311 "порт из env-файла"
echo "PII_PROXY_PORT=6300" > "$(pii_proxy_env_file beta)"
eq "$(pii_pick_port gamma)" 6301 "gamma: 6300 занят beta -> следующий"

# 3. определение прокси по settings.json
printf '{"env":{"ANTHROPIC_BASE_URL":"http://127.0.0.1:6311"}}' \
  > "$CLAUDE_LAB/alpha/.claude/settings.json"
eq "$(pii_agent_base_url alpha)" "http://127.0.0.1:6311" "локальный url"
printf '{"env":{"ANTHROPIC_BASE_URL":"https://api.example.com"}}' \
  > "$CLAUDE_LAB/beta/.claude/settings.json"
eq "$(pii_agent_base_url beta)" "" "внешний url не считается прокси"
eq "$(pii_agent_base_url nobody)" "" "нет settings.json"

# 4. gate: нет прокси - можно; прокси есть, но молчит - нельзя; жив - можно
pii_gate beta || fail "агент без прокси: gate должен пускать"
python3 - "$TMP/port" <<'PY' &
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200 if self.path == "/health" else 404); self.end_headers()
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(s.server_address[1]))
s.serve_forever()
PY
SRV_PID=$!
for _ in $(seq 1 50); do [ -s "$TMP/port" ] && break; sleep 0.1; done
pii_gate alpha && fail "прокси не слушает: gate должен отказать"
printf '{"env":{"ANTHROPIC_BASE_URL":"http://127.0.0.1:%s"}}' "$(cat "$TMP/port")" \
  > "$CLAUDE_LAB/alpha/.claude/settings.json"
pii_gate alpha || fail "прокси жив: gate должен пускать"

# 5. опрос session_stuck: считает только новые строки
eq "$(pii_stuck_poll alpha)" 0 "файла нет"
f="$(pii_stuck_file alpha)"
echo '{"session":"a1","count":3}' >> "$f"
echo '{"session":"b2","count":3}' >> "$f"
eq "$(pii_stuck_poll alpha)" 2 "две новые"
eq "$(pii_stuck_poll alpha)" 0 "повторно нового нет"
echo '{"session":"c3","count":3}' >> "$f"
eq "$(pii_stuck_poll alpha)" 1 "одна новая"

# 6. геопроверка: не RU - предупреждение; RU и нет сети - без предупреждения; всегда код 0
warn() { echo "WARN $*"; }; note() { echo "NOTE $*"; }; ok() { echo "OK $*"; }
PII_GEO_CMD="echo nl" out="$(pii_geo_check)"; rc=$?
[ "$rc" = 0 ] && echo "$out" | grep -q 'WARN.*NL' || fail "не RU должно предупреждать"
PII_GEO_CMD="echo RU" out="$(pii_geo_check)"
echo "$out" | grep -q WARN && fail "RU не должно предупреждать"
PII_GEO_CMD="false" out="$(pii_geo_check)"; rc=$?
[ "$rc" = 0 ] && echo "$out" | grep -q 'NOTE.*пропущена' || fail "нет сети: пропуск без ошибки"
PII_GEO_CMD="echo <html>blocked" out="$(pii_geo_check)"
echo "$out" | grep -q 'NOTE' || fail "мусорный ответ считается неопределённым"

echo "OK: pii.test.sh"
