#!/usr/bin/env bash
# task-poller.test.sh -- тест ОБЁРТКИ поллера. Сам цикл опроса живёт в
# task_poller.py и покрыт task_poller.test.py (30 проверок), который тут же и
# запускается последним случаем -- чтобы одна команда проверяла оба слоя.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { echo "✓ $*"; pass=$((pass+1)); }
bad() { echo "✗ $*"; fail=$((fail+1)); }

WRAPPER="$HERE/task-poller.sh"
DAEMON="$HERE/task_poller.py"

# ---- case 1: обе половины на месте и целы ------------------------------------
[ -f "$DAEMON" ] && ok "демон task_poller.py лежит рядом с обёрткой" \
  || bad "нет $DAEMON -- обёртке нечего запускать"
bash -n "$WRAPPER" 2>/dev/null && ok "обёртка синтаксически цела" \
  || bad "bash -n на обёртке провален"
python3 -m py_compile "$DAEMON" 2>/dev/null && ok "демон компилируется" \
  || bad "py_compile на демоне провален"

# ---- case 2: обёртка не уходит в exec ----------------------------------------
# Надзор (orchestration/lib/task-poller-launch.sh) считает живые поллеры по
# процессам с comm=bash и путём этого скрипта отдельным аргументом. `exec
# python3` подменил бы процесс -- поллер стал бы невидим, и watchdog поднимал бы
# второй поверх живого каждые 30 секунд.
if grep -vE '^[[:space:]]*#' "$WRAPPER" | grep -qE '^[[:space:]]*exec[[:space:]]'; then
  bad "обёртка уходит в exec -- надзор перестанет её видеть"
else
  ok "обёртка остаётся живым bash-процессом (нет exec)"
fi

# ---- case 3: тестовый хук сорсит, но не крутит цикл --------------------------
out="$(AGENT_WORKSPACE="$TMP/ws" AGENT_ID=carmella TASK_POLLER_LIB=1 \
  timeout 5 bash -c ". '$WRAPPER'; echo SOURCED" 2>&1)"
case "$out" in
  *SOURCED*) ok "TASK_POLLER_LIB=1 -- сорсится и не уходит в бесконечный цикл" ;;
  *)         bad "хук TASK_POLLER_LIB сломан: $out" ;;
esac

# ---- case 4: нет демона -- тихий выход с причиной в журнале ------------------
mkdir -p "$TMP/lonely"
cp "$WRAPPER" "$TMP/lonely/task-poller.sh"
AGENT_WORKSPACE="$TMP/ws2" AGENT_ID=carmella \
  timeout 10 bash "$TMP/lonely/task-poller.sh" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && ok "без демона обёртка выходит кодом 0, а не падает" \
  || bad "без демона обёртка вернула $rc"
grep -q 'task_poller.py' "$TMP/ws2/logs/task-poller.log" 2>/dev/null \
  && ok "причина выхода записана в журнал" || bad "в журнале нет причины выхода"

# ---- case 5: headless claude по-прежнему под запретом ------------------------
# Опрос обязан оставаться на подписке, а не жечь SDK-кредиты.
if grep -vE '^[[:space:]]*#' "$WRAPPER" "$DAEMON" | grep -qE 'claude +-p|claude +--print'; then
  bad "поллер тащит headless claude -- запрещено"
else
  ok "поллер не тащит headless claude"
fi

# ---- case 6: логика опроса зелёная -------------------------------------------
if python3 "$HERE/task_poller.test.py" >"$TMP/py.log" 2>&1; then
  ok "task_poller.test.py зелёный"
else
  bad "task_poller.test.py провален:"; tail -20 "$TMP/py.log"
fi

echo
echo "passed=$pass failed=$fail"
[ $fail -eq 0 ]
