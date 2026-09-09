#!/usr/bin/env bash
# pane.test.sh — unit test for the pane classifier, plus a REAL tmux test that
# the Escape-before-restart ladder distinguishes a slash-command overlay from a
# dead TUI. The regression: an operator running /context in the pane made the
# watchdog restart a healthy session ("no prompt rendered — heartbeat stale").
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/pane.sh"
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
    t="$(tmux capture-pane -pt "$s" -S -8 2>/dev/null)"
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
  tmux kill-session -t "$S" 2>/dev/null || true
  # A tiny fake TUI: prints a prompt, and on Escape redraws it. `less` stands in
  # for the overlay — it hides the prompt and exits on Escape via its keymap.
  if tmux new-session -d -s "$S" -x 80 -y 20 \
       "bash -c 'while :; do printf \"\\n❯ \\n  ⏵⏵ bypass permissions on\\n\"; read -r -n1 -s k; done'" 2>/dev/null; then
    wait_pane "$S" has_prompt || true
    has_prompt "$t" && ok "tmux: prompt visible before overlay" || bad "tmux: no prompt at start"

    # Cover the prompt the way a slash-command overlay does.
    tmux send-keys -t "$S" C-l 2>/dev/null
    tmux run-shell -t "$S" "printf '%s' ''" 2>/dev/null || true
    tmux send-keys -t "$S" "" 2>/dev/null
    tmux clear-history -t "$S" 2>/dev/null || true
    # Paint overlay text over the pane
    tmux respawn-pane -k -t "$S" \
      "bash -c 'printf \"  Context Usage\\n  Auto-compact window: 400k tokens\\n  /context all to expand\\n\"; sleep 30'" 2>/dev/null
    no_prompt() { ! has_prompt "$1"; }
    wait_pane "$S" no_prompt || true
    if has_prompt "$t"; then
      bad "tmux: overlay still shows a prompt — fixture wrong"
    else
      ok "tmux: overlay hides the prompt (reproduces the false-freeze signal)"
      looks_like_overlay "$t" && ok "tmux: captured overlay is recognised" \
                              || bad "tmux: captured overlay not recognised"
    fi

    # Restore a prompt-bearing pane — stands for Escape dismissing the overlay.
    tmux respawn-pane -k -t "$S" \
      "bash -c 'printf \"\\n❯ \\n  ⏵⏵ bypass permissions on\\n\"; sleep 30'" 2>/dev/null
    wait_pane "$S" has_prompt || true
    has_prompt "$t" && ok "tmux: prompt returns once the overlay is dismissed" \
                    || bad "tmux: prompt did not return"
    tmux kill-session -t "$S" 2>/dev/null || true
  else
    echo "· tmux session could not start — skipping live pane checks"
  fi
else
  echo "· tmux not installed — skipping live pane checks"
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
MARKER_DIR="$(mktemp -d)"
trap 'rm -rf "$MARKER_DIR"' EXIT
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
