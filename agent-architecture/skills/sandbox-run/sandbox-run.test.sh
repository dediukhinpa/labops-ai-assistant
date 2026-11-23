#!/usr/bin/env bash
# sandbox-run.test.sh — раннер песочницы: запуск, коды возврата, таймаут,
# входы/выходы, валидация аргументов, безопасное поведение без изоляции.
#
# Тест детерминирован при любом окружении: если bwrap доступен и работает,
# проверяется реальная изоляция (включая отсутствие сети); если нет — проверки
# идут через явный аварийный режим SANDBOX_ALLOW_UNISOLATED=1, а отказ без
# изоляции проверяется отдельным случаем.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SB="$HERE/sandbox-run.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { echo "✓ $*"; pass=$((pass+1)); }
bad() { echo "✗ $*"; fail=$((fail+1)); }

command -v python3 >/dev/null 2>&1 || { echo "python3 нет — тест пропущен"; exit 0; }

# Достаёт поле из JSON-результата раннера.
jget() { python3 -I -c 'import sys,json; d=json.load(sys.stdin); print(d[sys.argv[1]])' "$1"; }

# Доступен ли bwrap. Если да — гоняем реально через него; если нет — аварийный режим.
if command -v bwrap >/dev/null 2>&1 && bwrap --ro-bind / / --unshare-all --die-with-parent true >/dev/null 2>&1; then
  BWRAP_OK=1; ENVV=()
else
  BWRAP_OK=0; ENVV=(env SANDBOX_ALLOW_UNISOLATED=1)
fi

run() { "${ENVV[@]:-}" bash "$SB" "$@"; }

# 1. python: печать в stdout, нулевой код
cat > "$TMP/s1.py" <<'PY'
print("hi-%d" % 42)
PY
R1="$(run --lang python --code "$TMP/s1.py" 2>/dev/null)" || true
if [ "$(printf '%s' "$R1" | jget exit_code)" = "0" ] \
   && printf '%s' "$R1" | jget stdout | grep -q 'hi-42'; then
  ok "python-скрипт выполнился, stdout пойман, exit_code=0"
else
  bad "python-скрипт/stdout не пойман"; echo "      $R1"
fi

# 2. ненулевой код возврата
printf 'import sys; sys.stderr.write("boom\\n"); sys.exit(3)\n' > "$TMP/s2.py"
R2="$(run --lang python --code "$TMP/s2.py" 2>/dev/null)" || true
if [ "$(printf '%s' "$R2" | jget exit_code)" = "3" ] \
   && printf '%s' "$R2" | jget stderr | grep -q 'boom'; then
  ok "ненулевой код и stderr пойманы"
else
  bad "код возврата/stderr не пойманы"; echo "      $R2"
fi

# 3. таймаут
printf 'import time; time.sleep(10)\n' > "$TMP/s3.py"
R3="$(run --lang python --code "$TMP/s3.py" --timeout 1 2>/dev/null)" || true
if [ "$(printf '%s' "$R3" | jget timed_out)" = "True" ]; then
  ok "долгий скрипт убит по таймауту (timed_out)"
else
  bad "таймаут не сработал"; echo "      $R3"
fi

# 4. сбор выходного файла
printf 'open("out.json","w").write("{\\"ok\\":1}")\n' > "$TMP/s4.py"
R4="$(run --lang python --code "$TMP/s4.py" --output out.json 2>/dev/null)" || true
if printf '%s' "$R4" | python3 -I -c 'import sys,json; d=json.load(sys.stdin); o=d["outputs"][0]; assert o["present"] and "ok" in o["content"]'; then
  ok "выходной файл собран и возвращён"
else
  bad "выходной файл не собран"; echo "      $R4"
fi

# 5. входной файл виден скрипту
printf '[1,2,3]' > "$TMP/in.json"
printf 'import json; print(sum(json.load(open("data.json"))))\n' > "$TMP/s5.py"
R5="$(run --lang python --code "$TMP/s5.py" --input "$TMP/in.json:data.json" 2>/dev/null)" || true
if printf '%s' "$R5" | jget stdout | grep -q '^6$'; then
  ok "входной файл доступен внутри песочницы"
else
  bad "входной файл не прочитан"; echo "      $R5"
fi

# 6. валидация: несуществующий --code → отказ (код 2)
run --lang python --code /nope 2>/dev/null; rc=$?
[ "$rc" = "2" ] && ok "несуществующий --code отвергнут (exit 2)" || bad "валидация --code не сработала (rc=$rc)"

# 7. изоляция/безопасный дефолт
if [ "$BWRAP_OK" = "1" ]; then
  # Реальная изоляция: backend=bwrap, сети нет (socket-подключение падает).
  printf 'print("hi")\n' > "$TMP/s7.py"
  R7="$(bash "$SB" --lang python --code "$TMP/s7.py" 2>/dev/null)" || true
  printf 'import socket,sys\ntry:\n socket.create_connection(("1.1.1.1",53),2); print("NET")\nexcept Exception: print("NONET")\n' > "$TMP/s7n.py"
  R7N="$(bash "$SB" --lang python --code "$TMP/s7n.py" 2>/dev/null)" || true
  if [ "$(printf '%s' "$R7" | jget backend)" = "bwrap" ] \
     && [ "$(printf '%s' "$R7" | jget isolated)" = "True" ] \
     && printf '%s' "$R7N" | jget stdout | grep -q 'NONET'; then
    ok "bwrap: изоляция активна и сеть заблокирована"
  else
    bad "bwrap: изоляция/сеть не как ожидалось"; echo "      $R7 | $R7N"
  fi
else
  # Без bwrap и без разрешения — раннер обязан отказаться (exit 2).
  printf 'print(1)\n' > "$TMP/s7.py"
  SANDBOX_ALLOW_UNISOLATED=0 bash "$SB" --lang python --code "$TMP/s7.py" >/dev/null 2>&1; rc=$?
  [ "$rc" = "2" ] && ok "без изоляции и без разрешения — запуск отклонён (exit 2)" \
                  || bad "небезопасный дефолт: запустил без изоляции (rc=$rc)"
fi

echo "— sandbox-run: $pass ок, $fail провал —"
[ "$fail" -eq 0 ]
