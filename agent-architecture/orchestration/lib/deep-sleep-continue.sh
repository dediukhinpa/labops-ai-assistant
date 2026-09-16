#!/usr/bin/env bash
# Продолжение сессии Claude Code после глубокого сна (PR 7 плана тарифов
# labops-web-app: gateway/src/agent-sleep.ts).
#
# ПОЧЕМУ ТАК. Глубокий сон останавливает юнит агента целиком (память хоста
# освобождается), а дрёма — только замораживает процессы (сессия жива). После
# остановки изнутри юнита не отличить «меня усыпили» от «я упал и вотчдог меня
# поднял» — оба раза это холодный старт того же tmux-сервера. Root-воркер
# labops-web-app (deploy/provision_queue.py: write_deep_sleep_marker) перед
# остановкой юнита оставляет клиенту метку в его собственном доме — она
# переживает остановку, потому что лежит не в процессе, а на диске. Эта
# библиотека только читает и потребляет метку; кладёт её другой репозиторий.
#
# Путь метки — .claude/state/deep-sleep-continue от $HOME агента — держать в
# синхроне с DEEP_SLEEP_MARKER_REL в labops-web-app/deploy/provision_queue.py:
# общий контракт между двумя репозиториями, без разделяемого кода.
#
# Библиотека: при сорсинге ничего не делает.

# shellcheck shell=bash

DEEP_SLEEP_MARKER="${DEEP_SLEEP_MARKER:-$HOME/.claude/state/deep-sleep-continue}"

# deep_sleep_continue_flag [файл-метки] — печатает «--continue» и забирает
# метку (mv, чтобы обычный краш-рестарт вотчдога следующим разом не продолжил
# старую сессию по ошибке), если метка есть; иначе не печатает ничего и
# возвращает 1. Не проверяет, что у claude правда есть что продолжать —
# --continue сама решает это при старте; здесь только различаем «усыплён» от
# «упал».
deep_sleep_continue_flag() {
  local marker="${1:-$DEEP_SLEEP_MARKER}" taken
  [ -f "$marker" ] || return 1
  taken="$marker.taken.$$"
  mv "$marker" "$taken" 2>/dev/null || return 1
  rm -f "$taken" 2>/dev/null || true
  printf -- '--continue'
}
