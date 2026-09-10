#!/usr/bin/env bash
# pane.test.sh — unit test for the pane classifier, plus a REAL tmux test that
# the Escape-before-restart ladder distinguishes a slash-command overlay from a
# dead TUI. The regression: an operator running /context in the pane made the
# watchdog restart a healthy session ("no prompt rendered — heartbeat stale").
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/pane.sh"
# Живые секции ниже заводят настоящие сессии. Раньше они шли в ОБЩИЙ сервер, где
# сидят агенты, — а при заданной $TMUX (у панелей агентов она есть всегда) и
# вовсе в сервер той сессии, из которой запущен тест. Теперь сервер свой.
TEST_TMP="$(mktemp -d)"
# shellcheck source=lib/tmux-test-isolation.sh
. "$HERE/tmux-test-isolation.sh"
tmux_test_isolate "$TEST_TMP"
cleanup() { tmux_test_kill_server; rm -rf "$TEST_TMP"; }
trap cleanup EXIT
pass=0; fail=0
ok()  { echo "✓ $*"; pass=$((pass+1)); }
bad() { echo "✗ $*"; fail=$((fail+1)); }

IDLE='────────────────────
❯
  ⏵⏵ bypass permissions on (shift+tab to cycle)'

ACTIVE='● Reading files…
  ✻ Thinking (esc to interrupt)'

# Real /context output, trimmed — the exact shape that caused the false restart.
OVERLAY='  Context Usage
  ⛁ System tools: 15.4k tokens (3.9%)
  ⛁ Messages: 7.6k tokens (1.9%)
  ⛶ Free space: 329.1k (82.3%)
  Auto-compact window: 400k tokens
  /context all to expand'

DEAD=''

# ---- classifier ------------------------------------------------------------
has_prompt "$IDLE"        && ok "idle pane: prompt detected"      || bad "idle pane: prompt missed"
has_prompt "$OVERLAY"     && bad "overlay: prompt falsely found"  || ok "overlay: no prompt (as the watchdog sees it)"
has_prompt "$DEAD"        && bad "dead pane: prompt falsely found" || ok "dead pane: no prompt"
has_active_turn "$ACTIVE" && ok "active turn detected"            || bad "active turn missed"
has_active_turn "$IDLE"   && bad "idle misread as active turn"    || ok "idle is not an active turn"
looks_like_overlay "$OVERLAY" && ok "overlay recognised"          || bad "overlay not recognised"
looks_like_overlay "$IDLE"    && bad "idle misread as overlay"    || ok "idle is not an overlay"
looks_like_overlay "$ACTIVE"  && bad "active turn misread as overlay" || ok "active turn is not an overlay"

# ---- мёртвая авторизация ---------------------------------------------------
# Реальный хвост панели developer 2026-08-09: сессия жива, промпт нарисован,
# ход завершается за 0s ошибкой доступа. Все прочие проверки видят «здоровый
# простой», поэтому агент молчал 16 часов.
AUTH_DEAD='● Your organization has disabled Claude subscription access for Claude Code ·
  Use an Anthropic API key instead, or ask your admin to enable access
✻ Cogitated for 0s
────────────────────
❯
  ⏵⏵ bypass permissions on'
has_auth_error "$AUTH_DEAD" && ok "auth error detected"               || bad "auth error missed"
has_auth_error "$IDLE"      && bad "idle misread as auth error"       || ok "idle is not an auth error"
has_auth_error "$ACTIVE"    && bad "active turn misread as auth error" || ok "active turn is not an auth error"
# И — главное — почему это нужно отдельной веткой: панель с мёртвой авторизацией
# неотличима от здорового простоя для остальных классификаторов.
has_prompt "$AUTH_DEAD"      && ok "auth-dead pane still renders a prompt (why it hid)" \
                             || bad "auth-dead pane: prompt missed"
is_stuck_input "$AUTH_DEAD"  && bad "auth-dead pane misread as stuck input" \
                             || ok "auth-dead pane is not stuck input (nothing typed)"

# ---- мастер первого запуска -------------------------------------------------
# Реальный хвост панели developer 2026-09-09, снятый ровно так, как его берёт
# watchdog (capture-pane -S -8): сессия перезапустилась на обновившийся CLI и
# встала на выборе темы. Простояла двое суток — канал всё это время был мёртв.
ONBOARDING='Welcome to Claude Code v2.1.263

 Let'"'"'s get started.

 Choose the text style that looks best with your terminal
 To change this later, run /theme

   1. Auto (match terminal)
 ❯ 2. Dark mode ✔
   3. Light mode
   4. Dark mode (colorblind-friendly)'

# Второй шаг мастера — на нём сессия встаёт точно так же.
ONBOARDING_LOGIN=' Select login method:
 ❯ 1. Claude account with subscription · Pro, Max, Team, or Enterprise
   2. Anthropic Console account · API usage billing'

looks_like_onboarding "$ONBOARDING"       && ok "мастер (выбор темы) распознан" \
                                          || bad "мастер (выбор темы) пропущен"
looks_like_onboarding "$ONBOARDING_LOGIN" && ok "мастер (способ входа) распознан" \
                                          || bad "мастер (способ входа) пропущен"
looks_like_onboarding "$IDLE"    && bad "простой принят за мастер"      || ok "простой — не мастер"
looks_like_onboarding "$ACTIVE"  && bad "активный ход принят за мастер" \
                                 || ok "активный ход — не мастер"
looks_like_onboarding "$OVERLAY" && bad "оверлей принят за мастер"      || ok "оверлей — не мастер"
looks_like_onboarding "$DEAD"    && bad "пустая панель принята за мастер" \
                                 || ok "пустая панель — не мастер"
# И — главное — почему нужна отдельная ветка ДО has_prompt: «❯» стоит у
# выбранного пункта меню, поэтому мастер выглядит здоровым простоем.
has_prompt "$ONBOARDING"     && ok "мастер рисует «❯» (почему он и прятался)" \
                             || bad "у мастера не нашлось «❯» — проверка потеряла смысл"
# Мастер выглядит и как застрявший ввод: после «❯» стоит текст пункта меню.
# Это не лечится в предикате — «2. Dark mode ✔» неотличимо от набранной строки.
# Отсюда требование к порядку веток в watchdog.sh, проверяемое ниже.
is_stuck_input "$ONBOARDING" && ok "мастер похож и на застрявший ввод (вторая причина прятаться)" \
                             || bad "мастер уже не похож на застрявший ввод — проверьте ветку (B)"

# ---- вопрос о каналах для разработки ---------------------------------------
# Хвост панели labops-app 10.09.2026: claude после самообновления поднялся позже,
# чем start-agent.sh смотрел на экран, и сессия встала на вопросе.
DEV_CHANNELS=' Channels: server:labops-channel

 ❯ 1. I am using this for local development
   2. Exit

 Enter to confirm · Esc to cancel'
DEV_CHANNELS_EXIT=' Channels: server:labops-channel

   1. I am using this for local development
 ❯ 2. Exit

 Enter to confirm · Esc to cancel'
# Выбранный пункт рисуется и с неразрывным пробелом после «❯» — как поле ввода.
DEV_CHANNELS_NBSP="$(printf ' \xe2\x9d\xaf\xc2\xa01. I am using this for local development\n   2. Exit')"
# Вопрос уже отвечен, но остался в захваченной истории над свежим промптом.
DEV_ANSWERED=' ❯ 1. I am using this for local development
   2. Exit
 Enter to confirm · Esc to cancel
────────────────────
❯
  ⏵⏵ bypass permissions on'

looks_like_dev_channels_prompt "$DEV_CHANNELS"      && ok "вопрос о каналах распознан" \
                                                    || bad "вопрос о каналах пропущен"
looks_like_dev_channels_prompt "$DEV_CHANNELS_NBSP" && ok "вопрос распознан и с nbsp после «❯»" \
                                                    || bad "вопрос с nbsp после «❯» пропущен"
looks_like_dev_channels_prompt "$DEV_CHANNELS_EXIT" && ok "вопрос с выбранным Exit — тоже вопрос (учёт и эскалация)" \
                                                    || bad "вопрос с выбранным Exit не распознан"
looks_like_dev_channels_prompt "$DEV_ANSWERED" && bad "отвеченный вопрос из истории принят за живой (ложный Enter и тревога)" \
                                               || ok "отвеченный вопрос в истории — не вопрос"
for pane in "$IDLE" "$ACTIVE" "$OVERLAY" "$ONBOARDING" "$DEAD"; do
  if looks_like_dev_channels_prompt "$pane"; then
    bad "чужая панель принята за вопрос о каналах: [$(printf '%s' "$pane" | head -1)]"
  else
    ok "не вопрос о каналах: [$(printf '%s' "$pane" | head -1)]"
  fi
done
# Почему нужна отдельная ветка выше всех: вопрос выглядит и промптом, и вводом.
has_prompt "$DEV_CHANNELS"     && ok "вопрос о каналах рисует «❯» (почему он прятался)" \
                               || bad "у вопроса не нашлось «❯» — проверка потеряла смысл"
is_stuck_input "$DEV_CHANNELS" && ok "вопрос похож и на застрявший ввод (вторая причина)" \
                               || bad "вопрос уже не похож на застрявший ввод — проверьте ветку (B)"

# Ответ: Enter — только на первом пункте. Мок tmux записывает нажатия, а экран
# отдаёт MOCK_PANE_NOW — или MOCK_PANE_AFTER_UP, если стрелка уже нажата.
KEYS="$TEST_TMP/keys"; : > "$KEYS"
MOCK_PANE_NOW=""; MOCK_PANE_AFTER_UP=""
DEV_CHANNELS_SETTLE=0
tmux() {
  case "${1:-}" in
    send-keys)
      shift; [ "${1:-}" = -t ] && shift 2
      printf '%s\n' "${1:-}" >> "$KEYS" ;;
    capture-pane)
      if [ -n "$MOCK_PANE_AFTER_UP" ] && grep -qx Up "$KEYS"; then
        printf '%s' "$MOCK_PANE_AFTER_UP"
      else
        printf '%s' "$MOCK_PANE_NOW"
      fi ;;
  esac
  return 0
}
pressed() { tr '\n' ' ' < "$KEYS" | sed 's/ $//'; }
if answer_dev_channels_prompt fake "$DEV_CHANNELS" && [ "$(pressed)" = Enter ]; then
  ok "первый пункт подтверждён одним Enter"
else
  bad "первый пункт не подтверждён (нажато: $(pressed))"
fi
# Выбран «2. Exit». Enter на нём закрыл бы claude, а без стрелки выбор с Exit
# не сдвинул бы никто: watchdog только считал бы попытки и в конце звал
# оператора. Стрелка возвращает выбор; Enter — лишь когда экран это подтвердил.
: > "$KEYS"; MOCK_PANE_NOW="$DEV_CHANNELS_EXIT"; MOCK_PANE_AFTER_UP="$DEV_CHANNELS"
if answer_dev_channels_prompt fake "$DEV_CHANNELS_EXIT" && [ "$(pressed)" = "Up Enter" ]; then
  ok "на «2. Exit» выбор возвращён стрелкой на первый пункт, затем Enter"
else
  bad "на «2. Exit» ответ неверен (нажато: $(pressed))"
fi
: > "$KEYS"; MOCK_PANE_AFTER_UP=""
if ! answer_dev_channels_prompt fake "$DEV_CHANNELS_EXIT" && [ "$(pressed)" = Up ]; then
  ok "стрелка не сдвинула выбор с «Exit» — Enter не нажат"
else
  bad "Enter нажат на «Exit» или стрелки не было (нажато: $(pressed))"
fi
MOCK_PANE_NOW=""
for pane in "$DEV_ANSWERED" "$IDLE"; do
  : > "$KEYS"
  if answer_dev_channels_prompt fake "$pane" || [ -s "$KEYS" ]; then
    bad "клавиша нажата там, где нельзя: [$(printf '%s' "$pane" | grep -a '❯' | tail -1)]"
  else
    ok "ни одной клавиши: [$(printf '%s' "$pane" | grep -a '❯' | tail -1)]"
  fi
done
unset -f tmux
DEV_CHANNELS_SETTLE=0.5

# ---- stuck-input detection (pure) ------------------------------------------
STUCK='────────────────────
❯ что дальше по плану, босс
  ⏵⏵ bypass permissions on'
HINT='────────────────────
❯ Try"fix lint errors"
  ⏵⏵ bypass permissions on'
is_stuck_input "$STUCK"   && ok "stuck input detected"                 || bad "stuck input missed"
is_stuck_input "$IDLE"    && bad "clean idle misread as stuck"         || ok "clean idle is not stuck"
is_stuck_input "$ACTIVE"  && bad "active turn misread as stuck"        || ok "active turn is not stuck (would clobber work)"
is_stuck_input "$HINT"    && bad "placeholder hint misread as stuck"   || ok "placeholder hint is not stuck"
[ "$(pane_input_raw "$STUCK")" = "что дальше по плану, босс" ] \
  && ok "pane_input_raw preserves the message text (for retype)" \
  || bad "pane_input_raw mangled the text: [$(pane_input_raw "$STUCK")]"

# ---- recover_stuck_input (mocked tmux) -------------------------------------
# tmux is overridden with a stateful mock here, then `unset -f`d so the real
# tmux section below uses the real binary.
. "$HERE/pane-recover.sh"
RECOVER_SETTLE=0
RECOVER_SUBMIT_DELAY=0
SENT="$(mktemp)"; CLEARED=0
# CURSOR_X — что мок сообщает про КУРСОР, независимо от отрисовки. Именно этим
# отличается набранный текст (курсор ушёл вправо) от призрака отрисовки
# (курсор в колонке 2 при «полном» на вид поле).
CURSOR_X=21
# PHANTOM=1 — воспроизводит боевой случай: буфер пуст, но текст ОСТАЁТСЯ
# нарисованным что бы мы ни нажимали. Без этого мок «самоисцелялся» после C-u и
# тест проходил даже со старым кодом, ничего не гарантируя.
PHANTOM=0
tmux() {
  case "$1" in
    capture-pane)
      if [ "$PHANTOM" -eq 1 ]; then printf '%s' "$STUCK"
      elif [ "$CLEARED" -eq 0 ]; then printf '%s' "$STUCK"
      else printf '%s' "$IDLE"; fi ;;
    display)      printf '%s' "$CURSOR_X" ;;
    send-keys)
      shift; [ "${1:-}" = "-t" ] && shift 2
      case "${1:-}" in
        C-u)    [ "$PHANTOM" -eq 1 ] || { CLEARED=1; CURSOR_X=2; } ;;
        -l)     echo "TYPE:${2:-}" >> "$SENT" ;;
        Enter)  echo "ENTER" >> "$SENT" ;;
        BSpace) echo "BSPACE" >> "$SENT" ;;
      esac ;;
  esac
}
recover_stuck_input "fake-session"; rc=$?
[ "$rc" -eq 0 ] && ok "recover: returns success on a stuck box" || bad "recover: rc=$rc"
grep -q 'TYPE:что дальше по плану, босс' "$SENT" \
  && ok "recover: re-types the captured message literally" || bad "recover: message not re-typed"
grep -q '^ENTER$' "$SENT" && ok "recover: submits with Enter" || bad "recover: no Enter"
# Not stuck → no-op (rc=2)
CLEARED=1; : > "$SENT"
recover_stuck_input "fake-session"; rc=$?
{ [ "$rc" -eq 2 ] && [ ! -s "$SENT" ]; } && ok "recover: no-op on a clean prompt (rc=2)" \
  || bad "recover: acted on a clean prompt (rc=$rc, sent=$(cat "$SENT"))"

# --- однострочный vs многострочный ввод (кого будить алертом) ---------------
# Точное восстановление оператора не касается; потерянный хвост — касается.
ONELINE='────────────────────
❯ выкатывай, не жди юриста
────────────────────
  ⏵⏵ bypass permissions on'
MULTILINE='────────────────────
❯ Проверка связи после рестарта сессии. Ответь оператору через reply одной
  короткой строкой, что ты снова на связи. Ничего больше не делай.
────────────────────
  ⏵⏵ bypass permissions on'
input_is_multiline "$ONELINE"   && bad "однострочный ввод принят за многострочный (лишний алерт)" \
                                || ok "однострочный ввод: алерта оператору не будет"
input_is_multiline "$MULTILINE" && ok "многострочный ввод распознан (восстановится с потерей)" \
                                || bad "многострочный ввод не распознан — оператор не узнает об обрезке"
# История промптов выше по панели не должна читаться как продолжение ввода.
input_is_multiline "$STUCK"     && bad "история промптов принята за продолжение ввода" \
                                || ok "анализируется только последний ❯-блок"

# --- РЕГРЕССИЯ 2026-08-09: призрак отрисовки при ПУСТОМ буфере --------------
# Именно этот случай встречается в бою (сорванный auto-submit канала рисует
# сообщение, но в буфер не кладёт) — и именно на нём старое восстановление
# сдавалось с «box won't clear», хотя чистить было нечего.
CLEARED=0; CURSOR_X=2; PHANTOM=1; : > "$SENT"   # текст нарисован, буфер пуст
buffer_is_empty fake-session && ok "призрак распознан: буфер пуст, хотя текст нарисован" \
                             || bad "призрак принят за набранный текст (курсор проигнорирован)"
recover_stuck_input "fake-session"; rc=$?
[ "$rc" -eq 0 ] && ok "recover: призрак → доставка (rc=0), а не отказ box-wont-clear" \
                || bad "recover: сдался на призраке (rc=$rc) — регрессия вернулась"
grep -q 'TYPE:что дальше по плану, босс' "$SENT" \
  && ok "recover: потерянное сообщение перепечатано из отрисовки" \
  || bad "recover: сообщение не восстановлено (sent=$(cat "$SENT"))"
grep -q '^ENTER$' "$SENT" && ok "recover: призрак отправлен Enter'ом" || bad "recover: нет Enter"
grep -q '^BSPACE$' "$SENT" && bad "recover: лупит BSpace по пустому буферу" \
                           || ok "recover: не чистит то, что уже пусто"

# Набранный оператором текст (курсор ушёл вправо) — поле чистим перед перепечаткой.
CLEARED=0; CURSOR_X=21; PHANTOM=0; : > "$SENT"
buffer_is_empty fake-session && bad "набранный текст принят за призрак" \
                             || ok "набранный текст распознан как реальный буфер"
rm -f "$SENT"
unset -f tmux    # restore real tmux for the live section below

# wait_pane <session> <предикат> -- ждать, пока панель не отрисуется.
#
# Раньше здесь стоял фиксированный `sleep 1`. Хватало его не всегда: гейт гоняет
# эти случаи вместе с десятком других, а на живом хосте рядом работают два
# агента и сервисы мозга. Под нагрузкой панель не успевала отрисоваться, capture
# возвращал пустоту, и тест падал примерно раз на четыре прогона -- мигающий
# гейт, который приучает не верить красному. Ждём появления нужного содержимого,
# а не абстрактную секунду.
PANE_WAIT_TRIES="${PANE_WAIT_TRIES:-40}"   # 40 x 0.25с = до 10с
wait_pane() {
  local s="$1" pred="$2" i
  for ((i = 0; i < PANE_WAIT_TRIES; i++)); do
    t="$(tmux capture-pane -pt "=$s:^.{top-left}" -S -8 2>/dev/null)"
    if "$pred" "$t"; then return 0; fi
    sleep 0.25
  done
  return 1
}

# Предикат «панель не пуста»: для случаев, где ждём смены картинки, а не
# конкретного признака.
pane_not_empty() { [ -n "$(printf '%s' "$1" | tr -d '[:space:]')" ]; }

# ---- real tmux: Escape must restore the prompt after an overlay -------------
# This is the actual discriminator the watchdog relies on, so stubbing it would
# prove nothing. Skips cleanly where tmux is unavailable (CI containers).
if command -v tmux >/dev/null 2>&1; then
  S="panetest-$$"
  tmux kill-session -t "=$S" 2>/dev/null || true
  # A tiny fake TUI: prints a prompt, and on Escape redraws it. `less` stands in
  # for the overlay — it hides the prompt and exits on Escape via its keymap.
  if tmux new-session -d -s "$S" -x 80 -y 20 \
       "bash -c 'while :; do printf \"\\n❯ \\n  ⏵⏵ bypass permissions on\\n\"; read -r -n1 -s k; done'" 2>/dev/null; then
    wait_pane "$S" has_prompt || true
    has_prompt "$t" && ok "tmux: prompt visible before overlay" || bad "tmux: no prompt at start"

    # Cover the prompt the way a slash-command overlay does.
    tmux send-keys -t "=$S:^.{top-left}" C-l 2>/dev/null
    tmux run-shell -t "=$S:^.{top-left}" "printf '%s' ''" 2>/dev/null || true
    tmux send-keys -t "=$S:^.{top-left}" "" 2>/dev/null
    tmux clear-history -t "=$S:^.{top-left}" 2>/dev/null || true
    # Paint overlay text over the pane
    tmux respawn-pane -k -t "=$S:^.{top-left}" \
      "bash -c 'printf \"  Context Usage\\n  Auto-compact window: 400k tokens\\n  /context all to expand\\n\"; sleep 30'" 2>/dev/null
    # Ждём сам оверлей, а не «промпта нет»: сразу после respawn панель пуста, а
    # пустая панель тоже без промпта. Под нагрузкой хоста захват успевал раньше
    # отрисовки, и проверка «оверлей распознан» падала на пустоте.
    wait_pane "$S" looks_like_overlay || true
    if has_prompt "$t"; then
      bad "tmux: overlay still shows a prompt — fixture wrong"
    else
      ok "tmux: overlay hides the prompt (reproduces the false-freeze signal)"
      looks_like_overlay "$t" && ok "tmux: captured overlay is recognised" \
                              || bad "tmux: captured overlay not recognised"
    fi

    # Restore a prompt-bearing pane — stands for Escape dismissing the overlay.
    tmux respawn-pane -k -t "=$S:^.{top-left}" \
      "bash -c 'printf \"\\n❯ \\n  ⏵⏵ bypass permissions on\\n\"; sleep 30'" 2>/dev/null
    wait_pane "$S" has_prompt || true
    has_prompt "$t" && ok "tmux: prompt returns once the overlay is dismissed" \
                    || bad "tmux: prompt did not return"
    tmux kill-session -t "=$S" 2>/dev/null || true
  else
    echo "· tmux session could not start — skipping live pane checks"
  fi
else
  echo "· tmux not installed — skipping live pane checks"
fi

# ---- real tmux: ответ на вопрос о каналах доходит до сессии ----------------
# Имитация вопроса ждёт строку ввода и рисует промпт. Текст вопроса при этом
# остаётся на экране над промптом — заодно проверяется, что отвеченный вопрос не
# принимается за живой.
if command -v tmux >/dev/null 2>&1; then
  S="panetest-dev-$$"
  tmux kill-session -t "=$S" 2>/dev/null || true
  if tmux new-session -d -s "$S" -x 80 -y 20 \
       "bash -c 'printf \" ❯ 1. I am using this for local development\\n   2. Exit\\n\"; read -r _; printf \"\\n❯ \\n  ⏵⏵ bypass permissions on\\n\"; sleep 30'" 2>/dev/null; then
    wait_pane "$S" looks_like_dev_channels_prompt || true
    if looks_like_dev_channels_prompt "$t"; then
      ok "tmux: вопрос о каналах распознан на живой панели"
      answer_dev_channels_prompt "$S" "$t" || bad "tmux: ответ на вопрос не отправлен"
      dev_passed() { has_prompt "$1" && ! looks_like_dev_channels_prompt "$1"; }
      wait_pane "$S" dev_passed && ok "tmux: после ответа вопрос ушёл, промпт на месте" \
                               || bad "tmux: вопрос остался после ответа"
    else
      bad "tmux: вопрос о каналах не распознан на живой панели"
    fi
    tmux kill-session -t "=$S" 2>/dev/null || true
  else
    echo "· tmux session could not start — skipping live dev-channels check"
  fi
fi

# ---- real tmux: сосед с более длинным именем не получает клавиш -------------
# РЕГРЕССИЯ 10.09.2026: без точной сессии tmux ищет цель по НАЧАЛУ имени. Сессии
# labops-app не было, и её обращения уходили в labops-app-124546645: watchdog
# «нашёл» свою сессию и не поднял агента. Функции pane.sh бьют только в сессию
# с точным именем.
if command -v tmux >/dev/null 2>&1; then
  S="panetest-nb-$$"
  tmux kill-session -t "=$S-long" 2>/dev/null || true
  # Тот же вопрос, что выше: после Enter он сменится промптом — так видно нажатие.
  nb_tui="bash -c 'printf \" ❯ 1. I am using this for local development\\n   2. Exit\\n\"; "
  nb_tui+="read -r _; printf \"\\n❯ \\n  ⏵⏵ bypass permissions on\\n\"; sleep 30'"
  if tmux new-session -d -s "$S-long" -x 80 -y 20 "$nb_tui" 2>/dev/null; then
    wait_pane "$S-long" looks_like_dev_channels_prompt || true
    if answer_dev_channels_prompt "$S" "$t"; then
      bad "tmux: Enter ушёл в сессию с другим именем ($S-long вместо $S)"
    else
      ok "tmux: несуществующая сессия не подменяется соседом с более длинным именем"
    fi
    sleep 0.5
    t="$(tmux capture-pane -pt "=$S-long:^.{top-left}" -S -8 2>/dev/null)"
    looks_like_dev_channels_prompt "$t" && ok "tmux: панель соседа не тронута" \
                                        || bad "tmux: панель соседа получила Enter"
    [ -z "$(pane_cursor_x "$S")" ] && ok "tmux: курсор соседа не читается под чужим именем" \
                                   || bad "tmux: pane_cursor_x прочитал соседа"
    tmux kill-session -t "=$S-long" 2>/dev/null || true
  else
    echo "· tmux session could not start — skipping neighbour check"
  fi
fi

# ---- real tmux: второе окно оператора не перехватывает клавиши агента -------
# «=имя:» — это ТЕКУЩЕЕ окно сессии. Открой оператор в сессии агента второе окно
# (оно становится текущим), и watchdog читал бы его bash и слал бы туда Enter.
# Функции pane.sh обязаны работать с первым окном и его верхней левой панелью —
# в том числе при base-index и pane-base-index 1, где номера начинаются не с 0.
if command -v tmux >/dev/null 2>&1; then
  S="panetest-win-$$"
  OP_OUT="$TEST_TMP/operator-window.txt"; : > "$OP_OUT"
  win_tui="bash -c 'printf \" ❯ 1. I am using this for local development\\n   2. Exit\\n\"; "
  win_tui+="read -r _; printf \"\\n❯ \\n  ⏵⏵ bypass permissions on\\n\"; sleep 30'"
  if tmux new-session -d -s "$S" -x 80 -y 20 "$win_tui" 2>/dev/null; then
    # Нумерация с единицы: окно агента переезжает на 1, панели считаются с 1.
    # set-option ждёт цель-панель — «=имя» без двоеточия он не находит.
    tmux set-option -t "=$S:" base-index 1 2>/dev/null
    tmux move-window -s "=$S:0" -t "=$S:1" 2>/dev/null
    tmux set-option -w -t "=$S:1" pane-base-index 1 2>/dev/null
    # Окно оператора: всё, что в него придёт, падает в файл.
    tmux new-window -t "=$S:" "bash -c 'cat > \"$OP_OUT\"'" 2>/dev/null
    cur="$(tmux display -p -t "=$S:" '#{window_index}' 2>/dev/null)"
    first="$(tmux display -p -t "=$S:^.{top-left}" '#{window_index}.#{pane_index}' 2>/dev/null)"
    if [ "$cur" = 2 ] && [ "$first" = 1.1 ]; then
      ok "tmux: текущим стало окно оператора, панель агента — 1.1 (условие воспроизведено)"
    else
      bad "tmux: окружение не воспроизведено (текущее окно=$cur, панель агента=$first)"
    fi
    wait_pane "$S" looks_like_dev_channels_prompt || true
    looks_like_dev_channels_prompt "$t" \
      && ok "tmux: читается панель агента, а не текущее окно оператора" \
      || bad "tmux: панель агента не прочитана при втором окне"
    case "$(pane_cursor_x "$S")" in
      ''|*[!0-9]*) bad "tmux: курсор панели агента не читается при втором окне" ;;
      *)           ok "tmux: курсор читается у панели агента" ;;
    esac
    answer_dev_channels_prompt "$S" "$t" || bad "tmux: ответ на вопрос не отправлен"
    win_passed() { has_prompt "$1" && ! looks_like_dev_channels_prompt "$1"; }
    wait_pane "$S" win_passed && ok "tmux: Enter дошёл до панели агента" \
                              || bad "tmux: Enter не дошёл до панели агента"
    sleep 0.3
    [ ! -s "$OP_OUT" ] && ok "tmux: окно оператора не получило ни клавиши" \
                       || bad "tmux: клавиши ушли в окно оператора: $(od -c "$OP_OUT" | head -2)"
    tmux kill-session -t "=$S" 2>/dev/null || true
  else
    echo "· tmux session could not start — skipping second-window check"
  fi
fi

# ---- real tmux: на «2. Exit» стрелка возвращает выбор, claude не выходит ----
# Имитация меню claude: стрелки двигают выбор, Enter на первом пункте ведёт к
# промпту, Enter на «Exit» пишет флаг-файл и завершает «claude».
cat > "$TEST_TMP/dev-menu.sh" <<'TUI'
sel=2
draw() {
  printf '\033[2J\033[H Channels: server:labops-channel\n\n'
  if [ "$sel" = 1 ]; then
    printf ' ❯ 1. I am using this for local development\n   2. Exit\n'
  else
    printf '   1. I am using this for local development\n ❯ 2. Exit\n'
  fi
}
draw
while IFS= read -rsn1 k; do
  if [ "$k" = $'\e' ]; then
    read -rsn2 -t 1 k2 || k2=""
    [ "$k2" = "[A" ] && sel=1
    [ "$k2" = "[B" ] && sel=2
    draw
  elif [ -z "$k" ]; then
    if [ "$sel" = 1 ]; then
      printf '\033[2J\033[H\n❯ \n  ⏵⏵ bypass permissions on\n'; sleep 30; exit 0
    fi
    echo EXITED > "$1"; exit 0
  fi
done
TUI
if command -v tmux >/dev/null 2>&1; then
  S="panetest-up-$$"
  EXIT_FLAG="$TEST_TMP/dev-menu-exited"
  if tmux new-session -d -s "$S" -x 80 -y 20 bash "$TEST_TMP/dev-menu.sh" "$EXIT_FLAG" 2>/dev/null
  then
    exit_selected() {
      looks_like_dev_channels_prompt "$1" && _last_marker_line "$1" | grep -qa '2\. Exit'
    }
    wait_pane "$S" exit_selected && ok "tmux: живое меню стоит на «2. Exit»" \
                                 || bad "tmux: меню не отрисовалось на «2. Exit»"
    answer_dev_channels_prompt "$S" "$t" && ok "tmux: с «2. Exit» ответ дошёл (стрелка, Enter)" \
                                         || bad "tmux: с «2. Exit» ответ не отправлен"
    up_passed() { has_prompt "$1" && ! looks_like_dev_channels_prompt "$1"; }
    wait_pane "$S" up_passed && ok "tmux: после ответа — промпт" \
                             || bad "tmux: вопрос остался после ответа с «2. Exit»"
    [ ! -e "$EXIT_FLAG" ] && ok "tmux: «Exit» не выбран — claude не закрыт" \
                          || bad "tmux: Enter ушёл на «Exit» — claude закрылся бы"
    tmux kill-session -t "=$S" 2>/dev/null || true
  else
    echo "· tmux session could not start — skipping live Up check"
  fi
fi

# ---- real tmux: после ответа ждём, пока вопрос уйдёт (start-agent.sh) ------
# Медленная перерисовка: вопрос держится на экране ещё 1.5с после Enter. Кто
# проверит экран сразу, увидит «неотвеченный» вопрос и ответит второй раз.
if command -v tmux >/dev/null 2>&1; then
  S="panetest-slow-$$"
  slow_tui="bash -c 'printf \" ❯ 1. I am using this for local development\\n   2. Exit\\n\"; "
  slow_tui+="read -r _; sleep 1.5; printf \"\\n❯ \\n  ⏵⏵ bypass permissions on\\n\"; sleep 30'"
  if tmux new-session -d -s "$S" -x 80 -y 20 "$slow_tui" 2>/dev/null; then
    wait_pane "$S" looks_like_dev_channels_prompt || true
    answer_dev_channels_prompt "$S" "$t" || bad "tmux: ответ медленному меню не отправлен"
    now="$(tmux capture-pane -pt "=$S:^.{top-left}" -S -8 2>/dev/null)"
    looks_like_dev_channels_prompt "$now" \
      && ok "tmux: сразу после Enter вопрос ещё на экране (медленная перерисовка)" \
      || bad "tmux: перерисовка не медленная — случай ничего не проверяет"
    dev_channels_prompt_wait_gone "$S" 10 && ok "tmux: ожидание дождалось ухода вопроса" \
                                         || bad "tmux: ожидание не дождалось ухода вопроса"
    tmux kill-session -t "=$S" 2>/dev/null || true
  fi
  S="panetest-stuck-$$"
  stuck_tui="bash -c 'printf \" ❯ 1. I am using this for local development\\n   2. Exit\\n\"; "
  stuck_tui+="sleep 30'"
  if tmux new-session -d -s "$S" -x 80 -y 20 "$stuck_tui" 2>/dev/null; then
    wait_pane "$S" looks_like_dev_channels_prompt || true
    started="$(date +%s)"
    if dev_channels_prompt_wait_gone "$S" 1; then
      bad "tmux: неуходящий вопрос принят за ушедший"
    elif [ $(( $(date +%s) - started )) -le 5 ]; then
      ok "tmux: ожидание ограничено таймаутом (вопрос не ушёл — код 1)"
    else
      bad "tmux: ожидание вышло за таймаут"
    fi
    tmux kill-session -t "=$S" 2>/dev/null || true
  fi
fi

# ---- проводка: вопрос о каналах разработки ---------------------------------
# Вопрос похож и на промпт, и на застрявший ввод, поэтому ветка обязана стоять
# выше обеих — иначе он снова уедет в «здоровый простой».
WD="$HERE/../watchdog.sh"
SA="$HERE/../start-agent.sh"
dev_line="$(grep -n '^  if looks_like_dev_channels_prompt "\$TAIL"; then' "$WD" | head -1 | cut -d: -f1)"
np_line="$(grep -n 'if ! has_prompt "\$TAIL"' "$WD" | head -1 | cut -d: -f1)"
st_line="$(grep -n '# (B) Idle prompt' "$WD" | head -1 | cut -d: -f1)"
if [ -n "$dev_line" ] && [ -n "$np_line" ] && [ -n "$st_line" ] \
   && [ "$dev_line" -lt "$np_line" ] && [ "$dev_line" -lt "$st_line" ]; then
  ok "ветка вопроса о каналах стоит до промпта и ввода (строка $dev_line)"
else
  bad "ветку вопроса о каналах обошли (dev=$dev_line prompt=$np_line stuck=$st_line)"
fi
if grep -q 'report_down "вопрос о каналах разработки' "$WD"; then
  ok "неуходящий вопрос о каналах эскалируется оператору"
else
  bad "неуходящий вопрос о каналах никому не сообщается"
fi
# После лимита ответов — один рестарт на эпизод и только потом оператор. Раньше
# рестарта не было вовсе: сессия стояла на вопросе до прихода человека.
a0_from='/^  if looks_like_dev_channels_prompt "\$TAIL"; then/'
a0_to='/^  DEV_CHANNELS_ANSWERS=0$/'
a0_block="$(awk "$a0_from,$a0_to" "$WD")"
a0_line() { printf '%s\n' "$a0_block" | grep -n "$1" | head -1 | cut -d: -f1; }
a0_restart="$(a0_line 'restart_session "вопрос о каналах')"
a0_report="$(a0_line 'report_down "вопрос о каналах')"
if [ -n "$a0_restart" ] && [ -n "$a0_report" ] && [ "$a0_restart" -lt "$a0_report" ] \
   && printf '%s' "$a0_block" | grep -q 'DEV_CHANNELS_RESTARTED=1' \
   && grep -q 'DEV_CHANNELS_RESTARTED=0' "$WD"; then
  ok "неуходящий вопрос о каналах: один рестарт на эпизод, затем оператор"
else
  bad "ветка A0 без рестарта на эпизод (restart=$a0_restart report=$a0_report)"
fi
if grep -q 'dev_channels_prompt_wait_gone "\$SESSION"' "$SA"; then
  ok "start-agent.sh после ответа ждёт ухода вопроса — второй Enter не уйдёт в чужой экран"
else
  bad "start-agent.sh отвечает без ожидания перерисовки — второй Enter уйдёт в следующий экран"
fi
if grep -q 'lib/pane.sh' "$SA" && grep -q 'answer_dev_channels_prompt' "$SA"; then
  ok "start-agent.sh отвечает тем же детектором из lib/pane.sh"
else
  bad "start-agent.sh отвечает на вопрос своим грепом — детекторы разъедутся"
fi
if grep -qE 'START_READY_TIMEOUT:-([6-9][0-9]|[1-9][0-9]{2,})\}' "$SA"; then
  ok "start-agent.sh ждёт готовности дольше минуты"
else
  bad "start-agent.sh снова ждёт меньше минуты — медленный старт опять повиснет"
fi

# ---- watchdog wiring: ветка мастера должна стоять раньше веток простоя ------
W="$HERE/../watchdog.sh"
# Мастер похож и на промпт, и на застрявший ввод, поэтому распознать его надо
# ДО обеих веток — иначе он снова уедет в «здоровый простой», как 07–09.09.2026.
# Якорь — сама ветка, а не сброс ладдера выше по циклу: с «первым вхождением»
# тест проходил бы и в том случае, если ветку перенесли вниз, под (B).
onb_line="$(grep -n '^  if looks_like_onboarding "\$TAIL"; then' "$W" | head -1 | cut -d: -f1)"
noprompt_line="$(grep -n 'if ! has_prompt "\$TAIL"' "$W" | head -1 | cut -d: -f1)"
stuck_line="$(grep -n '# (B) Idle prompt' "$W" | head -1 | cut -d: -f1)"
if [ -n "$onb_line" ] && [ -n "$noprompt_line" ] && [ "$onb_line" -lt "$noprompt_line" ]; then
  ok "ветка мастера стоит до проверки промпта (строка $onb_line < $noprompt_line)"
else
  bad "ветку мастера обошли: она должна быть до has_prompt"
fi
if [ -n "$onb_line" ] && [ -n "$stuck_line" ] && [ "$onb_line" -lt "$stuck_line" ]; then
  ok "ветка мастера стоит до разбора застрявшего ввода (строка $onb_line < $stuck_line)"
else
  bad "ветку мастера обошли: она должна быть до is_stuck_input"
fi
if grep -q 'report_down "мастер первого запуска' "$W"; then
  ok "мастер, переживший рестарт, эскалируется оператору"
else
  bad "мастер после рестарта никому не сообщается — снова тихая поломка"
fi
if grep -q 'send-keys .*Escape' "$W" && grep -q 'overlay' "$W"; then
  ok "watchdog.sh tries Escape before restarting on a missing prompt"
else
  bad "watchdog.sh restarts on a missing prompt without trying Escape first"
fi
# The Escape attempt is worthless if it happens after the restart call.
esc_line="$(grep -n 'Escape' "$W" | grep -i 'overlay\|prompt' | head -1 | cut -d: -f1)"
res_line="$(grep -n 'restart_session "no prompt rendered' "$W" | head -1 | cut -d: -f1)"
if [ -n "$esc_line" ] && [ -n "$res_line" ] && [ "$esc_line" -lt "$res_line" ]; then
  ok "Escape attempt precedes the restart (line $esc_line < $res_line)"
else
  bad "Escape attempt does not precede the restart (esc=$esc_line restart=$res_line)"
fi

# Reliable stuck-input recovery must be wired into the stuck-input ladder, and
# must run BEFORE the operator-escalation (else a recoverable message escalates
# needlessly).
if grep -q 'source .*lib/pane-recover.sh' "$W" && grep -q 'recover_stuck_input' "$W"; then
  ok "watchdog.sh wires recover_stuck_input (clear + retype)"
else
  bad "watchdog.sh does not use recover_stuck_input — stuck messages only escalate"
fi
rec_line="$(grep -n 'recover_stuck_input "\$SESSION"' "$W" | head -1 | cut -d: -f1)"
esc2_line="$(grep -n 'escalating to operator' "$W" | head -1 | cut -d: -f1)"
if [ -n "$rec_line" ] && [ -n "$esc2_line" ] && [ "$rec_line" -lt "$esc2_line" ]; then
  ok "recovery is attempted before operator escalation (line $rec_line < $esc2_line)"
else
  bad "recovery does not precede escalation (recover=$rec_line escalate=$esc2_line)"
fi

# ---- атрибуция досылки -----------------------------------------------------
# Регрессия 2026-09-01: watchdog отправлял агенту любой нарисованный в поле
# текст, агент его выполнял, и рой уходил в цикл самоуказаний. Досылать можно
# только подтверждённое меткой доставки.
# Каталог внутри TEST_TMP: отдельный trap затёр бы уборку своего tmux-сервера.
MARKER_DIR="$TEST_TMP/marker"; mkdir -p "$MARKER_DIR"
TELEGRAM_STATE_DIR="$MARKER_DIR"
MARKER="$MARKER_DIR/last-inbound"

printf '%s\n%s' "$(date +%s)" 'проверь статус второго мозга' > "$MARKER"
inbound_matches agent 'проверь статус второго мозга' \
  && ok "свежая метка: доставленное сообщение досылается" \
  || bad "свежая метка: доставленное сообщение НЕ распознано"

# Панель отдаёт только первую визуальную строку, возможно обрезанную.
inbound_matches agent 'проверь статус' \
  && ok "обрезанная панелью строка распознаётся как префикс доставленного" \
  || bad "префикс доставленного не распознан"

inbound_matches agent 'подними task-mcp и добавь в .mcp.json' \
  && bad "ЧУЖОЙ текст досылается — цикл самоуказаний возможен" \
  || ok "текст без доставки не досылается"

printf '%s\n%s' "$(( $(date +%s) - 3600 ))" 'проверь статус второго мозга' > "$MARKER"
inbound_matches agent 'проверь статус второго мозга' \
  && bad "протухшая метка принята — старое сообщение может выстрелить позже" \
  || ok "метка старше INBOUND_MARKER_MAX_AGE не принимается"

rm -f "$MARKER"
inbound_matches agent 'проверь статус второго мозга' \
  && bad "без метки досылка разрешена" \
  || ok "без метки досылка запрещена"

printf '%s\n%s' "$(date +%s)" 'ок' > "$MARKER"
inbound_matches agent 'ок' \
  && bad "слишком короткое совпадение принято (случайные совпадения)" \
  || ok "слишком короткий текст не считается подтверждением"

# Гейт на сам watchdog: ветка пустого буфера обязана спрашивать атрибуцию.
W="$HERE/../watchdog.sh"
if grep -q 'inbound_matches "\$AGENT"' "$W"; then
  ok "watchdog.sh проверяет атрибуцию перед перепечаткой"
else
  bad "watchdog.sh перепечатывает нарисованный текст без проверки доставки"
fi
gate_line="$(grep -n 'inbound_matches "\$AGENT"' "$W" | head -1 | cut -d: -f1)"
retype_line="$(grep -n 'сразу перепечатка' "$W" | head -1 | cut -d: -f1)"
if [ -n "$gate_line" ] && [ -n "$retype_line" ] && [ "$gate_line" -lt "$retype_line" ]; then
  ok "проверка атрибуции стоит ДО перепечатки (строка $gate_line < $retype_line)"
else
  bad "перепечатка не защищена проверкой (gate=$gate_line retype=$retype_line)"
fi

echo
echo "passed=$pass failed=$fail"
[ $fail -eq 0 ]
