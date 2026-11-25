#!/usr/bin/env bash
# watchdog-stop.test.sh — `systemctl stop` действительно останавливает агента.
#
# systemd сначала исполняет ExecStop (stop-agent.sh), пока watchdog ещё жив, и только потом шлёт
# ему SIGTERM. Проверяется настоящий watchdog.sh (копия каталога orchestration, start-agent.sh в
# ней — заглушка, tmux — заглушка в PATH):
#   1. codex: при маркере остановки цикл надзора больше не перезапускает агента;
#   2. claude: то же; маркер прошлой остановки снимается при старте watchdog;
#   3. SIGTERM, пока watchdog ждёт start-agent: watchdog выходит с кодом 0 и снимает start-agent
#      (раньше тот переживал главный процесс юнита и поднимал агента после остановки).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
WD_PID=""
cleanup() {
  if [ -n "$WD_PID" ]; then kill -9 "$WD_PID" 2>/dev/null || true; fi
  if [ -f "$TMP/slow.pid" ]; then kill -9 "$(cat "$TMP/slow.pid")" 2>/dev/null || true; fi
  if [ -f "$TMP/sleep.pid" ]; then kill -9 "$(cat "$TMP/sleep.pid")" 2>/dev/null || true; fi
  rm -rf "$TMP"
}
trap cleanup EXIT

# shellcheck source=lib/tmux-test-isolation.sh
. "$HERE/lib/tmux-test-isolation.sh"
tmux_test_isolate "$TMP"

pass=0; fail=0
ok()  { echo "✓ $*"; pass=$((pass + 1)); }
bad() { echo "✗ $*"; fail=$((fail + 1)); }

AGENT="wdstop-probe"
export HOME="$TMP/home" CLAUDE_LAB="$TMP/lab"
WS="$CLAUDE_LAB/$AGENT/.claude"
mkdir -p "$HOME" "$WS/state" "$CLAUDE_LAB/shared" "$TMP/bin"

# Копия orchestration с заглушкой start-agent.sh: пишет, с каким окружением её позвал watchdog,
# и «поднимает сессию» (файл session-alive). При файле slow — висит, как start-agent в ожидании
# готовности канала.
cp -r "$HERE" "$TMP/orch"
cat > "$TMP/orch/start-agent.sh" <<EOF
#!/usr/bin/env bash
echo "start from_wd=\${LABOPS_START_FROM_WATCHDOG:-} mode=\${PII_START_MODE:-}" >> "$TMP/starts.log"
if [ -f "$TMP/slow" ]; then
  echo \$\$ > "$TMP/slow.pid"
  sleep 30 &
  echo \$! > "$TMP/sleep.pid"
  wait
fi
: > "$TMP/session-alive"
EOF
chmod +x "$TMP/orch/start-agent.sh"

# Заглушка tmux: сессия «жива», пока есть файл session-alive; экран — чистый промпт.
cat > "$TMP/bin/tmux" <<EOF
#!/usr/bin/env bash
case "\$1" in
  has-session) [ -f "$TMP/session-alive" ] ;;
  capture-pane) printf '❯\xc2\xa0\n' ;;
  *) exit 0 ;;
esac
EOF
# Поддельный codex: вход по подписке есть.
printf '#!/usr/bin/env bash\necho "Logged in using ChatGPT"\n' > "$TMP/bin/codex"
chmod +x "$TMP/bin/tmux" "$TMP/bin/codex"
export PATH="$TMP/bin:$PATH" CODEX_BIN="$TMP/bin/codex"
export WATCHDOG_TICK_SEC=0.1 WATCHDOG_TICKS=2 WATCHDOG_TG_ALERTS=0 NOTIFY_STATE_DIR="$TMP/notify"

starts() { grep -c . "$TMP/starts.log" 2>/dev/null || true; }
wait_for() {   # <секунд> <команда...> — ждать, пока команда не вернёт 0
  local deadline=$(( $(date +%s) + $1 )); shift
  while ! "$@"; do
    [ "$(date +%s)" -lt "$deadline" ] || return 1
    sleep 0.1
  done
}
starts_at_least() { [ "$(starts)" -ge "$1" ]; }
wd_gone() { ! kill -0 "$WD_PID" 2>/dev/null; }

run_watchdog() {
  bash "$TMP/orch/watchdog.sh" "$AGENT" >> "$TMP/watchdog.log" 2>&1 &
  WD_PID=$!
}

# stop_watchdog — SIGTERM; код выхода — в WD_RC («alive», если не вышел). Не через $(...):
# дождаться чужого (не своего) ребёнка подоболочка не может.
WD_RC=""
stop_watchdog() {
  WD_RC=0
  kill -TERM "$WD_PID" 2>/dev/null || true
  if ! wait_for 5 wd_gone; then WD_RC=alive; return 0; fi
  wait "$WD_PID" 2>/dev/null || WD_RC=$?
  WD_PID=""
}

# Маркер остановки соблюдается: пока его нет — рестарты идут, после — ни одного.
check_marker_stops_restarts() {   # <харнес>
  local n
  if wait_for 10 starts_at_least 2; then
    ok "$1: без маркера watchdog перезапускает агента (база)"
  else
    bad "$1: watchdog не перезапускал агента даже без маркера — тест ничего не проверит"
  fi
  date +%s > "$WS/state/stopping"
  sleep 0.5
  n="$(starts)"
  sleep 1.5
  if [ "$(starts)" -eq "$n" ]; then
    ok "$1: при маркере остановки рестартов нет"
  else
    bad "$1: watchdog перезапустил агента во время остановки ($n → $(starts))"
  fi
  if grep -q 'from_wd=1' "$TMP/starts.log"; then
    ok "$1: start-agent знает, что его зовёт watchdog"
  else
    bad "$1: watchdog не передал LABOPS_START_FROM_WATCHDOG"
  fi
  if grep -q 'mode=keep' "$TMP/starts.log"; then
    ok "$1: перезапуск сохраняет режим pii-proxy (keep)"
  else
    bad "$1: перезапуск не передал PII_START_MODE=keep"
  fi
}

# ── 1. codex: драйвера нет → watchdog перезапускает каждый проход, пока нет маркера.
printf 'HARNESS=codex\n' > "$CLAUDE_LAB/shared/swarm.env"
: > "$TMP/starts.log"; rm -f "$TMP/session-alive"
run_watchdog
check_marker_stops_restarts codex
stop_watchdog; rc="$WD_RC"
if [ "$rc" = 0 ]; then ok "codex: SIGTERM — выход с кодом 0"; else bad "codex: SIGTERM → $rc"; fi

# ── 2. claude: сессии нет → «session gone» каждый проход, пока нет маркера. Маркер прошлой
#       остановки снимается при старте watchdog.
rm -f "$CLAUDE_LAB/shared/swarm.env"
: > "$TMP/starts.log"; rm -f "$TMP/session-alive"
date +%s > "$WS/state/stopping"
run_watchdog
if wait_for 5 starts_at_least 1 && [ ! -f "$WS/state/stopping" ]; then
  ok "claude: старт watchdog снимает маркер прошлой остановки и поднимает агента"
else
  bad "claude: маркер прошлой остановки не снят или агент не поднят"
fi
# Сессия «упала» — без маркера watchdog её поднимет.
rm -f "$TMP/session-alive"
check_marker_stops_restarts claude
stop_watchdog; rc="$WD_RC"
if [ "$rc" = 0 ]; then ok "claude: SIGTERM — выход с кодом 0"; else bad "claude: SIGTERM → $rc"; fi

# ── 3. SIGTERM, пока watchdog ждёт долгий start-agent.
rm -f "$WS/state/stopping" "$TMP/session-alive" "$TMP/slow.pid" "$TMP/sleep.pid"
: > "$TMP/starts.log"; : > "$TMP/slow"
run_watchdog
wait_for 5 test -s "$TMP/slow.pid" || bad "заглушка start-agent не запустилась"
wait_for 5 test -s "$TMP/sleep.pid" || true
T0="$(date +%s)"
stop_watchdog; rc="$WD_RC"
if [ "$rc" = 0 ] && [ $(( $(date +%s) - T0 )) -le 4 ]; then
  ok "SIGTERM во время start-agent — watchdog выходит сразу с кодом 0"
else
  bad "SIGTERM во время start-agent: код $rc, $(( $(date +%s) - T0 )) с"
fi
start_dead() { ! kill -0 "$(cat "$TMP/slow.pid")" 2>/dev/null; }
sleep_dead() { ! kill -0 "$(cat "$TMP/sleep.pid")" 2>/dev/null; }
if wait_for 3 start_dead && wait_for 3 sleep_dead; then
  ok "start-agent и его дети сняты вместе с watchdog"
else
  bad "start-agent пережил остановку watchdog — поднял бы агента после systemctl stop"
fi
[ -f "$TMP/session-alive" ] && bad "сессия поднята после остановки" \
  || ok "после остановки сессия не поднята"

# ── 4. stop-agent.sh: маркер ставится до снятия сессии; порт app-server codex — с запасным
#       «6000 + индекс в ростере», как у start-agent/watchdog (в channel.env порта нет).
#       pkill/pgrep — заглушки: настоящие задели бы процессы живого роя.
mkdir -p "$TMP/stopbin"
printf '#!/usr/bin/env bash\necho "$*" >> "%s/pkill.log"\nexit 1\n' "$TMP" > "$TMP/stopbin/pkill"
printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/stopbin/pgrep"
printf 'HARNESS=codex\n' > "$CLAUDE_LAB/shared/swarm.env"
printf 'other\n%s\n' "$AGENT" > "$CLAUDE_LAB/agents.conf"
rm -f "$WS/state/stopping"; : > "$TMP/session-alive"; : > "$TMP/pkill.log"
# Заглушка tmux пишет порядок событий: в момент kill-session маркер уже должен стоять.
cat > "$TMP/stopbin/tmux" <<STUB
#!/usr/bin/env bash
case "\$1" in
  has-session) [ -f "$TMP/session-alive" ] ;;
  kill-session)
    if [ -f "$WS/state/stopping" ]; then echo marked; else echo unmarked; fi >> "$TMP/order.log"
    rm -f "$TMP/session-alive" ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$TMP/stopbin/pkill" "$TMP/stopbin/pgrep" "$TMP/stopbin/tmux"
PATH="$TMP/stopbin:$PATH" CODEX_STOP_WAIT=0 bash "$HERE/stop-agent.sh" "$AGENT" >/dev/null 2>&1 \
  || bad "stop-agent упал"
if [ "$(head -1 "$TMP/order.log" 2>/dev/null)" = marked ]; then
  ok "stop-agent ставит маркер до снятия сессии"
else
  bad "stop-agent снимает сессию без маркера — watchdog поднимет агента заново"
fi
if grep -qF '127\.0\.0\.1:6001/mcp' "$TMP/pkill.log"; then
  ok "stop-agent: порт app-server codex из ростера (6000 + индекс)"
else
  bad "stop-agent: app-server codex без порта — останется сиротой ($(tr '\n' ' ' < "$TMP/pkill.log"))"
fi
rm -f "$CLAUDE_LAB/agents.conf"

# ── 5. SIGHUP → watchdog переподнимает СЕБЯ (exec), перечитывает swarm.env, без рестарта юнита.
#       Так switch-harness.sh переводит агента на новый харнес без sudo на `systemctl restart`:
#       exec сохраняет PID (systemd доволен), а старт watchdog снимает маркер остановки и уходит
#       в цикл нового харнеса. Снятие маркера делает ТОЛЬКО старт watchdog — не рабочий цикл,
#       поэтому снятый после HUP маркер = доказанный re-exec.
rm -f "$WS/state/stopping" "$TMP/session-alive" "$TMP/slow" "$TMP/slow.pid" "$TMP/sleep.pid"
: > "$TMP/starts.log"
printf 'HARNESS=claude\n' > "$CLAUDE_LAB/shared/swarm.env"
: > "$TMP/watchdog.log"
run_watchdog
HUP_PID="$WD_PID"
if wait_for 5 starts_at_least 1; then
  ok "HUP: watchdog поднялся (claude)"
else
  bad "HUP: watchdog не стартовал"
fi
# Сменили харнес в swarm.env и поставили маркер остановки; HUP должен переподнять watchdog.
printf 'HARNESS=codex\n' > "$CLAUDE_LAB/shared/swarm.env"
date +%s > "$WS/state/stopping"
sleep 0.3
kill -HUP "$HUP_PID" 2>/dev/null || true
marker_gone() { [ ! -f "$WS/state/stopping" ]; }
if wait_for 5 marker_gone; then
  ok "HUP: маркер снят при старте — watchdog сделал re-exec"
else
  bad "HUP: маркер остановки не снят — re-exec не произошёл"
fi
if kill -0 "$HUP_PID" 2>/dev/null; then
  ok "HUP: тот же PID жив (exec, а не рестарт юнита)"
else
  bad "HUP: watchdog умер вместо re-exec"
fi
if grep -q 'SIGHUP' "$TMP/watchdog.log"; then
  ok "HUP: приём SIGHUP залогирован"
else
  bad "HUP: нет записи о SIGHUP в логе"
fi
stop_watchdog

echo "watchdog-stop.test.sh: $pass ok, $fail fail"
[ "$fail" -eq 0 ]
