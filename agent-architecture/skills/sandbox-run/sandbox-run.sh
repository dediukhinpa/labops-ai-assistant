#!/usr/bin/env bash
# sandbox-run.sh — изолированный запуск скрипта агента (прототип).
#
# Назначение: агент пишет скрипт (python/node/bash), раннер гоняет его в
# изоляции на этом сервере и возвращает структурированный результат (JSON в
# stdout). Нейтральная возможность обработки данных: фильтрация, парсинг,
# дедуп, агрегации, конвертация форматов и т.п. Песочница ИСПОЛНЯЕТ код, но не
# меняет того, что допустимо писать: недопустимую по сути задачу обёртка в
# песочницу допустимой не делает.
#
# Изоляция: при наличии bwrap (bubblewrap) — приватные namespace, корень
# read-only, отдельный /tmp, запись только в рабочую папку, СЕТИ НЕТ
# (--unshare-all). Без bwrap раннер по умолчанию отказывается запускать код
# неизолированно; явный аварийный режим — SANDBOX_ALLOW_UNISOLATED=1 (тогда
# только timeout + ulimit, без namespace и без блокировки сети), он помечается
# в результате isolated=false.
#
# Использование:
#   sandbox-run.sh --lang python|node|bash --code <файл-скрипта> \
#     [--timeout СЕК] [--mem-mb МБ] \
#     [--input ХОСТ_ПУТЬ[:ИМЯ]]... [--output ИМЯ]... [--network none]
#
# Результат (stdout, JSON): exit_code, stdout, stderr (усечены), outputs[],
# duration_ms, isolated, backend, network. Полный контракт — в SKILL.md.
set -euo pipefail

# --- значения по умолчанию и пределы ------------------------------------------
LANG_IN=""
CODE=""
TIMEOUT=60
TIMEOUT_MAX=300
MEM_MB=1024
MEM_MB_MAX=4096
NETWORK="none"
declare -a INPUTS=()
declare -a OUTPUTS=()
CAP_BYTES=65536   # сколько байт stdout/stderr/вывода отдавать модели

die() { printf 'sandbox-run: ОШИБКА: %s\n' "$*" >&2; exit 2; }
is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }

# --- разбор аргументов ---------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --lang)    LANG_IN="${2:-}"; shift 2 ;;
    --code)    CODE="${2:-}"; shift 2 ;;
    --timeout) TIMEOUT="${2:-}"; shift 2 ;;
    --mem-mb)  MEM_MB="${2:-}"; shift 2 ;;
    --network) NETWORK="${2:-}"; shift 2 ;;
    --input)   INPUTS+=("${2:-}"); shift 2 ;;
    --output)  OUTPUTS+=("${2:-}"); shift 2 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "неизвестный аргумент: $1" ;;
  esac
done

[ -n "$LANG_IN" ] || die "нужен --lang (python|node|bash)"
[ -n "$CODE" ] || die "нужен --code <файл-скрипта>"
[ -f "$CODE" ] || die "файл скрипта не найден: $CODE"
is_uint "$TIMEOUT" || die "--timeout должен быть целым"
is_uint "$MEM_MB" || die "--mem-mb должен быть целым"
[ "$TIMEOUT" -ge 1 ] && [ "$TIMEOUT" -le "$TIMEOUT_MAX" ] || die "--timeout вне 1..$TIMEOUT_MAX"
[ "$MEM_MB" -ge 32 ] && [ "$MEM_MB" -le "$MEM_MB_MAX" ] || die "--mem-mb вне 32..$MEM_MB_MAX"

case "$LANG_IN" in
  python) INTERP=(python3); EXT=py ;;
  node)   INTERP=(node);    EXT=js ;;
  bash)   INTERP=(bash);    EXT=sh ;;
  *) die "--lang должен быть python|node|bash" ;;
esac
command -v "${INTERP[0]}" >/dev/null 2>&1 || die "интерпретатор не найден: ${INTERP[0]}"

case "$NETWORK" in
  none) ;;
  allowlist) die "--network allowlist в прототипе не поддержан (нужен прокси с белым списком); используйте none" ;;
  *) die "--network должен быть none (или allowlist — не в прототипе)" ;;
esac

# --- рабочая папка -------------------------------------------------------------
WORK="$(mktemp -d "${TMPDIR:-/tmp}/sandbox-run.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

cp "$CODE" "$WORK/script.$EXT"

# Входы: копия в рабочую папку под указанным именем (по умолчанию — basename).
for spec in "${INPUTS[@]:-}"; do
  [ -n "$spec" ] || continue
  host="${spec%%:*}"
  name="${spec#*:}"; [ "$name" = "$spec" ] && name="$(basename "$host")"
  [ -e "$host" ] || die "вход не найден: $host"
  case "$name" in */*|..*|"") die "недопустимое имя входа: $name" ;; esac
  cp -a "$host" "$WORK/$name"
done

# --- выбор бэкенда изоляции ----------------------------------------------------
BACKEND="none"
ISOLATED=0
if command -v bwrap >/dev/null 2>&1 && \
   bwrap --ro-bind / / --unshare-all --die-with-parent true >/dev/null 2>&1; then
  BACKEND="bwrap"; ISOLATED=1
fi

if [ "$ISOLATED" -eq 0 ] && [ "${SANDBOX_ALLOW_UNISOLATED:-0}" != "1" ]; then
  die "нет рабочего бэкенда изоляции (bwrap недоступен или заблокирован). \
Поставьте bubblewrap (apt-get install -y bubblewrap) и проверьте профиль AppArmor для userns, \
либо запустите с SANDBOX_ALLOW_UNISOLATED=1 ПОД СВОЮ ОТВЕТСТВЕННОСТЬ (без namespace и без блокировки сети)."
fi

STDOUT="$WORK/.stdout"; STDERR="$WORK/.stderr"
START_MS=$(( $(date +%s%N) / 1000000 ))
RC=0

run_bwrap() {
  # ulimit применяется к bwrap и всему дереву: адресное пространство (память),
  # размер файла, CPU-время (страховка к wall-clock timeout). Жёсткий лимит
  # числа процессов — через pids-cgroup, это следующий шаг после прототипа.
  #
  # Рабочую папку монтируем ПОД tmpfs /tmp: корень --ro-bind'ом read-only, и
  # точку монтирования на верхнем уровне (/work) bwrap там создать не может
  # («Read-only file system»); /tmp — tmpfs, туда mkdir проходит. Комментарии
  # НЕ ставить между строками, склеенными «\» — иначе хвост команды уходит в
  # комментарий (так ломался запуск: timeout без команды).
  ( ulimit -v $(( MEM_MB * 1024 )) 2>/dev/null || true
    ulimit -f 262144 2>/dev/null || true
    ulimit -t $(( TIMEOUT + 5 )) 2>/dev/null || true
    exec timeout --kill-after=5 "$TIMEOUT" \
      bwrap \
        --ro-bind / / \
        --dev /dev --proc /proc --tmpfs /tmp \
        --bind "$WORK" /tmp/work --chdir /tmp/work \
        --unshare-all --die-with-parent --new-session \
        --clearenv \
        --setenv PATH "/usr/local/bin:/usr/bin:/bin" \
        --setenv HOME /tmp/work \
        --setenv LANG C.UTF-8 --setenv LC_ALL C.UTF-8 \
        -- "${INTERP[@]}" "/tmp/work/script.$EXT"
  )
}

run_plain() {
  # Аварийный режим без namespace: только timeout + ulimit, env вычищен.
  ( cd "$WORK"
    ulimit -v $(( MEM_MB * 1024 )) 2>/dev/null || true
    ulimit -f 262144 2>/dev/null || true
    ulimit -t $(( TIMEOUT + 5 )) 2>/dev/null || true
    exec timeout --kill-after=5 "$TIMEOUT" \
      env -i PATH="/usr/local/bin:/usr/bin:/bin" HOME="$WORK" \
        LANG=C.UTF-8 LC_ALL=C.UTF-8 \
        "${INTERP[@]}" "$WORK/script.$EXT"
  )
}

if [ "$BACKEND" = "bwrap" ]; then
  run_bwrap >"$STDOUT" 2>"$STDERR" || RC=$?
else
  run_plain >"$STDOUT" 2>"$STDERR" || RC=$?
fi
END_MS=$(( $(date +%s%N) / 1000000 ))

# timeout возвращает 124 (и 137 при --kill-after) — это таймаут, а не код скрипта.
TIMED_OUT=false
{ [ "$RC" -eq 124 ] || [ "$RC" -eq 137 ]; } && TIMED_OUT=true

# --- сбор результата в JSON (через python3 — безопасное экранирование) --------
# Список запрошенных выходных файлов передаём построчно в окружении.
OUT_LIST=""
for o in "${OUTPUTS[@]:-}"; do [ -n "$o" ] && OUT_LIST+="$o"$'\n'; done

SB_WORK="$WORK" SB_RC="$RC" SB_START="$START_MS" SB_END="$END_MS" \
SB_TIMED_OUT="$TIMED_OUT" SB_BACKEND="$BACKEND" SB_ISOLATED="$ISOLATED" \
SB_NETWORK="$NETWORK" SB_CAP="$CAP_BYTES" SB_OUTPUTS="$OUT_LIST" \
python3 -I - <<'PY'
import json, os

work = os.environ["SB_WORK"]
cap = int(os.environ["SB_CAP"])

def read_capped(path):
    try:
        with open(path, "rb") as f:
            data = f.read(cap + 1)
    except FileNotFoundError:
        return "", 0, False
    size = os.path.getsize(path)
    truncated = len(data) > cap
    text = data[:cap].decode("utf-8", "replace")
    return text, size, truncated

out_text, _, out_trunc = read_capped(os.path.join(work, ".stdout"))
err_text, _, err_trunc = read_capped(os.path.join(work, ".stderr"))

outputs = []
for name in os.environ.get("SB_OUTPUTS", "").splitlines():
    name = name.strip()
    if not name:
        continue
    p = os.path.join(work, name)
    if not os.path.isfile(p):
        outputs.append({"name": name, "present": False})
        continue
    content, size, trunc = read_capped(p)
    outputs.append({"name": name, "present": True, "size": size,
                    "truncated": trunc, "content": content})

result = {
    "exit_code": int(os.environ["SB_RC"]),
    "timed_out": os.environ["SB_TIMED_OUT"] == "true",
    "duration_ms": int(os.environ["SB_END"]) - int(os.environ["SB_START"]),
    "backend": os.environ["SB_BACKEND"],
    "isolated": os.environ["SB_ISOLATED"] == "1",
    "network": os.environ["SB_NETWORK"],
    "stdout": out_text,
    "stdout_truncated": out_trunc,
    "stderr": err_text,
    "stderr_truncated": err_trunc,
    "outputs": outputs,
}
print(json.dumps(result, ensure_ascii=False))
PY
