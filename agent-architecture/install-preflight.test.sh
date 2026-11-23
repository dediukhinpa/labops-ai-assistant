#!/usr/bin/env bash
# Поведенческий тест нулевого шага install.sh — предполётной проверки связи.
#
# Запускается НАСТОЯЩИЙ install.sh с подставным curl. Это безопасно ровно
# потому, что проверяемое поведение и есть остановка: при закрытом хосте скрипт
# обязан умереть на шаге 0, до установки пакетов и создания пользователя.
# Положительный путь здесь не гоняется намеренно — install.sh пошёл бы ставить
# агента по-настоящему; классификация ответов покрыта orchestration/lib/preflight.test.sh.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

mkdir -p "$TMP/bin"
make_curl_stub() {   # <код|000>
  cat > "$TMP/bin/curl" <<EOF
#!/usr/bin/env bash
# Подставной curl: отдаёт заданный код, в сеть не ходит.
case "$1" in
  000) printf '000'; exit 6 ;;
  *)   printf '%s' "$1"; exit 0 ;;
esac
EOF
  chmod +x "$TMP/bin/curl"
}

# Вывод пишем в файл, а не через $(...): подстановка команд создаёт подоболочку,
# и выставленный там RC до вызывающего не доходит.
# SKIP_* и закрытый stdin — страховка на случай, когда проверка СЛОМАНА и
# install.sh поедет дальше вопреки закрытому хосту: тогда он не должен ни
# клонировать репозитории, ни заводить пользователя, ни ждать ввода. HOME
# подменён, так что любые следы остаются во временном каталоге.
# env -u: тест обязан мерить КОД установщика, а не шелл оператора. Флаги
# install.sh наследуются из окружения, и PREFLIGHT_DONE=1 (его экспортируют,
# когда обходят закрытый по региону claude.ai) отключал шаг 0 ВНУТРИ теста —
# тот честно докладывал, что установка дошла до пакетов вопреки 403, хотя код
# был цел. Поймано 12.09.2026 у клиента. Поэтому гасим весь набор флагов, а
# нужные для теста задаём тут же, явно.
run_install() {   # <файл-вывода> [ПЕРЕМЕННАЯ=значение...] → код возврата в RC
  local out="$1"; shift
  RC=0
  env -u PREFLIGHT_DONE -u SKIP_SELFTEST -u GITHUB_TOKEN -u TG_PLUGIN_DIR \
      -u INSTALL_TG_LOCAL -u SECOND_BRAIN_DIR -u CLAUDE_LAB -u REUSE_EXISTING \
      -u HARNESS -u LABOPS_HARNESS_DEFAULTED -u NONINTERACTIVE -u AGENT_OS_USER \
      PATH="$TMP/bin:$PATH" HOME="$TMP/home" \
      SKIP_SECOND_BRAIN=1 SKIP_TG_PLUGIN=1 SKIP_USER_SETUP=1 "$@" \
      bash "$REPO/install.sh" >"$out" 2>&1 </dev/null || RC=$?
}

mkdir -p "$TMP/home"

# install.sh гоняем из КОПИИ, а не из рабочего дерева. Если проверка сломана, он
# поедет дальше нулевого шага и дойдёт до `chmod +x orchestration/*.sh` — то есть
# тест начнёт править файлы репозитория (поймано 08.09.2026: два скрипта молча
# стали исполняемыми). Копии нужен только шаг 0, поэтому берём install.sh и
# библиотеки, которые он сорсит.
REPO="$TMP/repo"
mkdir -p "$REPO/orchestration/lib"
cp "$HERE/install.sh" "$REPO/install.sh"
cp "$HERE/orchestration/lib/preflight.sh" "$REPO/orchestration/lib/preflight.sh"
cp "$HERE/orchestration/lib/sudo-compat.sh" "$REPO/orchestration/lib/sudo-compat.sh"
cp "$HERE/orchestration/lib/ui.sh" "$REPO/orchestration/lib/ui.sh"
# plugin.sh даёт clear_foreign_modules — без него install.sh упадёт на сорсе,
# и тест решит, что шаг 0 сломан, хотя сломана как раз копия.
cp "$HERE/orchestration/lib/plugin.sh" "$REPO/orchestration/lib/plugin.sh"
# voice-install.sh даёт voice_install (шаг «Голос»): install.sh сорсит его при старте.
cp "$HERE/orchestration/lib/voice-install.sh" "$REPO/orchestration/lib/voice-install.sh"
# ocr-install.sh даёт ocr_install (шаг «OCR»): install.sh сорсит его при старте.
cp "$HERE/orchestration/lib/ocr-install.sh" "$REPO/orchestration/lib/ocr-install.sh"
# harness.sh, codex-watch.sh, codex-install.sh: харнес роя спрашивается до шага 0, от него
# зависит набор проверяемых хостов (без ввода — claude по умолчанию).
for _lib in harness.sh codex-watch.sh codex-install.sh; do
  cp "$HERE/orchestration/lib/$_lib" "$REPO/orchestration/lib/$_lib"
done

# 1. Закрытый хост (403) — установка обязана остановиться.
make_curl_stub 403
run_install "$TMP/out-403.txt"; OUT="$(cat "$TMP/out-403.txt")"
[ "$RC" -ne 0 ] || fail "при 403 установка не должна продолжаться"

# 2. Остановка именно на шаге 0: до пакетов, пользователя и правки машины.
printf '%s' "$OUT" | grep -q 'Системные пакеты' \
  && fail "установка дошла до системных пакетов вопреки закрытому хосту"

# 3. Причина названа своим именем, а не общим «сеть недоступна». Ради этого
#    403 и отделён от отсутствия связи: чинится он совсем другим действием.
printf '%s' "$OUT" | grep -q '403' \
  || fail "в сообщении нет кода 403 — оператор не поймёт причину"
printf '%s' "$OUT" | grep -q 'закрытый регион' \
  || fail "не названа причина 403 (регион или репутация адреса)"

# 4. Аварийный обход должен быть назван прямо в сообщении, иначе оператор
#    останется без способа продолжить на свой риск.
printf '%s' "$OUT" | grep -q 'PREFLIGHT_DONE=1' \
  || fail "в сообщении не назван способ продолжить вопреки проверке"

# 5. Полное отсутствие связи — ДРУГОЙ текст. Если оба случая дают одно
#    сообщение, разделение классов бессмысленно.
make_curl_stub 000
run_install "$TMP/out-down.txt"; OUT_DOWN="$(cat "$TMP/out-down.txt")"
[ "$RC" -ne 0 ] || fail "без связи установка не должна продолжаться"
printf '%s' "$OUT_DOWN" | grep -qi 'нет соединения' \
  || fail "отсутствие связи не отличается по тексту от блокировки"
printf '%s' "$OUT_DOWN" | grep -q 'закрытый регион' \
  && fail "про регионы сказано там, где дело в сети — оператор пойдёт чинить не то"

# 6. Рой уже на codex, а прогон от root передал под пользователя агентов умолчание claude
#    (LABOPS_HARNESS_DEFAULTED=1, NONINTERACTIVE=1): берётся записанный codex — проверяются
#    хосты Codex, а не api.anthropic.com, и swarm.env не переписывается.
mkdir -p "$TMP/home/.claude-lab/shared"
printf 'HARNESS=codex\n' > "$TMP/home/.claude-lab/shared/swarm.env"
make_curl_stub 403
run_install "$TMP/out-codex.txt" HARNESS=claude LABOPS_HARNESS_DEFAULTED=1 NONINTERACTIVE=1
OUT_CX="$(cat "$TMP/out-codex.txt")"
printf '%s' "$OUT_CX" | grep -q 'chatgpt.com' \
  || fail "умолчание от root подменило записанный харнес codex: хосты Codex не проверялись"
printf '%s' "$OUT_CX" | grep -q 'api.anthropic.com' \
  && fail "рой на codex, а проверяется api.anthropic.com"
grep -qx 'HARNESS=codex' "$TMP/home/.claude-lab/shared/swarm.env" \
  || fail "swarm.env роя на codex переписан"
# Явный выбор оператора (без метки умолчания) по-прежнему главнее.
run_install "$TMP/out-explicit.txt" HARNESS=claude NONINTERACTIVE=1
grep -q 'api.anthropic.com' "$TMP/out-explicit.txt" \
  || fail "явный HARNESS=claude не учтён"
rm -rf "$TMP/home/.claude-lab"

echo "OK: install.sh preflight — 6 проверок пройдено"
