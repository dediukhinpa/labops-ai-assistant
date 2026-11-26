#!/usr/bin/env bash
# watchdog.sh — держит агента живым. Перезапускает tmux-сессию если она падает.
# Usage: watchdog.sh <agent-name>
# Designed to be the ExecStart of a Type=simple systemd service.
set -euo pipefail

AGENT="$1"
SESSION="labops-$AGENT"
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
START_SCRIPT="$SCRIPT_DIR/start-agent.sh"
# Пути фиксируем здесь: lib/pane-recover.sh при сорсинге перезаписывает
# SCRIPT_DIR на .../lib, и позже собрать их было бы уже нельзя.
DOCTOR_SCRIPT="$SCRIPT_DIR/doctor.sh"
TG_SEND="$SCRIPT_DIR/tg-send.sh"
ORCH_LIB="$SCRIPT_DIR/lib"
# Харнес роя: claude (по умолчанию) или codex — см. lib/harness.sh и ветку codex ниже.
# shellcheck source=lib/harness.sh
source "$ORCH_LIB/harness.sh"
WATCHDOG_HARNESS="$(harness_current 2>/dev/null || echo claude)"

# Idle-triggered memory consolidation: after the agent sits on a clean idle prompt
# for MEMORY_IDLE_CONSOLIDATE_MIN minutes, nudge the session to reflect (once per
# idle period). Reflection runs in-session (no headless claude); this only pings it.
CLAUDE_LAB="${CLAUDE_LAB:-$HOME/.claude-lab}"
AGENT_WS="$CLAUDE_LAB/$AGENT/.claude"
REFLECT_NUDGE="$AGENT_WS/scripts/reflect-nudge.sh"
IDLE_CYCLES=$(( ${MEMORY_IDLE_CONSOLIDATE_MIN:-10} * 60 / 30 ))   # 30s per loop cycle

# Heartbeat proof-of-life: hooks (settings.json) tick $AGENT_WS/state/heartbeat at
# every turn/tool boundary (SessionStart/UserPromptSubmit/PreToolUse/PostToolUse/
# Notification/Stop). A FRESH heartbeat means the agent is demonstrably alive — used
# below to SUPPRESS false-positive restarts (a static pane that is really a long
# tool run). Hooks fire at boundaries, NOT continuously, so a STALE heartbeat is
# never a restart trigger on its own — it only lifts the suppression and lets the
# pane-based classifier decide. Tune the window via WATCHDOG_HEARTBEAT_GRACE_SEC.
HEARTBEAT_FILE="$AGENT_WS/state/heartbeat"
HEARTBEAT_GRACE="${WATCHDOG_HEARTBEAT_GRACE_SEC:-45}"
heartbeat_age() {   # seconds since last heartbeat, or 999999 if absent/unreadable
  local hb now
  [ -f "$HEARTBEAT_FILE" ] || { echo 999999; return; }
  hb=$(cat "$HEARTBEAT_FILE" 2>/dev/null || echo '')
  case "$hb" in ''|*[!0-9]*) echo 999999; return;; esac
  now=$(date +%s)
  echo $(( now - hb ))
}
heartbeat_fresh() { [ "$(heartbeat_age)" -le "$HEARTBEAT_GRACE" ]; }
# heartbeat_since <epoch> — heartbeat записан строго позже указанного момента?
heartbeat_since() {
  local hb
  hb=$(cat "$HEARTBEAT_FILE" 2>/dev/null || echo '')
  case "$hb" in ''|*[!0-9]*) return 1;; esac
  [ "$hb" -gt "$1" ]
}

# Best-effort Telegram alerts to the Operator on failures/restarts. Opt-in via
# WATCHDOG_TG_ALERTS (default 1); never fatal; throttled. See lib/notify.sh.
# shellcheck source=lib/notify.sh
source "$SCRIPT_DIR/lib/notify.sh"

# Подхват самообновившегося Claude Code. Нативный установщик двигает симлинк, но
# работающий процесс остаётся на своём inode — без перезапуска сессия сидит на
# старой версии неделями (замер 08.09.2026: сессии отставали на две версии).
# Сколько проходов простоя выждать перед перезапуском — цикл около 30 секунд.
# shellcheck source=lib/cli-version.sh
source "$SCRIPT_DIR/lib/cli-version.sh"
CLI_UPDATE_IDLE_CYCLES="${WATCHDOG_CLI_UPDATE_IDLE_CYCLES:-2}"

log() { echo "[watchdog/$AGENT] $(date -u '+%H:%M:%S') $*"; }

# Такт цикла надзора: WATCHDOG_TICKS пауз по WATCHDOG_TICK_SEC (около 30 с на проход). Между
# паузами обслуживается /doctor. Переопределяется только в тестах.
WATCHDOG_TICK_SEC="${WATCHDOG_TICK_SEC:-2}"
WATCHDOG_TICKS="${WATCHDOG_TICKS:-15}"

# Маркер «агент останавливается» (agent_stop_mark в lib/agents.sh) и остановка по сигналу.
# shellcheck source=lib/agents.sh
source "$ORCH_LIB/agents.sh"
# Новый запуск watchdog = юнит стартует: маркер прошлой остановки больше не действует.
agent_stop_clear "$AGENT"

# PID start-agent.sh, который сейчас ждёт watchdog (пусто — не ждёт).
WATCHDOG_CHILD_PID=""
# on_term — SIGTERM/SIGINT от systemd (после ExecStop=stop-agent.sh): завершить своих детей
# (start-agent, фоновые подталкивания) и выйти с кодом 0. Сессию агента НЕ трогаем — её снимает
# stop-agent. Без ловушки start-agent, который watchdog ждал в этот момент, переживал главный
# процесс (KillMode=process) и поднимал агента после остановки юнита. Всё через `|| true`:
# под set -e ненулевой код внутри ловушки — тот самый «самоубивающийся» watchdog.
on_term() {
  local p k kids
  trap - TERM INT
  log "сигнал остановки — завершаю своих детей и выхожу (сессию снимает stop-agent)"
  # Внуков запоминаем заранее, а гасим ПОСЛЕ самого ребёнка: в обратном порядке start-agent, у
  # которого убили ожидаемый им процесс, успевал сделать следующий шаг — вплоть до создания
  # сессии; а после смерти ребёнка его дети уже не находятся по -P.
  for p in $(jobs -p 2>/dev/null || true) $WATCHDOG_CHILD_PID; do
    kids="$(pgrep -P "$p" 2>/dev/null || true)"
    kill -TERM "$p" 2>/dev/null || true
    for k in $kids; do kill -TERM "$k" 2>/dev/null || true; done
  done
  exit 0
}
trap on_term TERM INT

# on_hup — SIGHUP шлёт switch-harness.sh после смены харнеса роя (флип swarm.env + конвертация).
# Харнес watchdog читает ОДИН раз при старте (WATCHDOG_HARNESS) и дальше крутит цикл этого
# харнеса, поэтому новый харнес он сам не подхватит. exec переподнимает watchdog в ТОМ ЖЕ
# процессе (тот же PID — systemd доволен, рестарт юнита и sudo не нужны): скрипт перечитывает
# swarm.env, снимает старый маркер остановки (agent_stop_clear при старте) и уходит в цикл нового
# харнеса, подняв агента уже в новом рантайме. Сессию к этому моменту уже снял stop-agent.
on_hup() {
  trap - HUP
  log "SIGHUP — харнес роя сменился, переподнимаю watchdog (exec, перечитываю swarm.env)"
  exec "$0" "$AGENT"
}
trap on_hup HUP

# run_start [режим-pii] — запуск start-agent.sh. В фоне с wait, а не напрямую: bash исполняет
# ловушку сигнала только после завершения переднего процесса, а start-agent ждёт готовности до
# 90 с — дольше, чем systemd ждёт выхода. wait же прерывается сигналом сразу.
# LABOPS_START_FROM_WATCHDOG=1 — start-agent отказывается стартовать при маркере остановки.
# PII_START_MODE — как start-agent выбирает режим pii-proxy (pii_mode_resolve_start).
# Возвращает код start-agent.
run_start() {
  local rc=0
  LABOPS_START_FROM_WATCHDOG=1 PII_START_MODE="${1:-}" "$START_SCRIPT" "$AGENT" &
  WATCHDOG_CHILD_PID=$!
  wait "$WATCHDOG_CHILD_PID" || rc=$?
  WATCHDOG_CHILD_PID=""
  return "$rc"
}

# pii-proxy: в норме агент ходит в модель через него (ANTHROPIC_BASE_URL в settings.json,
# model_provider в config.toml у codex). Прокси молчит — агент работает напрямую (решение
# владельца 23.11.2026), см. lib/pii.sh и pii_watch_cycle ниже.
# shellcheck source=lib/pii.sh
source "$SCRIPT_DIR/lib/pii.sh"
# Сколько проходов чистого простоя выждать перед перезапуском claude ради возврата через прокси —
# как у подхвата обновлённого CLI: не рестартовать в паузе между двумя сообщениями оператора.
# Переход напрямую простоя не ждёт (см. (P) в основном цикле).
PII_SWITCH_IDLE_CYCLES="${WATCHDOG_PII_SWITCH_IDLE_CYCLES:-2}"

# Повтор последнего входящего после перевода claude на прямую работу (lib/pii-replay.sh).
# shellcheck source=lib/pii-replay.sh
source "$SCRIPT_DIR/lib/pii-replay.sh"

# pii_watch_cycle — проверка прокси раз в проход (гистерезис в pii_watch_step). Ставит PII_WANT.
pii_watch_cycle() {
  local prev_fail="$PII_FAIL_STREAK" prev_ok="$PII_OK_STREAK"
  pii_watch_step "$AGENT"
  if [ "$PII_FAIL_STREAK" -eq 1 ] && [ "$prev_fail" -eq 0 ]; then
    log "pii-proxy не ответил на /health — пробую поднять юнит (порог $PII_DOWN_AFTER_FAILS)"
  fi
  if [ "$PII_OK_STREAK" -eq 1 ] && [ "$prev_ok" -eq 0 ] \
     && [ "$(pii_mode_get "$AGENT")" = "$PII_MODE_DIRECT" ]; then
    log "pii-proxy снова отвечает — агент пока напрямую, верну (порог $PII_UP_AFTER_OKS)"
  fi
  return 0
}

# pii_report_stuck — алерт о застрявшей сессии (прокси пишет session_stuck после серии
# отказов 422/503). Простой механизм: файл событий + счётчик прочитанного, без журнала.
pii_report_stuck() {
  local n
  n="$(pii_stuck_poll "$AGENT" 2>/dev/null || echo 0)"
  if [ "${n:-0}" -gt 0 ]; then
    log "pii-proxy: session_stuck x$n"
    WATCHDOG_ALERT_COOLDOWN="${WATCHDOG_PII_STUCK_COOLDOWN:-3600}" \
      notify_op "$AGENT" "⚠️ сессия застряла: прокси маскирования отклоняет запросы подряд (422/503). Агент, вероятно, молчит. Пришлите /doctor или проверьте журнал labops-pii-proxy@$AGENT."
  fi
  return 0
}

# ── Что оператор действительно хочет знать ───────────────────────────────────
# РОВНО ДВА события заслуживают сообщения в Telegram:
#   (1) агент не может работать из-за подписки/входа Claude;
#   (2) агент недоступен, и автоматика не справилась сама.
# Плюс парное «снова на связи» — оно приходит ТОЛЬКО после алерта, поэтому не
# шум, а закрытие висящей тревоги.
#
# Всё остальное — рестарты сессии, подобранные осиротевшие процессы, ступени
# досылки застрявшего ввода — внутренняя кухня автоматики: пишем в лог, оператора
# не трогаем. Раньше каждый такой шаг слал сообщение, и оператор получал поток
# отчётов, по которым нечего делать (обратная связь 2026-08-09: «технические
# детали и копания в сессии — неактуальны»).
NOTIFY_TAG="$AGENT"          # префикс «🔧 developer:», без внутреннего имени демона

# Флаг «оператору сообщено о недоступности» лежит ФАЙЛОМ: переменная в памяти не
# пережила бы рестарт демона, и висящая тревога никогда бы не закрылась.
DOWN_FLAG="$CLAUDE_LAB/shared/state/$AGENT/agent-down"

# report_down <причина-для-лога> [текст-оператору]
# Второй аргумент отличает класс (1) «подписка/вход» от класса (2) «недоступен»;
# флаг общий — для оператора это одна висящая тревога, закрываемая одним
# «снова на связи».
report_down() {
  # Только `if`: `[ ... ] && return 0` при ложном условии возвращает 1 и под
  # `set -e` убивает демон — тот самый класс бага, что ронял watchdog.
  if [ -f "$DOWN_FLAG" ]; then return 0; fi
  mkdir -p "$(dirname "$DOWN_FLAG")" 2>/dev/null || true
  : > "$DOWN_FLAG" 2>/dev/null || true
  log "эскалация оператору: $1"
  WATCHDOG_ALERT_COOLDOWN="${WATCHDOG_DOWN_ALERT_COOLDOWN:-3600}" \
    notify_op "$AGENT" "${2:-⛔ агент недоступен — сам не починился. Пришлите /doctor: проверю и отчитаюсь.}"
  return 0
}

report_up() {
  if [ ! -f "$DOWN_FLAG" ]; then return 0; fi
  clear_down
  log "агент восстановился — закрываю тревогу"
  WATCHDOG_ALERT_COOLDOWN=0 notify_op "$AGENT" "✅ агент снова на связи."
  return 0
}

# Тихо снять тревогу — когда оператор и так получает ответ (вердикт доктора).
clear_down() { rm -f "$DOWN_FLAG" 2>/dev/null || true; return 0; }

# Флап рестартов = недоступность с точки зрения оператора: сессия поднимается, но
# не живёт. Один-два рестарта — норма самолечения, о них молчим.
RESTART_FLAP_WINDOW="${WATCHDOG_RESTART_FLAP_WINDOW:-900}"
RESTART_FLAP_COUNT="${WATCHDOG_RESTART_FLAP_COUNT:-3}"
RESTART_TIMES=""             # unix-метки рестартов внутри окна, через пробел

note_restart() {
  local now t keep n
  now="$(date +%s)"
  keep=""
  for t in $RESTART_TIMES $now; do
    if [ "$((now - t))" -lt "$RESTART_FLAP_WINDOW" ]; then keep="$keep $t"; fi
  done
  RESTART_TIMES="${keep# }"
  n="$(printf '%s' "$RESTART_TIMES" | wc -w)"
  if [ "$n" -ge "$RESTART_FLAP_COUNT" ]; then
    report_down "$n рестартов за ${RESTART_FLAP_WINDOW}s"
  fi
  return 0
}

# Initial start — but DON'T disrupt an already-running agent. This lets the
# watchdog itself be restarted (e.g. to pick up new code) without killing the
# live tmux session: if the session is alive we just resume monitoring.
# Сессию ищем только по точному имени («=»): иначе tmux берёт первую, чьё имя
# НАЧИНАЕТСЯ так же. 10.09.2026 watchdog labops-app нашёл здесь сессию
# labops-app-124546645, записал «уже жива» и так и не поднял своего агента.
log "starting..."
if tmux has-session -t "=$SESSION" 2>/dev/null; then
  log "session already alive — resuming monitor without restart"
else
  # Прокси молчит — start-agent.sh сам стартует агента напрямую и предупредит оператора.
  if [ "$WATCHDOG_HARNESS" = "codex" ]; then
    # Неудачный старт (например, нет входа в ChatGPT) не должен ронять демон под set -e:
    # цикл ниже поднимет тревогу и повторит.
    run_start || log "первый старт не удался — повторю в цикле надзора"
  else
    run_start
  fi
fi

# Liveness model. The ONLY reliable "a turn is actively running" marker is the
# "esc to interrupt" footer: Claude Code shows it for the whole duration of a turn
# and removes it the instant the turn ends. The elapsed-time line ("Cooked for
# 8s") PERSISTS on screen after a turn completes — keying on it would falsely flag
# a healthy idle agent that just finished a quick turn (this regressed silvio:
# old pattern `for [0-9]+s` matched the leftover "Cooked for Ns" marker and
# restarted an idle agent). So active-turn detection keys ONLY on "esc to
# interrupt".
#
# Two silent-failure modes seen in this lab, both invisible to a naive
# prompt-marker check (a hung TUI still renders ❯ / bypass-permissions):
#   (A) frozen turn — "esc to interrupt" present but pane byte-identical across
#       cycles (timer stopped) → turn wedged. Restart after ~60s.
#   (B) stuck input — an injected inbound sits in ❯ unsubmitted, no active turn.
#       Root cause is upstream: Claude Code's research-preview "channels" feature
#       is DOCUMENTED to auto-process a `notifications/claude/channel` event
#       (wrapped in a <channel> tag) but on this build drops it into the input
#       box as an uncommitted bracketed-paste. Not fixable from the plugin (the
#       capability is declared correctly). A single Enter does NOT commit the
#       paste (verified 2026-06-13 on silvio); we try Enter → Escape+Enter.
#       We DO NOT restart on stuck input: the agent is ALIVE (prompt rendered;
#       genuinely-dead sessions are caught by the frozen-turn / no-prompt
#       branches via heartbeat). Restarting would DESTROY the agent's in-progress
#       work and still not deliver the stuck message — strictly worse than
#       leaving it. So we nudge, then escalate to the OPERATOR and keep the
#       session alive. Acted on ONLY when the input box is non-empty, so a clean
#       idle prompt is never disturbed.
# ACTIVE_RE / PROMPT_RE + классификатор панели живут в lib/pane.sh — вынесены
# туда, чтобы их можно было покрыть тестом (этот файл — бесконечный цикл, его
# нельзя заsource'ить из теста).
# shellcheck source=lib/pane.sh
source "$SCRIPT_DIR/lib/pane.sh"
# Надзор за task-поллером (тот же код, что и start-agent) — see lib/task-poller-launch.sh.
# ВАЖНО: source ДО pane-recover.sh — тот при сорсинге перезаписывает $SCRIPT_DIR
# на .../lib, и любой последующий "$SCRIPT_DIR/lib/..." собрал бы путь lib/lib/.
# shellcheck source=lib/task-poller-launch.sh
source "$SCRIPT_DIR/lib/task-poller-launch.sh"
# Очередь запросов «/doctor» от плагина + аварийный приём команды из Telegram.
# shellcheck source=lib/doctor-request.sh
source "$SCRIPT_DIR/lib/doctor-request.sh"
# Заявки «/reset»: очистка контекста сессии набором /clear.
# shellcheck source=lib/session-reset.sh
source "$SCRIPT_DIR/lib/session-reset.sh"
# agent_bot_token — нужен только аварийному приёму (см. serve_doctor_request).
# shellcheck source=lib/agents.sh
source "$SCRIPT_DIR/lib/agents.sh"
# Reliable stuck-input recovery (clear + retype) — see lib/pane-recover.sh.
# shellcheck source=lib/pane-recover.sh
source "$SCRIPT_DIR/lib/pane-recover.sh"
PREV_TAIL=""
FROZEN_COUNT=0
NUDGE_STAGE=0
IDLE_COUNT=0
IDLE_CONSOLIDATED=0
# Рестарт по ошибке авторизации разрешён ровно один раз за эпизод — сбрасывается
# только доказанным восстановлением (см. ветку (A2) и сброс ниже), НЕ рестартом:
# иначе при реально отозванном доступе получился бы вечный цикл рестартов.
AUTH_RESTARTED=0
# Момент, после которого heartbeat считается доказательством восстановления.
# Хук SessionStart тоже пишет heartbeat, а он срабатывает при любом старте —
# в том числе у сессии без входа. Поэтому свежий heartbeat сразу после рестарта
# ничего не доказывает: раньше по нему watchdog объявлял «авторизация
# восстановлена», сбрасывал ладдер и вместо тревоги оператору перезапускал
# агента по кругу. Засчитываем только heartbeat позже рестарта + запас на старт.
AUTH_RESTART_AT=0
AUTH_RECOVERY_MARGIN_SEC="${WATCHDOG_AUTH_RECOVERY_MARGIN_SEC:-15}"
# То же самое для мастера первого запуска (ветка A1): один рестарт на эпизод.
ONBOARDING_RESTARTED=0
# Окно выбора (ветка A1b): сколько статичных проходов оно на экране. Отвечает на
# него оператор через плагин канала; watchdog лишь зовёт оператора, если окно
# висит дольше WATCHDOG_CHOICE_ALERT_CYCLES проходов (~30 с каждый, около 10 мин).
CHOICE_CYCLES=0
CHOICE_ALERT_CYCLES="${WATCHDOG_CHOICE_ALERT_CYCLES:-20}"
# Вопрос о каналах для разработки (ветка A0): сколько раз ответили за эпизод.
# Не уходит после нескольких ответов — один рестарт сессии (как у мастера, A1);
# вернулся и после него — зовём оператора, а не жмём Enter вечно.
DEV_CHANNELS_ANSWERS=0
DEV_CHANNELS_MAX_ANSWERS="${WATCHDOG_DEV_CHANNELS_MAX_ANSWERS:-3}"
DEV_CHANNELS_RESTARTED=0

# ── Обслуживание команды /doctor ─────────────────────────────────────────────
# Исполняет запрос, положенный плагином (или аварийным приёмом), и САМ отвечает
# оператору. Отвечает именно watchdog, а не плагин: доктор вправе перезапустить
# сессию, и тогда плагин умрёт вместе с ней, не успев отправить вердикт.
serve_doctor_request() {
  local chat out rc=0
  chat="$(doctor_request_take "$AGENT")" || return 0
  log "запрос /doctor принят — проверяю и чиню"
  out="$(bash "$DOCTOR_SCRIPT" "$AGENT" --fix --quiet 2>&1)" || rc=$?
  # Вердикт доктора сам сообщает состояние — тревогу снимаем молча, чтобы
  # оператор не получил два сообщения об одном и том же.
  if [ "$rc" -eq 0 ]; then clear_down; fi
  ( TG_CHAT_ID="$chat" "$TG_SEND" "$AGENT" "$out" ) >/dev/null 2>&1 || true
  log "ответ на /doctor отправлен (код $rc)"
  # Доктор мог перезапустить сессию или дослать ввод — прежний снимок панели
  # больше ничего не значит.
  PREV_TAIL=""; NUDGE_STAGE=0
  return 0
}

# ── Обслуживание команды /reset ────────────────────────────────────────
# Логика — в lib/session-reset.sh (serve_session_reset). После набора /clear
# прежний снимок панели и счётчики простоя больше ничего не значат.
serve_reset_request() {
  serve_session_reset
  if [ "$SESSION_RESET_SERVED" -eq 1 ]; then
    PREV_TAIL=""; NUDGE_STAGE=0; IDLE_COUNT=0; IDLE_CONSOLIDATED=0
  fi
  return 0
}

# note_idle_cycle -- учёт спокойного простоя: агент на связи, ходов нет.
#
# Зовётся из ДВУХ мест: чистый промпт и НАРИСОВАННЫЙ призрак при пустом буфере.
# Призрак -- это тоже простой: буфера за ним нет, агент ничего не делает. Пока
# он простоем не считался, до ветки простоя управление не доходило вовсе, и
# консолидация памяти не запускалась НИ РАЗУ: призрак висит часами, счётчик
# простоя стоял на нуле. У carmella так накопилось 67 неисполненных заявок с
# 19.07.2026 при пустом watermark, тогда как developer с чистым промптом
# консолидировался штатно.
note_idle_cycle() {
  report_up
  # Idle-triggered consolidation: once the agent has been idle long enough,
  # nudge it to reflect (episodic → passive). Fire once per idle period.
  IDLE_COUNT=$((IDLE_COUNT + 1))
  if [ "$IDLE_COUNT" -ge "$IDLE_CYCLES" ] && [ "$IDLE_CONSOLIDATED" -eq 0 ] && [ -f "$REFLECT_NUDGE" ]; then
    log "idle ${MEMORY_IDLE_CONSOLIDATE_MIN:-10}min → nudging memory consolidation"
    ( AGENT_WORKSPACE="$AGENT_WS" AGENT_ID="$AGENT" bash "$REFLECT_NUDGE" --reason idle >/dev/null 2>&1 || true ) &
    IDLE_CONSOLIDATED=1
  fi
}

# attempt_stuck_input_recovery -- надёжное восстановление залипшего ввода:
# чистим поле и ПЕРЕПЕЧАТЫВАЕМ текст обычными нажатиями + Enter.
#
# Зовётся из ДВУХ мест лестницы NUDGE_STAGE: со ступени 1 (обычное залипание,
# до неё был безрезультатный Enter) и НАПРЯМУЮ со ступени 0, когда буфер пуст,
# а текст подтверждён доставкой. Во втором случае ждать нечего: Enter коммитить
# нечего по определению, и откладывание на следующий ~30с проход задерживало
# реально потерянное сообщение оператора на пустом месте.
attempt_stuck_input_recovery() {
  log "stuck input persists — reliable resubmit (clear + retype)"
  # КРИТИЧНО: захват кода возврата ТОЛЬКО через `|| rc=$?`. Файл идёт под
  # `set -e`, где `cmd; rc=$?` убивает демон на любом ненулевом коде — а
  # recover_stuck_input штатно возвращает 1 (поле не чистится) и 2 (уже не
  # залипло). Итог до фикса (найдено 2026-08-09): watchdog умирал ровно на
  # этой строке, systemd поднимал его заново, NUDGE_STAGE обнулялся, и
  # лестница вечно начиналась заново с «пробую дослать (Enter)» — часы
  # алертов оператору и ни одного реального восстановления.
  local rc=0
  recover_stuck_input "$SESSION" "$AGENT" || rc=$?
  if [ "$rc" -ne 1 ]; then
    log "stuck input recovered (clear + retype), rc=$rc, текст из: ${RECOVER_SOURCE:-pane}"
    # Единственное исключение из «молчим о технике»: пропала ЧАСТЬ текста
    # оператора. Это не отчёт о работе автоматики, а потеря его данных —
    # без сообщения он будет ждать ответа на то, чего агент не видел.
    # Формулировка без внутренней кухни: что потерялось и что сделать.
    if [ "${RECOVER_TRUNCATED:-0}" -eq 1 ]; then
      notify_op "$AGENT" "✂️ ваше сообщение дошло не полностью — уцелела только последняя строка. Пришлите его ещё раз."
    fi
    NUDGE_STAGE=0   # recovered — reset the ladder
  else
    log "reliable resubmit failed — box won't clear, escalating next cycle"
    NUDGE_STAGE=2
  fi
}

restart_session() {
  # Молча: одиночный рестарт — штатное самолечение, оператору сообщать не о чем.
  # Тревога поднимается только если рестарты пошли по кругу (см. note_restart).
  # Идёт `systemctl stop` (маркер ставит stop-agent.sh) — никаких рестартов: иначе агент
  # поднимался заново, пока stop-agent ждёт сброса памяти драйвером codex.
  if agent_stopping "$AGENT"; then
    log "агент останавливается — рестарт ($1) пропущен"
    return 0
  fi
  # Режим pii-proxy (третий аргумент → PII_START_MODE start-agent.sh): по умолчанию keep —
  # перезапуск не возвращает агента с прямой работы на прокси в обход гистерезиса (возврат —
  # только через pii_watch_step: PII_UP_AFTER_OKS удачных проверок подряд). pii_switch_claude
  # передаёт direct: решение watchdog start-agent не переигрывает.
  log "restarting ($1)"
  pii_streak_reset
  if [ "$WATCHDOG_HARNESS" = "codex" ]; then
    run_start "${3:-keep}" || log "старт не удался — повторю на следующем проходе"
  else
    run_start "${3:-keep}"
  fi
  PREV_TAIL=""; FROZEN_COUNT=0; NUDGE_STAGE=0; IDLE_COUNT=0; IDLE_CONSOLIDATED=0
  # Плановый перезапуск (второй аргумент noflap: смена режима pii-proxy) — не признак
  # нездоровья, в счётчик флапа его не берём.
  if [ "${2:-}" != "noflap" ]; then note_restart; fi
}

# ── Харнес Codex ─────────────────────────────────────────────────────────────
# В tmux-сессии агента на Codex работает плагин-драйвер, а не TUI: разбирать экран, досылать
# ввод и отвечать на диалоги не нужно. Живость — процесс драйвера, его webhook-порт и
# heartbeat (драйвер пишет его на событиях нити и раз в минуту в простое). /reset драйвер
# обслуживает сам (новая нить), здесь — только /doctor, вход в ChatGPT и рестарты.
# shellcheck source=lib/codex-watch.sh
source "$ORCH_LIB/codex-watch.sh"
# shellcheck source=lib/agent-env.sh
source "$ORCH_LIB/agent-env.sh"
CODEX_HEARTBEAT_STALE="${WATCHDOG_CODEX_HEARTBEAT_STALE_SEC:-300}"
CODEX_AUTH_CHECK_CYCLES="${WATCHDOG_CODEX_AUTH_CHECK_CYCLES:-10}"
CODEX_PORT_MISS_LIMIT="${WATCHDOG_CODEX_PORT_MISS_LIMIT:-3}"

codex_port_listening() {   # <port>
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | grep -qE "127\.0\.0\.1:$1\b"
  else
    (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
  fi
}

codex_watch_loop() {
  local cycle=0 port_miss=0 auth_bad=0 state port
  port="$(agent_env_webhook_port "$AGENT" 2>/dev/null || true)"
  log "харнес codex: надзор за драйвером (порт ${port:-?})"
  while true; do
    for _ in $(seq 1 "$WATCHDOG_TICKS"); do
      sleep "$WATCHDOG_TICK_SEC"
      if doctor_request_pending "$AGENT"; then serve_doctor_request; fi
    done
    # Идёт остановка юнита — ничего не чиним и не перезапускаем, ждём SIGTERM.
    if agent_stopping "$AGENT"; then continue; fi
    # Аварийный приём /doctor — как у claude: при висящей тревоге плагин, скорее всего,
    # Telegram не читает.
    if [ -f "$DOWN_FLAG" ]; then
      BOT_TOKEN="$(agent_bot_token "$AGENT" 2>/dev/null || true)"
      if [ -n "$BOT_TOKEN" ] && doctor_poll_telegram "$AGENT" "$BOT_TOKEN"; then
        log "команда /doctor принята напрямую из Telegram (плагин недоступен)"
        serve_doctor_request
      fi
      BOT_TOKEN=""
    fi
    pii_report_stuck
    # Смена режима pii-proxy: драйвер сам видит новый файл режима и перезапускает app-server,
    # продолжая ту же нить; перезапуск сессии не нужен. Напрямую — сразу (идущий ход прерывается
    # и его вход повторяется), обратно через прокси — между ходами.
    pii_watch_cycle
    if pii_switch_due "$AGENT"; then
      log "pii-proxy: режим $(pii_mode_get "$AGENT") → $PII_WANT (переключит драйвер)"
      # pii_mode_set при смене сбрасывает и счётчики гистерезиса.
      pii_mode_set "$AGENT" "$PII_WANT" || true
    fi
    cycle=$((cycle + 1))

    # Вход в ChatGPT: на первом проходе, раз в CODEX_AUTH_CHECK_CYCLES и каждый проход, пока
    # входа нет. Без входа рестарты бесполезны — ждём человека с одной тревогой.
    if [ "$auth_bad" -eq 1 ] || codex_auth_check_due "$cycle" "$CODEX_AUTH_CHECK_CYCLES"; then
      state="$(codex_auth_state "$AGENT")"
      case "$state" in
        none|apikey)
          if [ "$auth_bad" -eq 0 ]; then
            report_down "codex: вход $state" \
              "⛔ агент не может работать: Codex не вошёл в ChatGPT по подписке. Что сделать: $(codex_login_hint "$AGENT"), затем агент поднимется сам."
          fi
          auth_bad=1
          continue ;;
        *)
          if [ "$auth_bad" -eq 1 ]; then
            auth_bad=0
            restart_session "вход в ChatGPT восстановлен"
            continue
          fi ;;
      esac
    fi

    if ! tmux has-session -t "=$SESSION" 2>/dev/null || [ -z "$(codex_driver_pid "$AGENT")" ]; then
      restart_session "драйвер codex не работает"
      port_miss=0
      continue
    fi
    if [ "$(ensure_task_poller "$AGENT" "$AGENT_WS")" = "launched" ]; then
      log "task-poller был мёртв при живом драйвере — поднял заново (supervise)"
    fi
    if [ -n "$port" ] && ! codex_port_listening "$port"; then
      port_miss=$((port_miss + 1))
      if [ "$port_miss" -ge "$CODEX_PORT_MISS_LIMIT" ]; then
        restart_session "webhook :$port не слушается $port_miss проходов"
        port_miss=0
      fi
      continue
    fi
    port_miss=0
    if codex_heartbeat_stale "$HEARTBEAT_FILE" "$CODEX_HEARTBEAT_STALE"; then
      restart_session "heartbeat драйвера старше ${CODEX_HEARTBEAT_STALE}s — драйвер завис"
      continue
    fi
    report_up
  done
}

if [ "$WATCHDOG_HARNESS" = "codex" ]; then
  codex_watch_loop
fi

while true; do
  # Пауза цикла нарезана мелко: прямая команда оператора не должна ждать полминуты
  # ответа. Всё остальное по-прежнему проверяется раз в ~30 секунд.
  for _ in $(seq 1 "$WATCHDOG_TICKS"); do
    sleep "$WATCHDOG_TICK_SEC"
    if doctor_request_pending "$AGENT"; then serve_doctor_request; fi
    if reset_request_pending "$AGENT"; then serve_reset_request; fi
  done
  # Идёт остановка юнита — ничего не чиним и не перезапускаем, ждём SIGTERM.
  if agent_stopping "$AGENT"; then continue; fi

  # Аварийный приём: пока висит тревога, плагин почти наверняка не читает
  # Telegram — и команда /doctor нужна ровно тогда, когда доставить её нечем.
  # Заглядываем сами. При живом плагине этого НЕ делаем: второй читатель
  # getUpdates оборвал бы его long-poll.
  if [ -f "$DOWN_FLAG" ]; then
    BOT_TOKEN="$(agent_bot_token "$AGENT" 2>/dev/null || true)"
    if [ -n "$BOT_TOKEN" ] && doctor_poll_telegram "$AGENT" "$BOT_TOKEN"; then
      log "команда /doctor принята напрямую из Telegram (плагин недоступен)"
      serve_doctor_request
    fi
    BOT_TOKEN=""
  fi

  # Defense in depth: reap any ORPHANED channel-server bun for this agent — its
  # claude parent died but the bun is spinning (PPID==1). The live bun is a child
  # of the live claude (PPID!=1) so it is never touched. Catches orphans from any
  # path (crash, manual kill, restart race), not just start-agent.sh restarts.
  for p in $(pgrep -f "\.claude-lab/$AGENT/\.claude/plugins/labops-channel/plugin/src/server\.ts" 2>/dev/null || true); do
    if [ "$(awk '{print $4}' "/proc/$p/stat" 2>/dev/null)" = "1" ]; then
      # Уборка мусора — оператору знать незачем, только в лог.
      log "reaping orphaned channel-bun pid=$p (ppid=1, parent claude died)"
      kill -9 "$p" 2>/dev/null || true
    fi
  done

  pii_report_stuck
  pii_watch_cycle

  # Session gone entirely
  if ! tmux has-session -t "=$SESSION" 2>/dev/null; then
    restart_session "session gone"
    continue
  fi

  # Сессия жива → надзор за task-поллером: если он тихо умер (прибит systemd при
  # рестарте юнита, убит сигналом, упал) — поднимаем заново, не дожидаясь полного
  # рестарта сессии. Идемпотентно; логируем только фактический повторный подъём.
  if [ "$(ensure_task_poller "$AGENT" "$AGENT_WS")" = "launched" ]; then
    log "task-poller был мёртв при живой сессии — поднял заново (supervise)"
  fi

  # (P) pii-proxy упал (гистерезис пройден): простоя не ждём (решение владельца 23.11.2026).
  # Идёт ход — прерываем его, не дожидаясь встроенных повторов CLI; в любом случае перезапуск
  # напрямую с --continue и повтор последнего входящего без ответа (pii_switch_claude).
  # Возврат через прокси — только из чистого простоя, ниже.
  if [ "$PII_WANT" = "$PII_MODE_DIRECT" ] && pii_switch_due "$AGENT"; then
    TAIL=$(tmux capture-pane -pt "=$SESSION:^.{top-left}" -S -8 2>/dev/null || true)
    if has_active_turn "$TAIL"; then
      pii_switch_claude "прокси упал посреди хода" interrupt
    else
      pii_switch_claude "прокси упал"
    fi
    continue
  fi

  TAIL=$(tmux capture-pane -pt "=$SESSION:^.{top-left}" -S -8 2>/dev/null || true)

  # (A0-) Гейт «Bypass Permissions mode». Отвечать за оператора нельзя — это его
  # решение (почему именно так, см. lib/pane.sh). Значит и рестарт бессмыслен:
  # свежая сессия встанет на том же вопросе. Раньше экран попадал в ветки
  # простоя и «не отвечает», и watchdog перезапускал сессию по кругу: у клиента
  # это крутилось больше часа (12.09.2026), а оператор видел только молчащего
  # агента. Теперь — одна тревога с точной инструкцией и ожидание человека.
  # Тревога уходит через Bot API напрямую (lib/notify.sh), а не через канал
  # агента: канал как раз и не поднялся, потому что сессия стоит на вопросе.
  if looks_like_bypass_permissions_prompt "$TAIL"; then
    report_down "гейт Bypass Permissions на экране — жду подтверждения оператора" \
      "⛔ $(bypass_permissions_hint "$SESSION")"
    PREV_TAIL=""
    continue
  fi

  # (A0) Вопрос о каналах для разработки на старте сессии. Отвечаем сразу, не
  # дожидаясь статичной панели: вопрос однозначен, а пока он на экране, сессия
  # стоит — MCP-серверы не стартуют, канал не поднимает порт. Для веток ниже он
  # неотличим от простоя или застрявшего ввода (см. DEV_CHANNELS_RE в lib/pane.sh),
  # поэтому стоит выше всех. start-agent.sh тоже отвечает, но смотрит на экран
  # ограниченное время: 10.09.2026 claude после самообновления поднялся позже, и
  # labops-app остался на вопросе без присмотра.
  if looks_like_dev_channels_prompt "$TAIL"; then
    if [ "$DEV_CHANNELS_ANSWERS" -lt "$DEV_CHANNELS_MAX_ANSWERS" ]; then
      DEV_CHANNELS_ANSWERS=$((DEV_CHANNELS_ANSWERS + 1))
      # На выбранном «2. Exit» функция сперва вернёт выбор стрелкой на первый
      # пункт: Enter прямо на «Exit» закрыл бы claude, а без стрелки выбранный
      # Exit не сдвинул бы никто.
      if answer_dev_channels_prompt "$SESSION" "$TAIL"; then
        log "вопрос о каналах разработки на экране — подтвердил (попытка $DEV_CHANNELS_ANSWERS)"
      else
        log "вопрос о каналах разработки: первый пункт выбрать не удалось — Enter не жму"
      fi
    elif [ "$DEV_CHANNELS_RESTARTED" -eq 0 ]; then
      # Ответы не помогли — один рестарт на эпизод, как у мастера (A1): свежая
      # сессия задаёт вопрос заново, и start-agent.sh отвечает на него сам.
      # Раньше здесь была только тревога, и сессия стояла до прихода человека.
      DEV_CHANNELS_RESTARTED=1
      DEV_CHANNELS_ANSWERS=0
      restart_session "вопрос о каналах не уходит после $DEV_CHANNELS_MAX_ANSWERS ответов"
      continue
    else
      report_down "вопрос о каналах разработки не уходит ни ответами, ни рестартом"
    fi
    PREV_TAIL=""
    continue
  fi
  DEV_CHANNELS_ANSWERS=0

  # Pane moved since last cycle → agent is progressing; reset and move on
  if [ "$TAIL" != "$PREV_TAIL" ]; then
    FROZEN_COUNT=0; NUDGE_STAGE=0; IDLE_COUNT=0; IDLE_CONSOLIDATED=0
    # Экран сменился — новое окно выбора считается с нуля (лог и тревога по нему свои).
    CHOICE_CYCLES=0
    # Эпизод auth-сбоя считаем закрытым только по доказательству: ход реально
    # прошёл (свежий heartbeat) и ошибки в панели нет. Просто перерисовка панели
    # доказательством не является — после рестарта она новая всегда.
    if [ "$AUTH_RESTARTED" -eq 1 ] && heartbeat_fresh \
       && heartbeat_since $(( AUTH_RESTART_AT + AUTH_RECOVERY_MARGIN_SEC )) \
       && ! has_auth_error "$TAIL"; then
      AUTH_RESTARTED=0
      log "авторизация восстановлена (ход прошёл) — сброс auth-ладдера"
    fi
    # Эпизод мастера закрываем по тому же правилу и по той же причине: пока ход
    # не прошёл, «панель изменилась» — это в том числе перелистывание самого
    # мастера с вопроса на вопрос.
    if [ "$ONBOARDING_RESTARTED" -eq 1 ] && heartbeat_fresh && ! looks_like_onboarding "$TAIL"; then
      ONBOARDING_RESTARTED=0
      log "мастер первого запуска пройден (ход прошёл) — сброс ладдера онбординга"
    fi
    # И эпизод вопроса о каналах — по тому же доказательству. Сброс по одному
    # лишь «вопроса нет на экране» дал бы цикл рестартов: после рестарта панель
    # какое-то время пуста, пока claude не нарисует вопрос снова.
    if [ "$DEV_CHANNELS_RESTARTED" -eq 1 ] && heartbeat_fresh \
       && ! looks_like_dev_channels_prompt "$TAIL"; then
      DEV_CHANNELS_RESTARTED=0
      log "вопрос о каналах разработки пройден (ход прошёл) — сброс ладдера"
    fi
    # Панель движется и в ней нет ошибки доступа — агент работает. Если висела
    # тревога, закрываем её: оператор должен узнать не только о поломке.
    if ! has_auth_error "$TAIL"; then report_up; fi
    PREV_TAIL="$TAIL"
    continue
  fi

  # --- Pane is STATIC (~30s unchanged). Classify. ---

  # (A) Active-turn marker present but pane frozen → hung turn. Confirm over ~60s.
  if printf '%s' "$TAIL" | grep -qa "$ACTIVE_RE"; then
    # Fresh heartbeat = the turn is actively doing tool work, just not repainting
    # the pane this cycle → alive, not frozen. Escalate only when the pane is
    # static AND the heartbeat has gone stale (no hook fired within the grace).
    if heartbeat_fresh; then
      FROZEN_COUNT=0
      log "active turn, pane static but heartbeat fresh ($(heartbeat_age)s) — alive"
      continue
    fi
    FROZEN_COUNT=$((FROZEN_COUNT + 1))
    if [ "$FROZEN_COUNT" -ge 2 ]; then
      restart_session "frozen turn — esc-to-interrupt static ~60s, heartbeat stale"
      continue
    fi
    log "possible freeze (1/2) — pane static, heartbeat stale — confirming next cycle"
    continue
  fi
  FROZEN_COUNT=0

  # (A1) Мастер первого запуска Claude Code. Проверяем ПЕРВЫМ среди статичных
  # состояний: ниже он неотличим от здорового простоя — выбранный пункт меню
  # начинается с «❯», поэтому has_prompt отвечает «да», поле ввода пусто, и
  # веткам (A3)/(B) делать нечего (см. ONBOARDING_RE в lib/pane.sh).
  #
  # Само не рассосётся: мастер ждёт клавиши, а до промпта сессия так и не дойдёт
  # — MCP-серверы не стартуют, канал не поднимает порт. Один рестарт: свежая
  # сессия стартует уже с проставленной меткой онбординга (см. start-agent.sh),
  # и мастера не будет. Если он вернулся — засев не сработал, дальше нужен
  # человек, а не второй круг рестартов.
  if looks_like_onboarding "$TAIL"; then
    if [ "$ONBOARDING_RESTARTED" -eq 0 ]; then
      ONBOARDING_RESTARTED=1
      log "мастер первого запуска на экране — сессия до промпта не дойдёт, перезапускаю"
      restart_session "мастер первого запуска Claude Code блокирует сессию"
      continue
    fi
    log "мастер первого запуска вернулся после рестарта — эскалация оператору"
    report_down "мастер первого запуска Claude Code не обходится рестартом" \
      "⛔ Claude Code требует пройти первый запуск — нужна помощь на сервере."
    continue
  fi

  # (A1b) Окно выбора Claude Code («❯ 1. … / 2. …»), например пауза фильтра
  # безопасности. Стоит ДО (A2) и (B): для (B) окно — непустое поле ввода, и та
  # слала бы в окно Ctrl-U, а на непустом буфере — Enter, выбирая пункт за
  # человека; для (A2) слово из окна или переписки над ним выглядело как ошибка
  # входа (26.11.2026: рестарт по «Unauthorized» из ответа агента). Рестарт тоже
  # не нужен: свежая сессия теряет контекст, а окно — штатное ожидание ответа.
  # Отвечает оператор кнопками в Telegram (плагин, choice-dialog.ts), паузу
  # фильтра плагин переключает сам. Здесь — лог и запасная тревога, если окно
  # провисело долго (плагин мёртв или оператор не видел сообщения).
  if looks_like_choice_dialog "$TAIL"; then
    CHOICE_CYCLES=$((CHOICE_CYCLES + 1))
    if [ "$CHOICE_CYCLES" -eq 1 ]; then
      log "окно выбора на экране — жду ответа оператора: $(choice_dialog_summary "$TAIL")"
    fi
    if [ "$CHOICE_CYCLES" -eq "$CHOICE_ALERT_CYCLES" ]; then
      CHOICE_ALERT="⛔ агент ждёт выбора в окне на экране: $(choice_dialog_summary "$TAIL")."
      CHOICE_ALERT+=" Ответьте кнопкой в чате агента или выберите пункт в сессии $SESSION на сервере."
      report_down "окно выбора не отвечено $CHOICE_CYCLES проходов" "$CHOICE_ALERT"
    fi
    continue
  fi
  CHOICE_CYCLES=0

  # TUI lost its prompt entirely → restart, UNLESS a recent hook proves the
  # session is alive (mid-render / transient repaint). A truly dead TUI stops
  # firing hooks, so a stale heartbeat lets the restart proceed.
  if ! has_prompt "$TAIL"; then
    if heartbeat_fresh; then
      log "no prompt rendered but heartbeat fresh ($(heartbeat_age)s) — deferring restart"
      continue
    fi
    # A local slash-command overlay (/context, /status, /cost, /help) looks
    # EXACTLY like a dead TUI: its output scrolls the prompt away, and because
    # the model never runs, no hook fires and the heartbeat goes stale. An
    # operator inspecting a healthy session was enough to trigger a restart.
    # Escape dismisses an overlay but does nothing to a dead TUI, so it is the
    # discriminator. Try it once before destroying the session.
    log "no prompt rendered — trying Escape (may be a slash-command overlay)"
    tmux send-keys -t "=$SESSION:^.{top-left}" Escape 2>/dev/null || true
    sleep 2
    TAIL="$(tmux capture-pane -pt "=$SESSION:^.{top-left}" -S -8 2>/dev/null || true)"
    if has_prompt "$TAIL"; then
      log "prompt returned after Escape — overlay, not a freeze; session left ALIVE"
      PREV_TAIL="$TAIL"
      continue
    fi
    restart_session "no prompt rendered — heartbeat stale (Escape did not restore it)"
    continue
  fi

  # (A2) Промпт есть, но в панели — ошибка авторизации, и heartbeat протух: ходы
  # падают, не начавшись. Для веток ниже это выглядит как здоровый простой, см.
  # AUTH_ERR_RE в lib/pane.sh. Один рестарт (свежий процесс перечитает
  # credentials.json), дальше — только эскалация оператору, чтобы не устроить
  # цикл бесполезных рестартов при реально отозванном доступе.
  if has_auth_error "$TAIL" && ! heartbeat_fresh; then
    if [ "$AUTH_RESTARTED" -eq 0 ]; then
      AUTH_RESTARTED=1
      log "ошибка авторизации в панели, heartbeat протух ($(heartbeat_age)s) — пробую рестарт сессии"
      restart_session "ошибка авторизации Claude — сессия жива, но ходы не выполняются"
      AUTH_RESTART_AT=$(date +%s)
      continue
    fi
    log "ошибка авторизации сохраняется после рестарта — эскалация оператору"
    report_down "подписка/вход Claude недействительны (рестарт не помог)" \
      "⛔ подписка Claude недействительна — агент работать не может. Нужно заново войти в Claude Code на сервере."
    continue
  fi

  # (B) Idle prompt. Is there unsubmitted text stuck in the input box?
  # Strip everything THROUGH the ❯ marker: the idle prompt renders "❯" + a
  # non-breaking space (U+00A0), NOT "❯ " with an ASCII space, so the old
  # `s/.*❯ //` never matched and left the ❯+nbsp in INPUT. Then drop nbsp
  # (which [[:space:]] does NOT match) and all ASCII whitespace. A clean idle
  # prompt → empty INPUT; only genuinely typed text survives. Without this every
  # idle agent looked "stuck" → Enter/Escape/restart on a ~90s cycle, the main
  # cause of agents going silent (found 2026-06-13).
  # Через pane_input (lib/pane.sh): там же защита от экрана без ❯ (плашка лимита),
  # на котором голый конвейер под pipefail ронял весь демон.
  INPUT=$(pane_input "$TAIL")
  # Placeholder hint text (e.g. `Try "fix lint errors"`) renders dim/styled in
  # the TUI, which is how a human tells it apart from real typed input — but
  # capture-pane here has no `-e`, so that styling is invisible and the plain
  # text survives stripping just like real input would. The rotating hint
  # happening to hold still across one 30s poll then read as "stuck input" on
  # a perfectly idle agent → false Enter/Escape/restart cycle (found
  # 2026-07-12). Recognize the hint's fixed `Try "..."` shape and fold it into
  # the idle branch below, same as an empty INPUT.
  if [ -z "$INPUT" ] || printf '%s' "$INPUT" | grep -qE '^Try".*"$'; then
    NUDGE_STAGE=0          # clean idle prompt — healthy, leave it alone
    LAST_PHANTOM=""        # поле очистилось — следующий призрак снова стоит лога
    # Чистый простой = агент на связи (сессия жива, промпт рисуется, ввод не
    # залип). Закрываем висящую тревогу — иначе она не закрылась бы никогда:
    # heartbeat у спокойно простаивающего агента протухает штатно.
    note_idle_cycle
    # Обновившийся CLI подбираем ТОЛЬКО отсюда: чистый простой — единственная
    # точка, где ход не идёт и терять нечего. Пары проходов ждём, чтобы не
    # рестартовать в паузе между двумя сообщениями оператора.
    if [ "$IDLE_COUNT" -ge "$CLI_UPDATE_IDLE_CYCLES" ] && cli_version_drifted "$SESSION"; then
      restart_session "claude обновился: $(cli_version_label "$(cli_version_running_exe "$SESSION")") → $(cli_version_label "$(cli_version_installed_exe)")"
      continue
    fi
    # Возврат через pii-proxy — только из чистого простоя, ход не рвём: адрес модели claude
    # читает на старте, так что нужен перезапуск. Метка --continue сохраняет разговор
    # (session-exec.sh), режим и сообщение оператору выставит start-agent.sh. Переход напрямую
    # обработан выше, (P), без ожидания простоя.
    if [ "$IDLE_COUNT" -ge "$PII_SWITCH_IDLE_CYCLES" ] && pii_switch_due "$AGENT"; then
      pii_switch_claude "простой"
      continue
    fi
    continue
  fi

  # Non-empty input that won't submit → try to commit it (~30s apart), then hand
  # off to the operator. NEVER restart (see mode (B) note above): the session is
  # alive and a restart would lose the agent's work without delivering the message.
  case "$NUDGE_STAGE" in
    0) if buffer_is_empty "$SESSION"; then
         # Текст только НАРИСОВАН, буфера за ним нет (сорванный auto-submit
         # канала). Enter тут отправлять нечего, а алерт «застрял промпт» —
         # ложная тревога: пропускаем ступень и сразу идём в перепечатку,
         # которая доставит потерянное сообщение.
         #
         # Но перепечатывать можно ТОЛЬКО подтверждённое доставкой: нарисованное
         # ≠ отправленное оператором, и без этой проверки watchdog отправлял
         # агенту придуманный текст, замыкая рой в цикл самоуказаний
         # (инцидент 2026-09-01, подробности в lib/pane.sh::inbound_matches).
         if inbound_matches "$AGENT" "$(pane_input_raw "$TAIL")"; then
           # Не через NUDGE_STAGE=1: та ступень исполнится лишь следующим
           # ~30с проходом, а ждать нечего — буфер пуст, Enter коммитить
           # нечего. Откладывание задерживало доставку реально потерянного
           # сообщения оператора на пустом месте (жалоба «агент не отвечает»
           # 15.08.2026: ввод прямо в tmux мимо плагина, быстрого
           # ensure-submit.ts для него нет).
           log "нарисованный, но не набранный ввод (буфер пуст) — сразу перепечатка"
           attempt_stuck_input_recovery
         else
           # Логируем ОДИН раз на призрак, а не каждый цикл: призрак висит
           # часами, и построчный лог (2880 строк в сутки на агента) прятал бы
           # в себе настоящие события watchdog.
           PHANTOM="$(pane_input_raw "$TAIL")"
           if [ "$PHANTOM" != "${LAST_PHANTOM:-}" ]; then
             log "нарисованный ввод не подтверждён доставкой — чищу поле, не отправляю"
             LAST_PHANTOM="$PHANTOM"
           fi
           tmux send-keys -t "=$SESSION:^.{top-left}" C-u 2>/dev/null || true
           NUDGE_STAGE=0
           # Буфер пуст, текст доставкой не подтверждён -- агент простаивает,
           # а не залип. Без этой строки призрак навсегда прятал ветку простоя
           # и консолидация памяти не запускалась ни разу.
           note_idle_cycle
         fi
       else
         # Молча: это первая ступень автоматики, а не событие для оператора.
         log "stuck input detected — Enter"
         tmux send-keys -t "=$SESSION:^.{top-left}" Enter 2>/dev/null || true
         NUDGE_STAGE=1
       fi ;;
    1) # A plain Enter cannot finalise a stuck bracketed-paste (verified: Enter,
       # Escape, Ctrl-C, ESC[201~ all fail). Reliable path — clear the box and
       # RE-TYPE as literal keystrokes + Enter (task-poller proves literal typing
       # submits). recover_stuck_input returns 1 only if the box won't clear.
       attempt_stuck_input_recovery ;;
    2) # Recovery failed. DO NOT restart — keep the session and its work alive;
       # escalate to the operator to submit manually. (Upstream: Claude Code
       # research-preview channels bug — see mode (B) note.)
       # С точки зрения оператора это и есть «агент недоступен»: сообщения до
       # него не доходят. Инструкций с tmux не даём — чинить должен /doctor.
       log "stuck input not auto-committing — session left ALIVE, escalating to operator (no restart)"
       report_down "застрявший ввод не лечится"
       NUDGE_STAGE=3 ;;
    *) : ;;  # оператор уведомлён; ждём его — НЕ рестартуем (работа важнее застрявшего сообщения)
  esac
done
