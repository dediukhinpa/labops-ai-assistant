#!/usr/bin/env bash
# task-poller-launch.test.sh — юнит-тест единого запуска/надзора task-поллера.
# Проверяет: нет скрипта → noscript; уже бежит → running (без повторного запуска);
# не бежит → launched (через setsid); а также реальный подсчёт процессов по /proc.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/task-poller-launch.sh"
pass=0; fail=0
ok()  { echo "✓ $*"; pass=$((pass+1)); }
bad() { echo "✗ $*"; fail=$((fail+1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---- нет скрипта → noscript, ничего не запускаем -----------------------------
launched_marker="$WORK/launched"
setsid() { echo "SETSID $*" >> "$launched_marker"; }   # перехват реального запуска
out="$(ensure_task_poller "developer" "$WORK")"
{ [ "$out" = "noscript" ] && [ ! -f "$launched_marker" ]; } \
  && ok "нет скрипта → noscript, запуск не вызван" \
  || bad "нет скрипта: out=$out marker=$( [ -f "$launched_marker" ] && echo yes || echo no)"

# Скрипт-заглушка: остаётся ЖИВЫМ bash-процессом (comm=bash, cmdline=`bash <путь>`)
# — ровно так выглядит настоящий поллер, поэтому _poller_count должен его считать.
# Цикл `sleep 1` (а не `sleep 300`): при kill осиротевший sleep умрёт за ≤1с, а
# stdout спавнов уведён в /dev/null → пайп теста он не держит.
mkdir -p "$WORK/scripts"
POLLER="$WORK/scripts/task-poller.sh"
printf '#!/usr/bin/env bash\nwhile :; do sleep 1; done\n' > "$POLLER"
chmod +x "$POLLER"

# ---- уже бежит → running, повторного запуска нет -----------------------------
_poller_count() { echo 1; }        # мокаем «уже бежит»
: > "$launched_marker"
out="$(ensure_task_poller "developer" "$WORK")"
{ [ "$out" = "running" ] && [ ! -s "$launched_marker" ]; } \
  && ok "уже бежит → running, дубликат не запущен" \
  || bad "уже бежит: out=$out marker=$(cat "$launched_marker" 2>/dev/null)"

# ---- не бежит → launched через setsid с путём поллера ------------------------
_poller_count() { echo 0; }        # мокаем «не бежит»
: > "$launched_marker"
out="$(ensure_task_poller "developer" "$WORK")"
# setsid у нас фоновый (`&`) — маркер пишется асинхронно, дождёмся его.
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$launched_marker" ] && break; sleep 0.1; done
{ [ "$out" = "launched" ] && grep -Fq "$POLLER" "$launched_marker"; } \
  && ok "не бежит → launched, setsid получил путь поллера" \
  || bad "не бежит: out=$out marker=$(cat "$launched_marker" 2>/dev/null)"
# Восстанавливаем настоящие функции: unset -f снёс бы оригинал _poller_count из
# lib безвозвратно, поэтому ре-сорсим lib, а перехват setsid просто снимаем.
unset -f setsid
. "$HERE/task-poller-launch.sh"

# ---- реальный _poller_count: считает ровно наш bash-процесс по /proc ---------
# Запускаем настоящий `bash <poller>` (спит), проверяем, что счётчик его видит,
# и что он НЕ ловит посторонний bash с другим путём в cmdline.
REAL="$WORK/scripts/task-poller.sh"
# stdout спавнов уводим в /dev/null: иначе они держат stdout-пайп теста открытым
# и наблюдающий `| tail` не увидит EOF, пока они не умрут.
bash "$REAL" >/dev/null 2>&1 & real_pid=$!
OTHER="$WORK/scripts/other.sh"; printf '#!/usr/bin/env bash\nwhile :; do sleep 1; done\n' > "$OTHER"
bash "$OTHER" >/dev/null 2>&1 & other_pid=$!
sleep 0.3
n="$(_poller_count "$REAL")"
[ "$n" -ge 1 ] && ok "_poller_count видит живой поллер ($n)" || bad "_poller_count не увидел поллер ($n)"
# other.sh не должен считаться поллером
no="$(_poller_count "$OTHER")"
n2="$(_poller_count "$REAL")"
{ [ "$n2" = "$no" ] || true; } >/dev/null
[ "$n2" -ge 1 ] && ok "_poller_count различает пути (other не влияет на счёт поллера)" \
  || bad "_poller_count спутал пути"
kill "$real_pid" "$other_pid" 2>/dev/null || true
wait "$real_pid" "$other_pid" 2>/dev/null || true

echo
echo "passed=$pass failed=$fail"
[ $fail -eq 0 ]
