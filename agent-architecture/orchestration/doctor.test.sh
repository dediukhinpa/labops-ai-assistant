#!/usr/bin/env bash
# doctor.test.sh — юнит-тест «одной кнопки» doctor.sh.
#
# Настоящих tmux/systemd/сети здесь нет: doctor должен давать оператору верный
# вердикт в состояниях, которые вручную не воспроизвести (просроченная подписка,
# зависший TUI, застрявшее сообщение). Поэтому окружение подменяется мок-командами
# в PATH, а состояние задаётся переменными MOCK_*.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCTOR="$HERE/doctor.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()  { echo "✓ $*"; pass=$((pass+1)); }
bad() { echo "✗ $*"; fail=$((fail+1)); }

# ── Моки ─────────────────────────────────────────────────────────────────────
MOCKS="$TMP/bin"
mkdir -p "$MOCKS"

cat > "$MOCKS/tmux" <<'EOF'
#!/usr/bin/env bash
# Состояние: MOCK_SESSION=1|0, MOCK_PANE=<текст>, MOCK_CURSOR_X=<колонка>.
case "$1" in
  has-session) [ "${MOCK_SESSION:-1}" = "1" ] ;;
  capture-pane)
    # После Enter экран сменяется на MOCK_PANE_AFTER_ENTER (если задан): так
    # тест видит, что ответ на вопрос действительно дошёл.
    if [ -n "${MOCK_PANE_AFTER_ENTER:-}" ] && grep -qx enter "${MOCK_KEYLOG:-/dev/null}" 2>/dev/null
    then printf '%s' "$MOCK_PANE_AFTER_ENTER"
    else printf '%s' "${MOCK_PANE:-}"; fi ;;
  display)      printf '%s' "${MOCK_CURSOR_X:-2}" ;;
  send-keys)
    # Фиксируем, ЧТО ушло в панель: Enter, стрелку и факт перепечатки (-l) —
    # чтобы тест отличал реальную досылку от «сделал вид» и видел лишние клавиши.
    for a in "$@"; do
      case "$a" in Enter) echo enter ;; Up) echo up ;; -l) echo typed ;; esac
    done >> "${MOCK_KEYLOG:-/dev/null}"
    exit 0 ;;
  *) exit 0 ;;
esac
EOF

cat > "$MOCKS/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  list-unit-files) [ "${MOCK_UNIT_INSTALLED:-1}" = "1" ] ;;
  is-active)       [ "${MOCK_UNIT_ACTIVE:-1}" = "1" ] ;;
  *) exit 0 ;;
esac
EOF

# Общая память «жива» — иначе каждый прогон тащил бы примечание про порты.
cat > "$MOCKS/curl" <<'EOF'
#!/usr/bin/env bash
exit "${MOCK_CURL_RC:-0}"
EOF

# Ни осиротевших процессов, ни поллеров.
cat > "$MOCKS/pgrep" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF

# Заглушка старта агента: MOCK_START_RC задаёт успех/провал.
cat > "$TMP/start-agent.sh" <<'EOF'
#!/usr/bin/env bash
echo started >> "${MOCK_STARTLOG:-/dev/null}"
exit "${MOCK_START_RC:-0}"
EOF

chmod +x "$MOCKS"/* "$TMP/start-agent.sh"

# ── Учётные данные ───────────────────────────────────────────────────────────
mk_creds() {   # <refreshTokenExpiresAt в мс, или "none">
  local f="$TMP/creds-$1.json"
  if [ "$1" = "none" ]; then
    printf '{"claudeAiOauth":{"subscriptionType":"max"}}' > "$f"
  else
    printf '{"claudeAiOauth":{"subscriptionType":"max","refreshTokenExpiresAt":%s}}' "$1" > "$f"
  fi
  printf '%s' "$f"
}
FUTURE="$(( ($(date +%s) + 86400) * 1000 ))"
PAST="$(( ($(date +%s) - 86400) * 1000 ))"
CREDS_OK="$(mk_creds "$FUTURE")"
CREDS_DEAD="$(mk_creds "$PAST")"

# ── Панели ───────────────────────────────────────────────────────────────────
IDLE='────────────────────
❯
  ⏵⏵ bypass permissions on (shift+tab to cycle)'

STUCK='────────────────────
❯ проверь второй мозг
  ⏵⏵ bypass permissions on (shift+tab to cycle)'

AUTH_DEAD='● Your organization has disabled Claude subscription access for Claude Code ·
✻ Cogitated for 0s
────────────────────
❯
  ⏵⏵ bypass permissions on'

DEAD_TUI=''

# Вопрос о каналах разработки — хвост панели labops-app 10.09.2026.
DEV_Q=' Channels: server:labops-channel

 ❯ 1. I am using this for local development
   2. Exit

 Enter to confirm · Esc to cancel'
DEV_Q_EXIT=' Channels: server:labops-channel

   1. I am using this for local development
 ❯ 2. Exit

 Enter to confirm · Esc to cancel'

# Паузы ответа на вопрос о каналах обнулены: мок перерисовывает экран мгновенно.
DEV_WAITS="DOCTOR_DEV_CHANNELS_WAIT=0 DEV_CHANNELS_SETTLE=0"

# run <описание переменных окружения через env> — печатает вывод, возвращает код.
run() {
  # shellcheck disable=SC2086  # DEV_WAITS — список присваиваний для env
  PATH="$MOCKS:$PATH" \
  CLAUDE_LAB="$TMP/lab" \
  DOCTOR_START_SCRIPT="$TMP/start-agent.sh" \
  RECOVER_SETTLE=0 RECOVER_SUBMIT_DELAY=0 \
  "$@" $DEV_WAITS bash "$DOCTOR" developer 2>&1
}

expect() {   # <описание> <ожидаемый код> <подстрока> -- <env...>
  local desc="$1" want_rc="$2" want_txt="$3"; shift 3
  [ "${1:-}" = "--" ] && shift
  local out rc=0
  out="$(run "$@")" || rc=$?
  if [ "$rc" -ne "$want_rc" ]; then
    bad "$desc — код $rc, ожидался $want_rc"; echo "    $out"; return
  fi
  if ! printf '%s' "$out" | grep -qF "$want_txt"; then
    bad "$desc — нет «$want_txt»"; echo "    $out"; return
  fi
  ok "$desc"
}

# ── Сценарии ─────────────────────────────────────────────────────────────────

expect "здоровый агент: «всё в порядке»" 0 "всё в порядке" -- \
  env CLAUDE_CREDENTIALS_FILE="$CREDS_OK" MOCK_PANE="$IDLE"

expect "просроченный вход: вердикт про подписку" 1 "подписка Claude недействительна" -- \
  env CLAUDE_CREDENTIALS_FILE="$CREDS_DEAD" MOCK_PANE="$IDLE"

expect "нет файла входа: зовём войти заново" 1 "нет входа в Claude Code" -- \
  env CLAUDE_CREDENTIALS_FILE="$TMP/absent.json" MOCK_PANE="$IDLE"

expect "срок входа не читается — не выдумываем поломку" 0 "всё в порядке" -- \
  env CLAUDE_CREDENTIALS_FILE="$(mk_creds none)" MOCK_PANE="$IDLE"

expect "ошибка доступа в панели — вердикт, а не рестарт" 1 "не проходит вход Claude" -- \
  env CLAUDE_CREDENTIALS_FILE="$CREDS_OK" MOCK_PANE="$AUTH_DEAD"

expect "служба остановлена — нужен root" 1 "служба агента остановлена" -- \
  env CLAUDE_CREDENTIALS_FILE="$CREDS_OK" MOCK_PANE="$IDLE" MOCK_UNIT_ACTIVE=0

expect "агента нет, без --fix только диагноз" 1 "агент не запущен" -- \
  env CLAUDE_CREDENTIALS_FILE="$CREDS_OK" MOCK_SESSION=0

# ── --fix действительно чинит ────────────────────────────────────────────────
fix_run() {
  # shellcheck disable=SC2086  # DEV_WAITS — список присваиваний для env
  PATH="$MOCKS:$PATH" \
  CLAUDE_LAB="$TMP/lab" \
  DOCTOR_START_SCRIPT="$TMP/start-agent.sh" \
  RECOVER_SETTLE=0 RECOVER_SUBMIT_DELAY=0 \
  "$@" $DEV_WAITS bash "$DOCTOR" developer --fix 2>&1
}

out="$(fix_run env CLAUDE_CREDENTIALS_FILE="$CREDS_OK" MOCK_SESSION=0 \
  MOCK_STARTLOG="$TMP/start1.log")" && rc=0 || rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qF "запустил агента заново" && [ -s "$TMP/start1.log" ]; then
  ok "--fix поднимает остановленного агента"
else
  bad "--fix не поднял агента (код $rc)"; echo "    $out"
fi

# Застрявшее сообщение: курсор в колонке 2 — текст только НАРИСОВАН, буфера нет.
# Правильное лечение — перепечатать и отправить (Enter должен уйти).
out="$(fix_run env CLAUDE_CREDENTIALS_FILE="$CREDS_OK" MOCK_PANE="$STUCK" \
  MOCK_CURSOR_X=2 MOCK_KEYLOG="$TMP/keys.log")" && rc=0 || rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qF "дослал застрявшее сообщение" && [ -s "$TMP/keys.log" ]; then
  ok "--fix досылает застрявшее сообщение"
else
  bad "--fix не дослал застрявшее сообщение (код $rc)"; echo "    $out"
fi

# Тот же случай без --fix: чинить нельзя, но сказать оператору обязаны.
expect "застрявшее сообщение видно и без --fix" 1 "сообщение застряло" -- \
  env CLAUDE_CREDENTIALS_FILE="$CREDS_OK" MOCK_PANE="$STUCK" MOCK_CURSOR_X=2

# ── Вопрос о каналах разработки ──────────────────────────────────────────────
# Экран вопроса проходит и has_prompt, и is_stuck_input: до фикса --fix принимал
# его за застрявшее сообщение и перепечатывал строку меню с Enter — а на
# «2. Exit» такой Enter закрыл бы claude.
# keys <лог> — что ушло в панель, одной строкой (для сообщения о провале).
keys() { tr '\n' ' ' < "$1"; }

: > "$TMP/dev1.log"
out="$(run env CLAUDE_CREDENTIALS_FILE="$CREDS_OK" MOCK_PANE="$DEV_Q" \
  MOCK_KEYLOG="$TMP/dev1.log")" && rc=0 || rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -qF "стартовый вопрос" \
   && [ ! -s "$TMP/dev1.log" ]; then
  ok "вопрос о каналах без --fix: понятная причина и ни одной клавиши"
else
  bad "вопрос о каналах без --fix (код $rc, клавиши: $(keys "$TMP/dev1.log"))"
  echo "    $out"
fi

: > "$TMP/dev2.log"
out="$(fix_run env CLAUDE_CREDENTIALS_FILE="$CREDS_OK" MOCK_PANE="$DEV_Q" \
  MOCK_PANE_AFTER_ENTER="$IDLE" MOCK_KEYLOG="$TMP/dev2.log")" && rc=0 || rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qF "подтвердил стартовый вопрос" \
   && [ "$(cat "$TMP/dev2.log")" = enter ]; then
  ok "--fix отвечает на вопрос одним Enter, без перепечатки меню"
else
  bad "--fix на вопросе о каналах (код $rc, клавиши: $(keys "$TMP/dev2.log"))"
  echo "    $out"
fi

# Enter ушёл, а вопрос остался — «починил» писать нельзя.
: > "$TMP/dev3.log"
out="$(fix_run env CLAUDE_CREDENTIALS_FILE="$CREDS_OK" MOCK_PANE="$DEV_Q" \
  MOCK_KEYLOG="$TMP/dev3.log")" && rc=0 || rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -qF "не принимает ответ" \
   && ! grep -q typed "$TMP/dev3.log"; then
  ok "--fix: неушедший вопрос — вердикт оператору, не «починил»"
else
  bad "--fix на неуходящем вопросе (код $rc, клавиши: $(keys "$TMP/dev3.log"))"
  echo "    $out"
fi

# Выбран «2. Exit»: Enter в этот экран закрыл бы claude — он не должен уйти.
: > "$TMP/dev4.log"
out="$(fix_run env CLAUDE_CREDENTIALS_FILE="$CREDS_OK" MOCK_PANE="$DEV_Q_EXIT" \
  MOCK_KEYLOG="$TMP/dev4.log")" && rc=0 || rc=$?
if [ "$rc" -eq 1 ] && ! grep -qE 'enter|typed' "$TMP/dev4.log"; then
  ok "--fix: на выбранном «2. Exit» Enter не нажат"
else
  bad "--fix нажал Enter на «2. Exit» (код $rc, клавиши: $(keys "$TMP/dev4.log"))"
  echo "    $out"
fi

# Мёртвый TUI: промпта нет даже после Escape → рестарт как последнее средство.
out="$(fix_run env CLAUDE_CREDENTIALS_FILE="$CREDS_OK" MOCK_PANE="$DEAD_TUI" \
  MOCK_STARTLOG="$TMP/start2.log")" && rc=0 || rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qF "перезапустил зависшего агента" && [ -s "$TMP/start2.log" ]; then
  ok "--fix перезапускает зависший TUI"
else
  bad "--fix не перезапустил зависший TUI (код $rc)"; echo "    $out"
fi

# Здоровая панель рестарта НЕ заслуживает: рестарт стирает переписку агента.
out="$(fix_run env CLAUDE_CREDENTIALS_FILE="$CREDS_OK" MOCK_PANE="$IDLE" \
  MOCK_STARTLOG="$TMP/start3.log")" && rc=0 || rc=$?
if [ "$rc" -eq 0 ] && [ ! -s "$TMP/start3.log" ]; then
  ok "--fix не трогает здорового агента"
else
  bad "--fix зря перезапустил здорового агента"; echo "    $out"
fi

# ── Форма вывода ─────────────────────────────────────────────────────────────
# Вердикт читает человек в Telegram: короткий, без внутренней кухни.
out="$(run env CLAUDE_CREDENTIALS_FILE="$CREDS_OK" MOCK_PANE="$IDLE")"
lines="$(printf '%s\n' "$out" | grep -c . || true)"
if [ "$lines" -lt 2 ]; then bad "вердикт пуст — проверка формы ничего не проверила"; fi
if [ "$lines" -le 4 ]; then ok "вердикт короткий ($lines строк)"; else bad "вердикт разросся: $lines строк"; fi
if printf '%s' "$out" | grep -qE 'tmux|systemctl|heartbeat|pgrep|bun'; then
  bad "в вердикте протекла внутренняя кухня"
else
  ok "в вердикте нет внутренней кухни"
fi

echo
echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
