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

# 3a. агент на Codex: прокси — model_provider в .codex/config.toml (корень без пути бэкенда)
mkdir -p "$CLAUDE_LAB/cx/.codex" "$CLAUDE_LAB/cx/.claude"
printf 'model_provider = "labops-pii"\n[model_providers.labops-pii]\nbase_url = "http://127.0.0.1:6391/backend-api/codex"\n' \
  > "$CLAUDE_LAB/cx/.codex/config.toml"
eq "$(pii_agent_base_url cx)" "http://127.0.0.1:6391" "codex: корень прокси из config.toml"
printf 'model_provider = "openai"\n' > "$CLAUDE_LAB/cx/.codex/config.toml"
eq "$(pii_agent_base_url cx)" "" "codex: провайдер не через прокси"

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

# 4b. режим «через прокси» / «напрямую»: файл режима, предупреждения оператору, старт.
SENT="$TMP/sent.log"
notify_op() { shift; printf '%s\n' "$*" >> "$SENT"; }
export PII_SYSTEMCTL="$TMP/fake-systemctl" PII_REVIVE_WAIT_SEC=0
printf '#!/usr/bin/env bash\necho "$*" >> "%s/revive.log"\n' "$TMP" > "$PII_SYSTEMCTL"
chmod +x "$PII_SYSTEMCTL"
LIVE_URL="http://127.0.0.1:$(cat "$TMP/port")"
# Свободный порт, который никто не слушает: «мёртвый» прокси.
DEAD_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0))
print(s.getsockname()[1])')"
set_proxy() {   # <url> — куда смотрит прокси агента alpha
  printf '{"env":{"ANTHROPIC_BASE_URL":"%s"}}' "$1" > "$CLAUDE_LAB/alpha/.claude/settings.json"
}
eq "$(pii_mode_get alpha)" proxy "режим по умолчанию"
eq "$(pii_proxy_state alpha)" up "прокси жив"
eq "$(pii_proxy_state beta)" none "у beta прокси нет"
set_proxy "http://127.0.0.1:$DEAD_PORT"
eq "$(pii_proxy_state alpha)" down "прокси молчит"

# старт при мёртвом прокси: попытка поднять юнит, затем напрямую и одно предупреждение
: > "$SENT"
eq "$(pii_mode_resolve_start alpha)" direct "старт без прокси - напрямую"
eq "$(pii_mode_get alpha)" direct "режим записан"
grep -q 'labops-pii-proxy@alpha.service' "$TMP/revive.log" || fail "юнит прокси не поднимали"
eq "$(grep -c 'без маскирования\|БЕЗ маскирования' "$SENT")" 1 "одно предупреждение о падении"
# повторный старт в том же состоянии - без нового предупреждения
eq "$(pii_mode_resolve_start alpha)" direct "повторный старт"
eq "$(wc -l < "$SENT" | tr -d ' ')" 1 "повтор не шлёт второе предупреждение"
# прокси поднялся - старт через него и одно сообщение о восстановлении
set_proxy "$LIVE_URL"
eq "$(pii_mode_resolve_start alpha)" proxy "старт с живым прокси"
eq "$(wc -l < "$SENT" | tr -d ' ')" 2 "сообщение о восстановлении"
grep -q 'снова отвечает' "$SENT" || fail "нет текста о восстановлении"
# агент без прокси: файл режима убирается, сообщений нет
pii_mode_write beta direct
eq "$(pii_mode_resolve_start beta)" none "агент без прокси"
[ -e "$(pii_mode_file beta)" ] && fail "у агента без прокси остался файл режима"
eq "$(wc -l < "$SENT" | tr -d ' ')" 2 "агент без прокси не шлёт предупреждений"

# гистерезис работающего агента: одиночный сбой не переключает, PII_DOWN_AFTER_FAILS подряд - да
PII_FAIL_STREAK=0; PII_OK_STREAK=0; : > "$TMP/revive.log"
set_proxy "http://127.0.0.1:$DEAD_PORT"
pii_watch_step alpha
pii_switch_due alpha && fail "один сбой не должен переключать"
grep -q alpha "$TMP/revive.log" || fail "на первом сбое не пробовали поднять прокси"
set_proxy "$LIVE_URL"
pii_watch_step alpha
pii_switch_due alpha && fail "сбой, затем успех - без переключения"
eq "$PII_FAIL_STREAK" 0 "успех сбрасывает счётчик сбоев"
set_proxy "http://127.0.0.1:$DEAD_PORT"; : > "$TMP/revive.log"
for _ in $(seq 1 $(( PII_DOWN_AFTER_FAILS - 1 ))); do
  pii_watch_step alpha
  pii_switch_due alpha && fail "переключение раньше порога"
done
pii_watch_step alpha
pii_switch_due alpha || fail "после $PII_DOWN_AFTER_FAILS сбоев подряд нужно напрямую"
eq "$PII_WANT" direct "нужен режим напрямую"
eq "$(grep -c alpha "$TMP/revive.log")" 1 "юнит поднимаем один раз на серию сбоев"
pii_mode_set alpha "$PII_WANT" || fail "смена режима должна вернуть 0"
pii_mode_set alpha direct && fail "повторная запись того же режима - не смена"
eq "$(wc -l < "$SENT" | tr -d ' ')" 3 "одно предупреждение на падение"
# Текст: последнее сообщение повторяется само, переслать пользователя не просят.
pii_mode_message alpha direct | grep -q "повторяю его уже без прокси" \
  || fail "предупреждение не говорит, что сообщение повторяется"
pii_mode_message alpha direct | grep -q "ещё раз" && fail "предупреждение просит переслать"
pii_watch_step alpha
pii_switch_due alpha && fail "уже напрямую - больше не переключать"
# восстановление: PII_UP_AFTER_OKS удачных подряд
set_proxy "$LIVE_URL"
for _ in $(seq 1 $(( PII_UP_AFTER_OKS - 1 ))); do
  pii_watch_step alpha
  pii_switch_due alpha && fail "возврат раньше порога"
done
pii_watch_step alpha
pii_switch_due alpha || fail "после $PII_UP_AFTER_OKS успехов подряд нужно через прокси"
eq "$PII_WANT" proxy "нужен режим через прокси"
pii_mode_set alpha "$PII_WANT" || fail "возврат через прокси - смена"
eq "$(wc -l < "$SENT" | tr -d ' ')" 4 "одно сообщение о восстановлении"
# смена режима обнуляет счётчики: после возврата на прокси одна неудача не уводит напрямую
eq "$PII_OK_STREAK$PII_FAIL_STREAK" "00" "смена режима сбросила счётчики"
set_proxy "http://127.0.0.1:$DEAD_PORT"
pii_watch_step alpha
pii_switch_due alpha && fail "после возврата на прокси одна неудача не должна переключать"
set_proxy "$LIVE_URL"; pii_watch_step alpha

# Симуляция crash-loop прокси (D): down,down,down → watchdog решает «напрямую» → перезапуск
# агента, на старте юнит прокси поднялся (up) → снова down. Решение watchdog не переигрывается
# стартом, счётчики после смены режима начинаются заново — ни рестарта, ни лишних сообщений.
pii_streak_reset; pii_mode_write alpha proxy; : > "$SENT"
set_proxy "http://127.0.0.1:$DEAD_PORT"
for _ in $(seq 1 "$PII_DOWN_AFTER_FAILS"); do pii_watch_step alpha; done
eq "$PII_WANT" direct "симуляция: после серии неудач нужно напрямую"
# restart_session watchdog: сброс счётчиков и старт с решением watchdog (PII_START_MODE=direct)
pii_streak_reset
set_proxy "$LIVE_URL"   # юнит прокси поднялся на старте
eq "$(PII_START_MODE=direct pii_mode_resolve_start alpha)" direct \
  "старт по решению watchdog не возвращает на прокси по одной удачной проверке"
eq "$(pii_mode_get alpha)" direct "симуляция: режим напрямую"
set_proxy "http://127.0.0.1:$DEAD_PORT"   # прокси снова упал
pii_watch_step alpha
pii_switch_due alpha && fail "симуляция: агент уже напрямую — нового переключения нет"
eq "$(wc -l < "$SENT" | tr -d ' ')" 1 "симуляция: одно предупреждение на весь эпизод"
# прочие перезапуски (keep): агент напрямую напрямую и стартует, даже если прокси ответил
set_proxy "$LIVE_URL"
eq "$(PII_START_MODE=keep pii_mode_resolve_start alpha)" direct "keep: прямой режим сохраняется"
eq "$(wc -l < "$SENT" | tr -d ' ')" 1 "keep: без сообщений"
# keep на прокси при мёртвом прокси — fail-open сразу, без ожидания гистерезиса
pii_mode_write alpha proxy; set_proxy "http://127.0.0.1:$DEAD_PORT"
eq "$(PII_START_MODE=keep pii_mode_resolve_start alpha)" direct "keep: мёртвый прокси на старте — напрямую"
# возврат на прокси — только гистерезисом watchdog
set_proxy "$LIVE_URL"; pii_streak_reset
for _ in $(seq 1 "$PII_UP_AFTER_OKS"); do pii_watch_step alpha; done
eq "$PII_WANT" proxy "возврат на прокси после $PII_UP_AFTER_OKS удачных подряд"
eq "$(PII_START_MODE=proxy pii_mode_resolve_start alpha)" proxy "старт по решению вернуться на прокси"
pii_streak_reset

# агент без прокси: переключать нечего
pii_watch_step beta
eq "$PII_WANT" "" "у агента без прокси нет нужного режима"
pii_switch_due beta && fail "агента без прокси не переключаем"
unset -f notify_op

# 4c. Прокси жив, псевдонимизатор нет (E): /health отвечает 503 с "pseudonymizer":"down" —
# это «недоступен» (напрямую), а сообщение оператору называет причину.
python3 - "$TMP/port503" <<'PY' &
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b'{"status":"degraded","pseudonymizer":"down","reason":"pseudonymizer_unavailable"}'
        self.send_response(503); self.send_header("content-type", "application/json")
        self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(s.server_address[1]))
s.serve_forever()
PY
SRV503_PID=$!
for _ in $(seq 1 50); do [ -s "$TMP/port503" ] && break; sleep 0.1; done
NOPSEUDO_URL="http://127.0.0.1:$(cat "$TMP/port503")"
set_proxy "$NOPSEUDO_URL"
eq "$(pii_proxy_state alpha)" down "псевдонимизатор мёртв — прокси считается недоступным"
eq "$(pii_proxy_down_reason alpha)" pseudonymizer "причина — псевдонимизатор"
set_proxy "http://127.0.0.1:$DEAD_PORT"
eq "$(pii_proxy_down_reason alpha)" proxy "прокси не отвечает — причина прокси"
set_proxy "$NOPSEUDO_URL"
pii_mode_write alpha proxy; : > "$SENT"
notify_op() { shift; printf '%s\n' "$*" >> "$SENT"; }
pii_mode_set alpha direct || fail "смена режима при мёртвом псевдонимизаторе"
grep -q 'сервис псевдонимизации недоступен' "$SENT" || fail "сообщение не называет псевдонимизатор"
grep -q 'БЕЗ маскирования' "$SENT" || fail "сообщение не говорит о немаскированных ПДн"
unset -f notify_op
kill "$SRV503_PID" 2>/dev/null
pii_mode_write alpha proxy; set_proxy "$LIVE_URL"

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

# Адрес сервиса псевдонимизации: по умолчанию прежний 8300, окружение его переопределяет.
eq "$PII_PSEUDONYMIZER_URL_DEFAULT" "http://127.0.0.1:8300" "адрес псевдонимизатора по умолчанию"
eq "$(env -u PII_PSEUDONYMIZER_URL PII_PSEUDONYMIZER_PORT=28300 bash -c \
  ". '$HERE/pii.sh'; printf '%s' \"\$PII_PSEUDONYMIZER_URL_DEFAULT\"")" \
  "http://127.0.0.1:28300" "порт псевдонимизатора из окружения"
eq "$(PII_PSEUDONYMIZER_URL=http://10.0.0.5:9000 bash -c \
  ". '$HERE/pii.sh'; printf '%s' \"\$PII_PSEUDONYMIZER_URL_DEFAULT\"")" \
  "http://10.0.0.5:9000" "адрес псевдонимизатора из окружения"

echo "OK: pii.test.sh"
