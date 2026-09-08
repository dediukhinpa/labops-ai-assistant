#!/usr/bin/env bash
# Unit tests for lib/cli-version.sh — обнаружение устаревшего бинаря сессии.
#
# Без моков /proc: тест поднимает НАСТОЯЩИЕ процессы из двух файлов версий и
# двигает симлинк между ними. Проверяется ровно то поведение ядра, на котором
# стоит вся затея, — запущенный процесс держит свой исходный inode.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done; rm -rf "$TMP"; }
trap cleanup EXIT

# Две «версии» одного бинаря. Нужен реальный исполняемый файл: /proc/<pid>/exe
# указывает на inode, а не на строку из cmdline, поэтому скриптом не обойтись —
# для скрипта exe вёл бы на интерпретатор, один и тот же у обеих версий.
# Раскладка повторяет нативный установщик: версия — это САМ исполняемый файл,
# названный номером версии, а не каталог с бинарём внутри.
mkdir -p "$TMP/versions" "$TMP/bin"
cp /bin/sleep "$TMP/versions/1.0"
cp /bin/sleep "$TMP/versions/2.0"

export CLI_VERSION_CLAUDE_BIN="$TMP/bin/claude"
export CLI_VERSION_PANE_PID_CMD="$TMP/pane-pid.sh"

set_pane_pid() { printf '#!/usr/bin/env bash\necho %s\n' "$1" > "$TMP/pane-pid.sh"; chmod +x "$TMP/pane-pid.sh"; }

# shellcheck disable=SC1091
source "$HERE/cli-version.sh"

fail() { echo "FAIL: $1"; exit 1; }

# Сессия стартовала с версии 1.0 и продолжает её исполнять.
"$TMP/versions/1.0" 300 & OLD_PID=$!
PIDS+=("$OLD_PID")
set_pane_pid "$OLD_PID"

# 1. Симлинк указывает туда же, откуда стартовали — дрейфа нет.
ln -sfn "$TMP/versions/1.0" "$TMP/bin/claude"
cli_version_drifted demo && fail "дрейф найден там, где версии совпадают"

# 2. Обновление приехало: симлинк уехал на 2.0, процесс остался на 1.0.
ln -sfn "$TMP/versions/2.0" "$TMP/bin/claude"
cli_version_drifted demo || fail "дрейф не найден после подмены симлинка"

# 3. Метка версии для лога берётся из имени файла версии.
[ "$(cli_version_label "$(cli_version_running_exe demo)")" = "1.0" ] \
  || fail "метка запущенной версии неверна: $(cli_version_label "$(cli_version_running_exe demo)")"
[ "$(cli_version_label "$(cli_version_installed_exe)")" = "2.0" ] \
  || fail "метка установленной версии неверна: $(cli_version_label "$(cli_version_installed_exe)")"

# 4. Перезапустились на новой версии — дрейф закрылся.
"$TMP/versions/2.0" 300 & NEW_PID=$!
PIDS+=("$NEW_PID")
set_pane_pid "$NEW_PID"
cli_version_drifted demo && fail "дрейф остался после перезапуска на актуальной версии"

# 5. FAIL-OPEN: процесса нет — молчим, а не рестартуем вслепую.
kill "$OLD_PID" 2>/dev/null || true
wait "$OLD_PID" 2>/dev/null
set_pane_pid "$OLD_PID"
cli_version_drifted demo && fail "мёртвый процесс принят за дрейф (должен быть fail-open)"

# 6. FAIL-OPEN: pane_pid не отдался вовсе (сессии нет).
set_pane_pid ""
cli_version_drifted demo && fail "пустой pane_pid принят за дрейф"

# 7. FAIL-OPEN: claude не найден — сравнивать не с чем.
set_pane_pid "$NEW_PID"
CLI_VERSION_CLAUDE_BIN="$TMP/bin/nonexistent-claude"
cli_version_drifted demo && fail "отсутствующий бинарь принят за дрейф"
CLI_VERSION_CLAUDE_BIN="$TMP/bin/claude"

# 8. Метка неизвестного пути не роняет вызывающего.
[ "$(cli_version_label '')" = "неизвестна" ] || fail "пустой путь должен давать «неизвестна»"

echo "OK: cli-version.sh — 8 проверок пройдено"
