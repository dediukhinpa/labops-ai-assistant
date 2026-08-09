#!/usr/bin/env bash
# task-poller-launch.sh — единый запуск и надзор межагентного task-поллера.
#
# Источается двумя местами:
#   • start-agent.sh — первый запуск при старте сессии;
#   • watchdog.sh    — надзор: поднять поллер, если сессия жива, а его процесс
#                      исчез (прибит systemd при рестарте юнита, убит сигналом,
#                      упал). Без надзора «тихо умерший» поллер лежал бы мёртвым
#                      до следующего полного рестарта сессии.
#
# Идемпотентно: если поллер для ЭТОГО воркспейса уже бежит — не дублируем.
# Библиотека, ничего не запускает при сорсинге и не логирует сама — решение о
# логировании принимает вызывающая сторона по возвращённому статусу.

# Точный подсчёт живых поллеров ИМЕННО для данного воркспейса. `pgrep -f <путь>`
# нельзя — он матчит и наш собственный процесс (путь попадает в его cmdline).
# Поэтому идём по /proc: берём процессы с comm=bash и сверяем, что путь скрипта
# присутствует отдельным аргументом в их \0-разделённом cmdline.
_poller_count() {
  local poller="$1" n=0 pid
  for pid in $(pgrep -x bash 2>/dev/null || true); do
    # 2>/dev/null ПЕРЕД input-редиректом: процесс мог исчезнуть между pgrep и
    # чтением /proc — глушим ошибку открытия отсутствующего cmdline.
    if tr '\0' '\n' 2>/dev/null < "/proc/$pid/cmdline" | grep -Fxq "$poller"; then
      n=$((n + 1))
    fi
  done
  printf '%s' "$n"
}

# Запустить поллер, если для воркспейса он ещё не бежит.
# Печатает один из статусов и всегда возвращает 0:
#   noscript — скрипта нет (агент без поллера, нечего запускать);
#   running  — поллер уже бежит, повторно не запускаем;
#   launched — поллер только что поднят.
ensure_task_poller() {
  local agent="$1" workspace="$2"
  local poller="$workspace/scripts/task-poller.sh"
  if [ ! -f "$poller" ]; then
    printf '%s' "noscript"; return 0
  fi
  if [ "$(_poller_count "$poller")" -gt 0 ]; then
    printf '%s' "running"; return 0
  fi
  mkdir -p "$workspace/logs" 2>/dev/null || true
  AGENT_ID="$agent" AGENT_WORKSPACE="$workspace" \
    TASK_POLL_INTERVAL="${TASK_POLL_INTERVAL:-5}" \
    setsid bash "$poller" </dev/null >>"$workspace/logs/task-poller.log" 2>&1 &
  printf '%s' "launched"; return 0
}
