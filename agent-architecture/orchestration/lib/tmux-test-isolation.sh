#!/usr/bin/env bash
# tmux-test-isolation.sh — свой tmux-сервер для тестов, которые заводят НАСТОЯЩИЕ
# сессии. Тест сорсит файл и зовёт tmux_test_isolate до первого вызова tmux.
#
# ПОЧЕМУ. Живые агенты работают в одном общем tmux-сервере. Сервер tmux выбирает
# так: -S/-L в командной строке, иначе сокет из $TMUX, и только потом
# $TMUX_TMPDIR/tmux-<uid>/default. В панелях агентов $TMUX задана всегда, а
# test.sh агенты гоняют как раз из своих сессий. Без этой обвязки такой тест
# заводил бы сессии прямо в сервере роя, а `tmux kill-server` из его уборки снёс
# бы весь рой. Одного TMUX_TMPDIR мало — $TMUX его перекрывает (проверено на
# tmux 3.4 с сервером-приманкой: при заданной $TMUX тест попадал в приманку).
#
# tmux_test_isolate <каталог> — снять $TMUX/$TMUX_PANE и направить tmux в свой
#   сервер внутри <каталог>. TMUX_TMPDIR экспортируется: скрипты, которые тест
#   запускает подпроцессами, попадут в тот же сервер.
# tmux_test_kill_server — погасить ТОЛЬКО свой сервер. Сокет указан явно (-S),
#   поэтому даже заново выставленная $TMUX не уведёт команду в чужой сервер.

tmux_test_isolate() {
  local dir="${1:?tmux_test_isolate: нужен каталог}"
  # unset без local внутри функции снимает переменные у всего теста — это и нужно.
  unset TMUX TMUX_PANE
  export TMUX_TMPDIR="$dir/tmux"
  mkdir -p "$TMUX_TMPDIR"
  TMUX_TEST_SOCKET="$TMUX_TMPDIR/tmux-$(id -u)/default"
}

tmux_test_kill_server() {
  [ -n "${TMUX_TEST_SOCKET:-}" ] || return 0
  # command — мимо мок-функций tmux, которые тесты определяют у себя.
  command tmux -S "$TMUX_TEST_SOCKET" kill-server 2>/dev/null || true
}
