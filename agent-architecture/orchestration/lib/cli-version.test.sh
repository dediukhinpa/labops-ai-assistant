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
# Случай 15 поднимает настоящую сессию — только в своём tmux-сервере, иначе при
# заданной $TMUX она легла бы в сервер роя (см. lib/tmux-test-isolation.sh).
# shellcheck source=lib/tmux-test-isolation.sh
. "$HERE/tmux-test-isolation.sh"
tmux_test_isolate "$TMP"
cleanup() {
  for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done
  tmux_test_kill_server
  rm -rf "$TMP"
}
trap cleanup EXIT

# Две «версии» одного бинаря. Нужен реальный исполняемый файл: /proc/<pid>/exe
# указывает на inode, а не на строку из cmdline, поэтому скриптом не обойтись —
# для скрипта exe вёл бы на интерпретатор, один и тот же у обеих версий.
# Раскладка повторяет нативный установщик: версия — это САМ исполняемый файл,
# названный номером версии, а не каталог с бинарём внутри.
#
# Берём копию bash, а НЕ /bin/sleep. Утилиту coreutils копировать нельзя: там,
# где они собраны ОДНИМ мультивызывным бинарём, программа выбирается по argv[0],
# а наши «версии» названы номерами. Это давно так в coreutils-single (Fedora,
# RHEL), а с переходом Ubuntu на uutils (Rust-реализация, штатная с 25.10) — и
# на Ubuntu: копия под именем «1.0» отвечает «coreutils: unknown program '1'» и
# умирает, не дожив до проверки (поймано 12.09.2026 у клиента на Ubuntu 26.04).
# Живём на чтении из fifo, в которое никто не пишет: процесс блокируется в
# builtin read, не порождая потомков. Через «sleep 300» версия оставляла бы
# после себя осиротевший процесс с унаследованным stdout, а он подвешивает
# любого, кто читает вывод теста каналом. Хвост «; :» обязателен и здесь: для
# ОДНОЙ простой команды bash делает implicit exec, и /proc/<pid>/exe указывал бы
# на подменённый образ вместо нашей копии.
BASH_BIN="$(command -v bash)"
mkdir -p "$TMP/versions" "$TMP/bin"
mkfifo "$TMP/keepalive"
STAY_ALIVE="read -r _ < \"$TMP/keepalive\"; :"
cp "$BASH_BIN" "$TMP/versions/1.0"
cp "$BASH_BIN" "$TMP/versions/2.0"

export CLI_VERSION_CLAUDE_BIN="$TMP/bin/claude"
export CLI_VERSION_PANE_PID_CMD="$TMP/pane-pid.sh"

set_pane_pid() { printf '#!/usr/bin/env bash\necho %s\n' "$1" > "$TMP/pane-pid.sh"; chmod +x "$TMP/pane-pid.sh"; }

# shellcheck disable=SC1091
source "$HERE/cli-version.sh"

fail() { echo "FAIL: $1"; exit 1; }

# Сессия стартовала с версии 1.0 и продолжает её исполнять.
"$TMP/versions/1.0" -c "$STAY_ALIVE" & OLD_PID=$!
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
"$TMP/versions/2.0" -c "$STAY_ALIVE" & NEW_PID=$!
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

# ── Метка пройденного онбординга ─────────────────────────────────────────────
export CLI_VERSION_CONFIG_JSON="$TMP/claude.json"
ln -sfn "$TMP/versions/2.0" "$TMP/bin/claude"
cfg_get() {   # <файл> <ключ>
  python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get(sys.argv[2]))" "$1" "$2"
}

# 9. В существующий конфиг метка дописывается, а чужие ключи остаются на месте.
printf '{"projects": {"/home/agent": {"hasTrustDialogAccepted": true}}}' \
  > "$CLI_VERSION_CONFIG_JSON"
cli_version_mark_onboarding_done
[ "$(cfg_get "$CLI_VERSION_CONFIG_JSON" hasCompletedOnboarding)" = "True" ] \
  || fail "метка онбординга не проставлена"
[ "$(cfg_get "$CLI_VERSION_CONFIG_JSON" lastOnboardingVersion)" = "2.0" ] \
  || fail "записана не та версия"
python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if d['projects']['/home/agent']['hasTrustDialogAccepted'] else 1)
" "$CLI_VERSION_CONFIG_JSON" || fail "засев затёр подтверждённое доверие к каталогу"

# 10. Версия обновилась — метка едет следом, иначе мастер выйдет снова.
ln -sfn "$TMP/versions/1.0" "$TMP/bin/claude"
cli_version_mark_onboarding_done
[ "$(cfg_get "$CLI_VERSION_CONFIG_JSON" lastOnboardingVersion)" = "1.0" ] \
  || fail "метка не поехала за сменой версии"

# 11. Конфига нет — создаётся с нуля (первый запуск агента на чистом хосте).
rm -f "$CLI_VERSION_CONFIG_JSON"
cli_version_mark_onboarding_done
[ "$(cfg_get "$CLI_VERSION_CONFIG_JSON" hasCompletedOnboarding)" = "True" ] \
  || fail "на чистом хосте конфиг не создан"

# 12. Битый конфиг НЕ затирается: его настоящее содержимое знает только CLI, а
# пустышка стоила бы оператору всех подтверждённых доверий.
printf '{сломано' > "$CLI_VERSION_CONFIG_JSON"
cli_version_mark_onboarding_done
[ "$(cat "$CLI_VERSION_CONFIG_JSON")" = '{сломано' ] || fail "битый конфиг затёрт"

# 13. Бинаря нет — версия неизвестна, врать метке нельзя: конфиг не трогаем.
printf '{}' > "$CLI_VERSION_CONFIG_JSON"
CLI_VERSION_CLAUDE_BIN="$TMP/bin/nonexistent-claude" cli_version_mark_onboarding_done
[ "$(cat "$CLI_VERSION_CONFIG_JSON")" = '{}' ] || fail "без бинаря записана выдуманная версия"

# 14. Временный файл за собой не оставляем — конфиг общий на все сессии хоста.
[ ! -e "$CLI_VERSION_CONFIG_JSON.tmp" ] || fail "остался временный файл рядом с конфигом"

# 15. Pid берётся у панели агента — первого окна, а не текущего. Раньше
#     `list-panes -t =имя:` отдавал панели ТЕКУЩЕГО окна: открой оператор в
#     сессии второе окно, и сюда пришёл бы pid его bash — /proc/<pid>/exe не тот
#     бинарь, дрейф «найден», агент на простое ушёл бы в рестарт.
if command -v tmux >/dev/null 2>&1; then
  unset CLI_VERSION_PANE_PID_CMD
  ln -sfn "$TMP/versions/2.0" "$TMP/bin/claude"
  S="cliver-$$"
  # Команда отдельными аргументами — tmux исполнит её сам, без обёртки-оболочки,
  # и pane_pid окажется ровно процессом «версии».
  if tmux new-session -d -s "$S" "$TMP/versions/2.0" -c "$STAY_ALIVE" 2>/dev/null; then
    tmux new-window -t "=$S:" bash -c 'sleep 300'
    agent_pid="$(tmux display -p -t "=$S:^.{top-left}" '#{pane_pid}')"
    op_pid="$(tmux display -p -t "=$S:" '#{pane_pid}')"
    [ -n "$agent_pid" ] && [ "$agent_pid" != "$op_pid" ] \
      || fail "окружение не воспроизведено: второе окно не стало текущим"
    [ "$(_cli_version_pane_pid "$S")" = "$agent_pid" ] \
      || fail "pid взят не у панели агента, а у текущего окна оператора"
    cli_version_drifted "$S" && fail "второе окно оператора принято за дрейф версии"
    # Сосед с более длинным именем не подменяет несуществующую сессию.
    [ -z "$(_cli_version_pane_pid "${S%?}")" ] || fail "pid прочитан у сессии с другим именем"
    tmux kill-session -t "=$S" 2>/dev/null || true
  else
    echo "· tmux-сессия не поднялась — случай 15 пропущен"
  fi
fi

echo "OK: cli-version.sh — 15 проверок пройдено"
