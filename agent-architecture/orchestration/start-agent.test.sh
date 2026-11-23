#!/usr/bin/env bash
# Юнит-тест start-agent.sh: pii-proxy не отвечает — агент всё равно стартует, но напрямую, и
# оператор получает одно предупреждение; прокси поднялся — следующий старт через него.
# Решение владельца 23.11.2026 (раньше старт без прокси отменялся).
#
# Живые tmux, claude и Telegram не трогаются: tmux и pkill — заглушки в ~/.local/bin
# подставного HOME (start-agent.sh ставит этот каталог в начало PATH), отправка в Telegram —
# NOTIFY_SEND_CMD, /health — локальный python-сервер.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
SRV_PID=""
trap 'rm -rf "$TMP"; [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null' EXIT

fail() { echo "FAIL: $1"; exit 1; }

# Страховка поверх заглушки tmux: даже если бы настоящий tmux нашёлся раньше неё, он смотрел бы
# в свой сервер во временном каталоге, а не в сервер роя.
# shellcheck source=lib/tmux-test-isolation.sh
. "$HERE/lib/tmux-test-isolation.sh"
tmux_test_isolate "$TMP"

AGENT="probe"
export HOME="$TMP/home" CLAUDE_LAB="$TMP/lab"
WS="$CLAUDE_LAB/$AGENT/.claude"
mkdir -p "$HOME/.local/bin" "$WS/state" "$CLAUDE_LAB/shared/state/$AGENT/telegram"
cat > "$CLAUDE_LAB/shared/state/$AGENT/telegram/channel.env" <<'EOF'
TELEGRAM_BOT_TOKEN=111111:AAtest-token
TELEGRAM_WEBHOOK_TOKEN=test-webhook
TELEGRAM_ALLOWED_USER_IDS=42
TELEGRAM_WEBHOOK_PORT=6098
EOF
chmod 600 "$CLAUDE_LAB/shared/state/$AGENT/telegram/channel.env"

# Заглушки: tmux пишет свои аргументы в журнал, pkill ничего не делает.
cat > "$HOME/.local/bin/tmux" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$TMP/tmux.log"
case "\$1" in has-session) exit 1 ;; esac
exit 0
EOF
printf '#!/usr/bin/env bash\nexit 0\n' > "$HOME/.local/bin/pkill"
printf '#!/usr/bin/env bash\necho "$*" >> "%s/systemctl.log"\n' "$TMP" > "$TMP/systemctl"
cat > "$TMP/send" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$2" >> "$TMP/sent.log"
EOF
chmod +x "$HOME/.local/bin/tmux" "$HOME/.local/bin/pkill" "$TMP/systemctl" "$TMP/send"
export NOTIFY_SEND_CMD="$TMP/send" PII_SYSTEMCTL="$TMP/systemctl" PII_REVIVE_WAIT_SEC=0
export START_READY_TIMEOUT=1 NOTIFY_STATE_DIR="$TMP/notify"

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
LIVE="http://127.0.0.1:$(cat "$TMP/port")"
DEAD="http://127.0.0.1:$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0))
print(s.getsockname()[1])')"
set_proxy() { printf '{"env":{"ANTHROPIC_BASE_URL":"%s"}}' "$1" > "$WS/settings.json"; }
sent_count() { cat "$TMP/sent.log" 2>/dev/null | grep -c . || true; }

# 1. Прокси молчит: старт не отменяется, сессия поднимается, режим напрямую, одно предупреждение.
set_proxy "$DEAD"
ERR="$(bash "$HERE/start-agent.sh" "$AGENT" 2>&1 >/dev/null)"; rc=$?
[ "$rc" -eq 0 ] || fail "без прокси start-agent должен стартовать агента (код $rc): $ERR"
grep -q "^new-session -d -s labops-$AGENT" "$TMP/tmux.log" || fail "сессия не поднята без прокси"
[ "$(cat "$WS/state/pii-mode")" = direct ] || fail "режим напрямую не записан"
printf '%s' "$ERR" | grep -q 'стартует напрямую' || fail "нет предупреждения в журнале старта"
grep -q "labops-pii-proxy@$AGENT.service" "$TMP/systemctl.log" \
  || fail "юнит прокси не пробовали поднять"
[ "$(sent_count)" -eq 1 ] || fail "ожидали одно предупреждение оператору, получили $(sent_count)"
grep -q 'БЕЗ маскирования' "$TMP/sent.log" || fail "предупреждение не говорит о немаскированных ПДн"

# 2. Повторный старт при том же мёртвом прокси (рестарт watchdog) — без второго сообщения.
bash "$HERE/start-agent.sh" "$AGENT" >/dev/null 2>&1 || fail "повторный старт без прокси упал"
[ "$(sent_count)" -eq 1 ] || fail "повторный старт прислал второе предупреждение"

# 3. Прокси поднялся: старт через него, одно сообщение о восстановлении.
set_proxy "$LIVE"
bash "$HERE/start-agent.sh" "$AGENT" >/dev/null 2>&1 || fail "старт с живым прокси упал"
[ "$(cat "$WS/state/pii-mode")" = proxy ] || fail "режим через прокси не записан"
[ "$(sent_count)" -eq 2 ] || fail "ожидали сообщение о восстановлении, всего $(sent_count)"
grep -q 'снова отвечает' "$TMP/sent.log" || fail "нет сообщения о восстановлении"

# 4. Живой прокси с самого начала — никаких сообщений (поведение прежнее).
rm -f "$WS/state/pii-mode" "$TMP/sent.log"
bash "$HERE/start-agent.sh" "$AGENT" >/dev/null 2>&1 || fail "обычный старт упал"
[ "$(sent_count)" -eq 0 ] || fail "при живом прокси оператору ничего не шлём"

# 5. Перезапуск watchdog'ом (PII_START_MODE=keep): агент напрямую так и стартует напрямую, даже
#    если прокси на старте ответил — возврат только гистерезисом watchdog.
printf 'direct\n' > "$WS/state/pii-mode"; rm -f "$TMP/sent.log"
LABOPS_START_FROM_WATCHDOG=1 PII_START_MODE=keep bash "$HERE/start-agent.sh" "$AGENT" \
  >/dev/null 2>&1 || fail "перезапуск watchdog'ом упал"
[ "$(cat "$WS/state/pii-mode")" = direct ] || fail "перезапуск вернул агента на прокси в обход гистерезиса"
[ "$(sent_count)" -eq 0 ] || fail "перезапуск в том же режиме не должен ничего слать"

# 6. Идёт остановка (маркер stop-agent): старт от watchdog отменяется, ручной — снимает маркер.
: > "$TMP/tmux.log"; date +%s > "$WS/state/stopping"
LABOPS_START_FROM_WATCHDOG=1 bash "$HERE/start-agent.sh" "$AGENT" >/dev/null 2>&1 \
  || fail "отмена старта при остановке должна быть без ошибки"
grep -q '^new-session' "$TMP/tmux.log" && fail "watchdog поднял сессию во время остановки"
[ -f "$WS/state/stopping" ] || fail "старт от watchdog не должен снимать маркер остановки"
bash "$HERE/start-agent.sh" "$AGENT" >/dev/null 2>&1 || fail "ручной старт после остановки упал"
grep -q '^new-session' "$TMP/tmux.log" || fail "ручной старт не поднял сессию"
[ -f "$WS/state/stopping" ] && fail "ручной старт не снял маркер остановки"

echo "OK: start-agent.test.sh — 6 сценариев"
