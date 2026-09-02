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

# Best-effort Telegram alerts to the Operator on failures/restarts. Opt-in via
# WATCHDOG_TG_ALERTS (default 1); never fatal; throttled. See lib/notify.sh.
# shellcheck source=lib/notify.sh
source "$SCRIPT_DIR/lib/notify.sh"

log() { echo "[watchdog/$AGENT] $(date -u '+%H:%M:%S') $*"; }

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
log "starting..."
if tmux has-session -t "$SESSION" 2>/dev/null; then
  log "session already alive — resuming monitor without restart"
else
  "$START_SCRIPT" "$AGENT"
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
  log "restarting ($1)"
  "$START_SCRIPT" "$AGENT"
  PREV_TAIL=""; FROZEN_COUNT=0; NUDGE_STAGE=0; IDLE_COUNT=0; IDLE_CONSOLIDATED=0
  note_restart
}

while true; do
  # Пауза цикла нарезана мелко: прямая команда оператора не должна ждать полминуты
  # ответа. Всё остальное по-прежнему проверяется раз в ~30 секунд.
  for _ in $(seq 1 15); do
    sleep 2
    if doctor_request_pending "$AGENT"; then serve_doctor_request; fi
  done

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

  # Session gone entirely
  if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    restart_session "session gone"
    continue
  fi

  # Сессия жива → надзор за task-поллером: если он тихо умер (прибит systemd при
  # рестарте юнита, убит сигналом, упал) — поднимаем заново, не дожидаясь полного
  # рестарта сессии. Идемпотентно; логируем только фактический повторный подъём.
  if [ "$(ensure_task_poller "$AGENT" "$AGENT_WS")" = "launched" ]; then
    log "task-poller был мёртв при живой сессии — поднял заново (supervise)"
  fi

  TAIL=$(tmux capture-pane -pt "$SESSION" -S -8 2>/dev/null || true)

  # Pane moved since last cycle → agent is progressing; reset and move on
  if [ "$TAIL" != "$PREV_TAIL" ]; then
    FROZEN_COUNT=0; NUDGE_STAGE=0; IDLE_COUNT=0; IDLE_CONSOLIDATED=0
    # Эпизод auth-сбоя считаем закрытым только по доказательству: ход реально
    # прошёл (свежий heartbeat) и ошибки в панели нет. Просто перерисовка панели
    # доказательством не является — после рестарта она новая всегда.
    if [ "$AUTH_RESTARTED" -eq 1 ] && heartbeat_fresh && ! has_auth_error "$TAIL"; then
      AUTH_RESTARTED=0
      log "авторизация восстановлена (ход прошёл) — сброс auth-ладдера"
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
    tmux send-keys -t "$SESSION" Escape 2>/dev/null || true
    sleep 2
    TAIL="$(tmux capture-pane -pt "$SESSION" -S -8 2>/dev/null || true)"
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
  INPUT=$(printf '%s' "$TAIL" | grep -a '❯' | tail -1 | sed -e 's/.*❯//' -e 's/\xc2\xa0//g' -e 's/[[:space:]]//g')
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
           tmux send-keys -t "$SESSION" C-u 2>/dev/null || true
           NUDGE_STAGE=0
           # Буфер пуст, текст доставкой не подтверждён -- агент простаивает,
           # а не залип. Без этой строки призрак навсегда прятал ветку простоя
           # и консолидация памяти не запускалась ни разу.
           note_idle_cycle
         fi
       else
         # Молча: это первая ступень автоматики, а не событие для оператора.
         log "stuck input detected — Enter"
         tmux send-keys -t "$SESSION" Enter 2>/dev/null || true
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
