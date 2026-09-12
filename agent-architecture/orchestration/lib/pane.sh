#!/usr/bin/env bash
# pane.sh — classify what an agent's tmux pane is showing.
#
# Extracted from watchdog.sh so the classification is testable: watchdog.sh is
# an endless supervision loop and cannot be sourced by a test.
#
# WHY THE OVERLAY CASE EXISTS:
# Claude Code slash commands (/context, /status, /cost, /help) are handled
# locally by the CLI — the model never runs. Two consequences make their output
# indistinguishable from a dead TUI:
#   1. the full-screen output scrolls the `❯` prompt out of the captured tail;
#   2. no hook fires (hooks are driven by model turns), so the heartbeat goes
#      stale exactly as it would if the session had died.
# The watchdog therefore restarted a perfectly healthy session — observed on
# the live host after an operator ran /context in the pane. Escape dismisses
# the overlay, which is what distinguishes it from a real freeze.
#
# ЦЕЛИ TMUX — ТОЛЬКО ТОЧНЫЕ. Функции принимают голое имя сессии и сами строят
# цель: «=имя» для команд над сессией, «=имя:^.{top-left}» для команд над
# панелью. Без «=» tmux, не найдя точной сессии, берёт первую, чьё имя
# НАЧИНАЕТСЯ так же: у labops-app это labops-app-124546645 — чужой агент получил
# бы наши клавиши. `=имя` без двоеточия панель не находит (capture-pane и
# send-keys падают), а `=имя:` — это ТЕКУЩЕЕ окно сессии: откроет оператор в
# сессии агента второе окно, и клавиши уйдут в его bash, а pid его bash
# watchdog примет за сменившуюся версию claude (ложный рестарт). `^` — окно с
# наименьшим номером: окно агента создаётся первым и получает base-index, новые
# окна tmux нумерует выше. `{top-left}` — его верхняя левая панель при любых
# base-index и pane-base-index (номер `.0` от pane-base-index зависит).
# Страж формы — scripts/check_tmux_targets.py (test.sh, секция 22).

PROMPT_RE='❯|bypass permissions'
ACTIVE_RE='esc to interrupt'

# has_prompt <pane-text> — is the input prompt visible?
has_prompt() { printf '%s' "${1:-}" | grep -qaE "$PROMPT_RE"; }

# has_active_turn <pane-text> — is a model turn currently running?
has_active_turn() { printf '%s' "${1:-}" | grep -qa "$ACTIVE_RE"; }

# looks_like_overlay <pane-text> — does the pane show local slash-command
# output rather than the conversation? Advisory only: the authoritative test is
# whether Escape brings the prompt back (see watchdog.sh). Kept deliberately
# narrow — matching loosely here would mask real freezes.
looks_like_overlay() {
  printf '%s' "${1:-}" | grep -qaE \
    'Context Usage|Estimated usage by category|Auto-compact window|/context all to expand|Memory files ·|Skills ·'
}

# ── Мастер первого запуска ───────────────────────────────────────────────────
# Claude Code показывает мастер (выбор темы, следом способ входа), когда его
# метка онбординга разошлась с установленной версией — а версию нативный
# установщик двигает сам. Пока мастер на экране, сессия не доходит до промпта:
# MCP-серверы не стартуют, канал не поднимает порт, агент нем.
#
# Проверять это надо ДО has_prompt, потому что распознать мастер по промпту
# нельзя: выбранный пункт меню начинается с того же символа «❯», и has_prompt
# отвечает «да». Отсюда и цена вопроса — для watchdog мастер был неотличим от
# здорового простоя с пустым полем ввода, то есть от состояния, в котором делать
# нечего. Замер на живом хосте 09.09.2026: обе сессии простояли на выборе темы
# двое суток, тревога оператору так и не ушла.
#
# Держим узко, как и looks_like_overlay: только те две строки, которыми мастер
# задаёт свои вопросы. Широкий шаблон здесь маскировал бы настоящие зависания.
ONBOARDING_RE='Choose the text style that looks best|Select login method'

# looks_like_onboarding <pane-text> — на экране мастер первого запуска?
looks_like_onboarding() { printf '%s' "${1:-}" | grep -qaE "$ONBOARDING_RE"; }

# ── Вопрос о каналах для разработки ─────────────────────────────────────────
# Агенты стартуют с --dangerously-load-development-channels (канал Telegram —
# research-preview Claude Code), и на каждом старте claude спрашивает, точно ли
# это локальная разработка: «1. I am using this for local development / 2. Exit».
# Ответ всегда первый пункт — тот же выбор, что оператор сделал, поставив агента.
#
# Пока вопрос на экране, сессия стоит: MCP-серверы не стартуют, порт канала не
# поднимается, агент нем. start-agent.sh отвечает на вопрос, но смотрел на экран
# лишь 30 секунд; 10.09.2026 claude после самообновления поднялся позже, и
# labops-app остался на вопросе. Для watchdog вопрос выглядел как простой или
# застрявший ввод: выбранный пункт начинается с «❯», и has_prompt отвечает «да».
DEV_CHANNELS_RE='I am using this for local development'

# _last_marker_line <pane-text> — последняя строка с «❯»: выбранный пункт меню
# или поле ввода. Судить надо по ней, а не по тексту вопроса где угодно: отвеченный
# вопрос остаётся в захваченной истории над промптом, и по нему watchdog жал бы
# Enter в пустое поле, а в конце концов поднял бы ложную тревогу.
_last_marker_line() { printf '%s' "${1:-}" | grep -a '❯' | tail -1; }

# looks_like_dev_channels_prompt <pane-text> — вопрос на экране и ждёт ответа?
# Считается и при выбранном «2. Exit»: ответ сперва вернёт выбор на первый пункт.
looks_like_dev_channels_prompt() {
  printf '%s' "${1:-}" | grep -qa "$DEV_CHANNELS_RE" || return 1
  _last_marker_line "${1:-}" | grep -qaE "1\. $DEV_CHANNELS_RE|2\. Exit"
}

# ── Гейт «Bypass Permissions mode» ──────────────────────────────────────────
# CLI 2.1.x показывает его на КАЖДОМ старте сессии с
# --dangerously-skip-permissions: «Bypass Permissions mode» и выбор
# «No, exit / Yes, I accept». Сам флаг этот вопрос НЕ снимает — это отдельный
# гейт, как доверие к папке и мастер первого запуска.
#
# Отвечать за оператора мы здесь НЕ будем, и это осознанно: согласие на режим
# без проверок — решение человека за его же клавиатурой, а не автоматики.
# Распознаём экран ради двух вещей: не считать его зависанием (иначе watchdog
# перезапускает сессию, та встаёт на том же вопросе, и так по кругу — у клиента
# это крутилось больше часа, 12.09.2026) и сказать оператору ровно то, что от
# него требуется. Подтверждается один раз на машину: CLI хранит ответ в
# пользовательских настройках, и на последующих стартах вопроса уже нет.
BYPASS_PERMISSIONS_RE='Bypass Permissions mode'

# looks_like_bypass_permissions_prompt <pane-text> — вопрос на экране и ждёт ответа?
# Как и с dev-channels, судим по последней строке с «❯»: отвеченный вопрос
# остаётся в истории панели выше промпта, и по нему мы звали бы оператора зря.
looks_like_bypass_permissions_prompt() {
  printf '%s' "${1:-}" | grep -qa "$BYPASS_PERMISSIONS_RE" || return 1
  _last_marker_line "${1:-}" | grep -qaE 'No, exit|Yes, I accept'
}

# Что показать оператору: одной строкой, с точной командой.
bypass_permissions_hint() {   # <session>
  printf 'агент ждёт подтверждения режима без проверок (Bypass Permissions mode). Подтвердите один раз на этой машине: tmux attach -t =%s → стрелка вниз на «Yes, I accept» → Enter → Ctrl-b d' "${1:-labops-<агент>}"
}

# Пауза после стрелки перед повторным чтением экрана: меню перерисовывается не сразу.
DEV_CHANNELS_SETTLE="${DEV_CHANNELS_SETTLE:-0.5}"

# answer_dev_channels_prompt <session> <pane-text> — подтвердить первый пункт.
# 0 — Enter отправлен на первом пункте; 1 — вопроса нет или выбрать первый пункт
# не удалось. На выбранном «2. Exit» Enter закрыл бы claude, а просто не жать —
# значит оставить сессию стоять до прихода человека: выбор сам с Exit не уйдёт.
# Поэтому сперва стрелка вверх, затем экран перечитывается, и Enter уходит,
# только если выбранным стал первый пункт.
answer_dev_channels_prompt() {
  local session="${1:-}" pane="${2:-}"
  looks_like_dev_channels_prompt "$pane" || return 1
  if ! _last_marker_line "$pane" | grep -qa "1\. $DEV_CHANNELS_RE"; then
    tmux send-keys -t "=$session:^.{top-left}" Up 2>/dev/null || return 1
    sleep "$DEV_CHANNELS_SETTLE"
    pane="$(tmux capture-pane -pt "=$session:^.{top-left}" -S -8 2>/dev/null || true)"
    looks_like_dev_channels_prompt "$pane" || return 1
    _last_marker_line "$pane" | grep -qa "1\. $DEV_CHANNELS_RE" || return 1
  fi
  tmux send-keys -t "=$session:^.{top-left}" Enter 2>/dev/null || return 1
  return 0
}

# Сколько ждать смены экрана после ответа (секунды) и шаг опроса панели.
DEV_CHANNELS_GONE_TIMEOUT="${DEV_CHANNELS_GONE_TIMEOUT:-10}"
DEV_CHANNELS_POLL_SEC="${DEV_CHANNELS_POLL_SEC:-0.25}"

# dev_channels_prompt_wait_gone <session> [таймаут-сек] — дождаться, пока вопрос
# уйдёт с экрана после ответа. 0 — ушёл; 1 — к концу таймаута всё ещё на экране.
# Зачем ждать: claude перерисовывает экран не сразу, и до перерисовки вопрос
# выглядит неотвеченным. Кто проверит его раньше, ответит второй раз — и этот
# Enter уйдёт уже в следующий экран; а доктор записал бы «не уходит» на пустом
# месте. Таймаут 0 — проверить один раз, без ожидания.
dev_channels_prompt_wait_gone() {
  local session="${1:-}" timeout="${2:-$DEV_CHANNELS_GONE_TIMEOUT}" deadline pane
  deadline=$(( $(date +%s) + ${timeout%.*} ))
  while :; do
    pane="$(tmux capture-pane -pt "=$session:^.{top-left}" -S -8 2>/dev/null || true)"
    looks_like_dev_channels_prompt "$pane" || return 0
    [ "$(date +%s)" -lt "$deadline" ] || return 1
    sleep "$DEV_CHANNELS_POLL_SEC"
  done
}

# ── Мёртвая авторизация ──────────────────────────────────────────────────────
# Самый коварный отказ: сессия ЖИВА (TUI рисует ❯, tmux цел, процесс на месте),
# но каждый ход мгновенно падает на авторизации — Claude Code печатает ошибку и
# завершает ход за 0s. Для всех прочих проверок это неотличимо от здорового
# простоя: промпт есть, активного хода нет, поле ввода пусто. Heartbeat при этом
# протухает (Stop-хук не срабатывает — ход не доходит до конца), но протухший
# heartbeat сам по себе рестарт не запускает. Итог: агент молчит сутками, а
# watchdog считает его здоровым (найдено 2026-08-09 на developer: токен истёк в
# 15:00, процесс не смог обновиться, 16 часов тишины).
#
# Практически всегда лечится рестартом сессии: свежий процесс перечитывает
# ~/.claude/.credentials.json. Если же доступ реально отозван — рестарт не
# поможет, поэтому watchdog пробует его ОДИН раз и дальше зовёт оператора.
AUTH_ERR_RE='disabled Claude subscription access|Invalid API key|Please run /login|OAuth token (has )?expired|Credit balance is too low|authentication_error|Unauthorized'

# has_auth_error <pane-text> — в панели видна ошибка авторизации/доступа?
has_auth_error() { printf '%s' "${1:-}" | grep -qaE "$AUTH_ERR_RE"; }

# ── Stuck-input detection & recovery ─────────────────────────────────────────
# The tg channel delivers an inbound by asking Claude Code (research-preview
# `claude/channel`) to inject it into the input and auto-submit. That auto-submit
# intermittently fails, leaving the message in the `❯` box uncommitted — and a
# plain Enter cannot finalise a stuck bracketed-paste (verified: Enter, Escape,
# Ctrl-C, ESC[201~ all fail). The reliable path is to CLEAR the box and re-type
# the text as literal keystrokes + Enter (the same primitive task-poller uses,
# which submits cleanly because it is not a bracketed paste).

# pane_input <pane-text> — the input box contents with ALL whitespace stripped.
# Empty ⇒ clean idle prompt. Mirrors watchdog's emptiness test (❯ renders with a
# trailing U+00A0, not an ASCII space).
pane_input() {
  printf '%s' "${1:-}" | grep -a '❯' | tail -1 \
    | sed -e 's/.*❯//' -e 's/\xc2\xa0//g' -e 's/[[:space:]]//g'
}

# pane_input_raw <pane-text> — the input box contents with internal spaces kept
# but ends trimmed (for RE-TYPING the operator's message). Only the last visual
# line is recoverable from the pane, so a wrapped multi-line inbound cannot be
# faithfully reconstructed — callers must treat this as best-effort.
pane_input_raw() {
  printf '%s' "${1:-}" | grep -a '❯' | tail -1 \
    | sed -e 's/.*❯//' -e 's/\xc2\xa0//g' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# ── Призрак отрисовки vs реальный буфер ──────────────────────────────────────
# ПРОВЕРЕНО НА ЖИВОЙ СЕССИИ 2026-08-09 (developer): когда канал доставляет
# входящее, а auto-submit срывается, Claude Code РИСУЕТ текст в поле, но НЕ
# кладёт его в буфер ввода. Для capture-pane это неотличимо от набранного
# текста, поэтому watchdog годами лечил не ту болезнь: слал Enter (отправлять
# нечего), пытался очистить поле (оно и так пусто), читал призрак снова, решал
# «поле не чистится» и звал оператора.
#
# Различает их ТОЛЬКО позиция курсора: в пустом поле курсор стоит сразу за
# «❯ » (колонка 2), при реально набранном тексте — за последним символом.
#   поле пусто + призрак «проверь второй мозг» → cursor_x=2
#   набрано «тест»                              → cursor_x=6
# Поэтому «залипло ли» решаем по курсору, а текст призрака используем как
# ИСТОЧНИК потерянного сообщения — его достаточно перепечатать и отправить.
PANE_INPUT_COL0="${PANE_INPUT_COL0:-2}"   # колонка курсора в пустом поле («❯ »)

# pane_cursor_x <session> — колонка курсора (пусто, если tmux недоступен).
pane_cursor_x() { tmux display -pt "=$1:^.{top-left}" '#{cursor_x}' 2>/dev/null || true; }

# buffer_is_empty <session> — в БУФЕРЕ ввода ничего нет (что бы ни рисовалось).
# Неизвестный курсор трактуем как «не пусто»: тогда логика откатывается к
# прежнему, текстовому поведению, а не начинает слать лишние клавиши.
buffer_is_empty() {
  local x; x="$(pane_cursor_x "$1")"
  case "$x" in ''|*[!0-9]*) return 1 ;; esac
  [ "$x" -le "$PANE_INPUT_COL0" ]
}

# input_is_multiline <pane-text> — занимает ли ввод больше одной визуальной
# строки. Из панели восстанавливается только строка с «❯», поэтому многострочный
# ввод перепечатывается С ПОТЕРЕЙ — единственный случай, когда оператору есть
# смысл сообщать об успешном восстановлении. Для однострочного сообщения
# восстановление точное, и алерт — чистый шум (обратная связь оператора
# 2026-08-09: «зачем мне это знать?»).
# Разметка поля: рамка ─── / строка с ❯ / [продолжение] / рамка ───.
input_is_multiline() {
  # Два прохода: в панели строк с ❯ несколько (история промптов), нас интересует
  # ТОЛЬКО последняя — текущее поле ввода.
  printf '%s' "${1:-}" | awk '
    { line[NR] = $0; if ($0 ~ /❯/) last = NR }
    END {
      if (!last) exit 1
      for (i = last + 1; i <= NR; i++) {
        # Границы блока ввода: нижняя рамка ИЛИ строка статуса под полем
        # («⏵⏵ bypass permissions …»). Без второго условия статус читался как
        # продолжение ввода и любое сообщение выглядело многострочным.
        if (line[i] ~ /^[─[:space:]]*$/)               exit 1
        if (line[i] ~ /bypass permissions|⏵⏵|esc to interrupt/) exit 1
        if (line[i] ~ /[^[:space:]]/)                  exit 0   # продолжение ввода
      }
      exit 1
    }
  '
}

# ── Атрибуция досылки ────────────────────────────────────────────────────────
# ЖИВОЙ ИНЦИДЕНТ 2026-09-01 (developer, до этого carmella 2026-08-15): в поле
# ввода оказывается нарисованный текст, которого оператор НЕ отправлял, а
# перепечатка ниже честно жмёт по нему Enter. Агент выполняет придуманную
# инструкцию, её результат порождает новый нарисованный текст — и рой уходит в
# самоподдерживающийся цикл (10 «сообщений» за 15 минут; агент успел дописать
# себе .mcp.json и просил root). Пустой буфер сам по себе НЕ доказывает, что
# перед нами потерянное сообщение оператора: он лишь означает «в буфере пусто».
#
# Поэтому досылать разрешено ТОЛЬКО текст, подтверждённый доставкой: плагин на
# каждое входящее пишет метку (см. tg-plugin/plugin/src/channel/inbound-marker.ts),
# и нарисованное должно совпасть со свежей меткой. Нет метки — не наше сообщение,
# отправлять его нельзя ни при каких обстоятельствах.
INBOUND_MARKER_MAX_AGE="${INBOUND_MARKER_MAX_AGE:-600}"   # метка старше — не в счёт
INBOUND_MIN_MATCH_CHARS="${INBOUND_MIN_MATCH_CHARS:-8}"   # короче — совпадение случайно

# inbound_marker_file <agent> — путь метки последнего доставленного входящего.
inbound_marker_file() {
  local dir="${TELEGRAM_STATE_DIR:-${CLAUDE_LAB:-$HOME/.claude-lab}/shared/state/$1/telegram}"
  printf '%s/last-inbound' "$dir"
}

# inbound_delivered_text <agent> — полный текст последнего доставленного
# входящего (без строки времени). Панель отдаёт только первую визуальную строку
# поля ввода, поэтому длинное сообщение из неё восстанавливается ОБРЕЗАННЫМ
# (замерено: 202 символа → 77). Метка хранит его целиком и побайтово, так что
# перепечатывать надо её, а не то, что видно на экране.
inbound_delivered_text() {
  local file; file="$(inbound_marker_file "${1:-}")"
  [ -f "$file" ] || return 1
  tail -n +2 "$file" 2>/dev/null
}

# _squash <text> — схлопнуть пробелы: панель переносит и дополняет строки, из-за
# чего побайтовое сравнение с оригиналом бессмысленно.
_squash() { printf '%s' "${1:-}" | tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//'; }

# inbound_matches <agent> <painted-text> — подтверждён ли нарисованный текст
# свежей доставкой. Панель отдаёт только строку с «❯» (первая визуальная строка
# длинного сообщения, возможно обрезанная), поэтому ищем её как подстроку
# доставленного текста, а не полное равенство.
inbound_matches() {
  local agent="${1:-}" painted; painted="$(_squash "${2:-}")"
  local file ts now delivered
  [ "${#painted}" -ge "$INBOUND_MIN_MATCH_CHARS" ] || return 1
  file="$(inbound_marker_file "$agent")"
  [ -f "$file" ] || return 1
  ts="$(head -1 "$file" 2>/dev/null || echo '')"
  case "$ts" in ''|*[!0-9]*) return 1 ;; esac
  now="$(date +%s)"
  [ $(( now - ts )) -le "$INBOUND_MARKER_MAX_AGE" ] || return 1
  delivered="$(_squash "$(tail -n +2 "$file" 2>/dev/null || true)")"
  case "$delivered" in *"$painted"*) return 0 ;; *) return 1 ;; esac
}

# is_stuck_input <pane-text> — a message is sitting in the input unsubmitted:
# prompt visible, no active turn, input non-empty, and NOT the rotating
# placeholder hint Try"...". This is the state to recover.
is_stuck_input() {
  local t="${1:-}" inp
  has_prompt "$t" || return 1
  has_active_turn "$t" && return 1
  inp="$(pane_input "$t")"
  [ -n "$inp" ] || return 1
  printf '%s' "$inp" | grep -qE '^Try".*"$' && return 1
  return 0
}
