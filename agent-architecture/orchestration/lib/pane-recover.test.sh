#!/usr/bin/env bash
# pane-recover.test.sh — интеграционный тест перепечатки застрявшего ввода.
#
# Живой tmux нужен по существу: recover_stuck_input работает клавишами и
# курсором, а не строками, и все прошлые баги были именно в этом стыке.
# Сервер свой (lib/tmux-test-isolation.sh): одного TMUX_TMPDIR было мало — при
# заданной $TMUX (а в панелях агентов она задана всегда) tmux шёл в сервер роя, и
# `kill-server` из уборки снёс бы всех агентов разом. Роль TUI играет
# `bash -c 'printf "❯ "; cat > файл'`: панель выглядит как поле ввода, а всё
# отправленное Enter'ом падает в файл — то есть тест проверяет не «что
# нарисовано», а что РЕАЛЬНО ушло агенту.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
# shellcheck source=lib/tmux-test-isolation.sh
. "$HERE/tmux-test-isolation.sh"
tmux_test_isolate "$TMP"
SESSION_BASE="pane-recover-test-$$"
SESSION="$SESSION_BASE-0"
OUT="$TMP/submitted-0.txt"
export TELEGRAM_STATE_DIR="$TMP/state"; mkdir -p "$TELEGRAM_STATE_DIR"
MARKER="$TELEGRAM_STATE_DIR/last-inbound"

cleanup() {
  tmux_test_kill_server   # только свой сервер — сокет задан явно
  rm -rf "$TMP"
}
trap cleanup EXIT

pass=0; fail=0
ok()  { echo "✓ $*"; pass=$((pass+1)); }
bad() { echo "✗ $*"; fail=$((fail+1)); }

if ! command -v tmux >/dev/null 2>&1; then
  echo "tmux недоступен — тест пропущен"; exit 0
fi

RECOVER_SETTLE=0.05
RECOVER_SUBMIT_DELAY=0.4
export RECOVER_SETTLE RECOVER_SUBMIT_DELAY
# shellcheck source=lib/pane-recover.sh
. "$HERE/pane-recover.sh"

# Каждый случай — своя сессия и свой файл: убивать последнюю сессию нельзя,
# вместе с ней уходит сервер, и следующий new-session попадает в умирающий
# («server exited unexpectedly» — поймано на прогоне). Всё чистит cleanup.
CASE=0
start_pane() {   # <текст-в-поле>
  CASE=$((CASE+1))
  SESSION="$SESSION_BASE-$CASE"
  OUT="$TMP/submitted-$CASE.txt"
  : > "$OUT"
  tmux new-session -d -s "$SESSION" -x 80 -y 20 \
    "bash -c 'printf \"❯ \"; cat > \"$OUT\"'"
  sleep 0.4
  [ -n "${1:-}" ] && tmux send-keys -t "=$SESSION:^.{top-left}" -l "$1"
  sleep 0.3
}

write_marker() { printf '%s\n%s' "$(date +%s)" "$1" > "$MARKER"; }

LONG='проверь пожалуйста статус второго мозга, потом посмотри логи поллера задач за последний час и скажи одним предложением, есть ли там ошибки доставки межагентских задач, и если есть — процитируй последнюю'
FIRST_LINE='проверь пожалуйста статус второго мозга, потом посмотри логи поллера'

# 1. Метка есть → перепечатывается ПОЛНЫЙ текст, а не обрезок из панели.
write_marker "$LONG"
start_pane "$FIRST_LINE"
rc=0; recover_stuck_input "$SESSION" developer || rc=$?
sleep 0.3
got="$(head -1 "$OUT" 2>/dev/null || true)"
[ "$rc" -eq 0 ] && ok "восстановление по метке: rc=0" || bad "rc=$rc"
[ "$got" = "$LONG" ] && ok "ушёл полный текст (${#got} симв.)" \
  || bad "текст не совпал: отправлено ${#got} симв. вместо ${#LONG}"
[ "${RECOVER_SOURCE}" = "marker" ] && ok "источник — метка" || bad "источник ${RECOVER_SOURCE}"
[ "${RECOVER_TRUNCATED}" -eq 0 ] && ok "флаг потери снят" || bad "флаг потери выставлен зря"

# 2. Метки нет → откат на панель, потеря честно помечена флагом.
rm -f "$MARKER"
start_pane "$LONG"
rc=0; recover_stuck_input "$SESSION" developer || rc=$?
sleep 0.3
got="$(head -1 "$OUT" 2>/dev/null || true)"
[ "$rc" -eq 0 ] && ok "без метки: rc=0" || bad "без метки rc=$rc"
[ -n "$got" ] && [ "$got" != "$LONG" ] && ok "без метки текст обрезан (${#got} симв.) — как и было" \
  || bad "ожидалась обрезка панели, получено ${#got} симв."
[ "${RECOVER_SOURCE}" = "pane" ] && ok "источник — панель" || bad "источник ${RECOVER_SOURCE}"
[ "${RECOVER_TRUNCATED}" -eq 1 ] && ok "потеря помечена флагом" || bad "потеря не помечена"

# 3. Многострочная метка → склеивается в одну строку и уходит ЦЕЛИКОМ:
#    литеральный перевод строки в поле ввода = отправка, иначе ушло бы кусками.
MULTI=$'первая строка задания\nвторая строка с деталями\nтретья строка и финальное слово ХВОСТ'
write_marker "$MULTI"
start_pane 'первая строка задания'
rc=0; recover_stuck_input "$SESSION" developer || rc=$?
sleep 0.3
lines="$(wc -l < "$OUT" 2>/dev/null || echo 0)"
got="$(head -1 "$OUT" 2>/dev/null || true)"
[ "$lines" -eq 1 ] && ok "многострочное ушло одним сообщением" || bad "ушло строк: $lines"
case "$got" in *ХВОСТ*) ok "хвост многострочного сообщения не потерян" ;;
              *) bad "хвост потерян: $got" ;; esac
case "$got" in *"первая строка задания вторая строка"*) ok "переносы склеены пробелом" ;;
              *) bad "склейка сломана: $got" ;; esac

# 4. Пустое поле — восстанавливать нечего.
start_pane ""
rc=0; recover_stuck_input "$SESSION" developer || rc=$?
[ "$rc" -eq 2 ] && ok "чистый промпт — rc=2, ничего не отправлено" || bad "чистый промпт rc=$rc"

# 5. Без имени агента метка не читается (обратная совместимость вызова).
write_marker "$LONG"
start_pane "$FIRST_LINE"
rc=0; recover_stuck_input "$SESSION" || rc=$?
sleep 0.3
[ "${RECOVER_SOURCE}" = "pane" ] && ok "без агента метка не используется" || bad "метка прочитана без агента"

# 6. Спецсимволы доезжают дословно: перепечатка идёт литерально (send-keys -l),
#    а сравнение с меткой — через case-шаблон с кавычками, поэтому ни $VAR, ни
#    backtick, ни glob не должны ни раскрываться, ни ломать сопоставление.
SPECIAL='посмотри $HOME/logs/*.log | grep "ошибка" && echo `date` — 100% срочно, ага?'
write_marker "$SPECIAL"
start_pane 'посмотри $HOME/logs'
rc=0; recover_stuck_input "$SESSION" developer || rc=$?
sleep 0.3
got="$(head -1 "$OUT" 2>/dev/null || true)"
[ "$got" = "$SPECIAL" ] && ok "спецсимволы дошли дословно" || bad "спецсимволы искажены: $got"
[ "${RECOVER_SOURCE}" = "marker" ] && ok "спецсимволы не сорвали сопоставление с меткой" \
  || bad "сопоставление с меткой сорвалось на спецсимволах"

# 7. Unicode и эмодзи в ДОСТАВЛЕННОМ тексте доезжают без искажений.
#    Эмодзи специально нет в нарисованной строке: в поддельном TUI (обычный
#    `cat` в каноническом режиме) Ctrl-U стирает по числу символов, а терминал
#    считает колонки, и двухколоночный символ оставляет хвост — артефакт
#    харнесса, а не системы: у настоящего TUI своя отрисовка поля, а в реальном
#    сценарии призрака буфер и вовсе пуст и чистить нечего.
UNI='срочно проверь очередь — там «кавычки-ёлочки», тире и эмодзи 🙂 ⚡ в конце'
write_marker "$UNI"
start_pane 'срочно проверь очередь'
rc=0; recover_stuck_input "$SESSION" developer || rc=$?
sleep 0.3
got="$(head -1 "$OUT" 2>/dev/null || true)"
[ "$got" = "$UNI" ] && ok "unicode и эмодзи не искажены" || bad "unicode искажён: $got"

echo
echo "passed=$pass failed=$fail"
[ $fail -eq 0 ]
