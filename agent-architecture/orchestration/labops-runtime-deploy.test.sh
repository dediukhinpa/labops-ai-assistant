#!/usr/bin/env bash
# Unit tests for labops-runtime-deploy.sh — копия роя из checkout, записанного root.
# Гоняется не от root: настройки, каталог копии и юниты подменены через env.
# Главное: в копию попадает только закоммиченное плюс node_modules, прежняя
# копия заменяется целиком, источник берётся из настроек, а не от вызывающего.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ARCH="$(cd "$HERE/.." && pwd)"
HELPER="$HERE/labops-runtime-deploy.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

ME="$(id -un)"
SRC="$TMP/src"
mkdir -p "$SRC/tg-plugin/plugin/node_modules/dep" "$TMP/units" "$TMP/lab/dev/.claude"
# Настоящий agent-architecture: копия должна уметь обновить скиллы своим sync-skills.sh.
tar -C "$ARCH/.." -cf - --exclude=node_modules --exclude=.git agent-architecture \
  | tar -x -C "$SRC"
echo '{}' > "$SRC/tg-plugin/plugin/package.json"
echo mod > "$SRC/tg-plugin/plugin/node_modules/dep/index.js"
printf 'node_modules/\nsecret.env\n' > "$SRC/.gitignore"
git -C "$SRC" init -q
git -C "$SRC" -c user.email=t@t -c user.name=t add -A
git -C "$SRC" -c user.email=t@t -c user.name=t commit -qm init
echo "TOKEN=1" > "$SRC/secret.env"
echo draft >> "$SRC/agent-architecture/README.md"
COMMIT="$(git -C "$SRC" rev-parse HEAD)"

CONF="$TMP/runtime.conf"
printf 'SOURCE=%s\nOWNER=%s\nLAB=%s\n' "$SRC" "$ME" "$TMP/lab" > "$CONF"
TARGET="$TMP/opt/labops/ai-assistant"

run() {  # run <args...> — код в RC, вывод в $TMP/out
  RC=0
  LABOPS_RUNTIME_CONF="$CONF" LABOPS_RUNTIME_DIR="$TARGET" LABOPS_UNIT_DIR="$TMP/units" \
    bash "$HELPER" "$@" >"$TMP/out" 2>&1 </dev/null || RC=$?
}

# 1. Вхолостую — ничего не создаёт.
run --dry-run
[ "$RC" -eq 0 ] || fail "dry-run упал: $(cat "$TMP/out")"
[ ! -e "$TARGET" ] || fail "dry-run создал копию"
grep -q 'незакоммиченные правки' "$TMP/out" || fail "не предупредил о правках в checkout"

# 2. Копия: закоммиченное + node_modules, без секретов и черновиков.
printf '[Service]\nUser=%s\nExecStart=%s/agent-architecture/orchestration/watchdog.sh dev\n' \
  "$ME" "$SRC" > "$TMP/units/claude-agent-dev.service"
printf '[Service]\nUser=%s\nExecStart=%s/agent-architecture/orchestration/watchdog.sh ok\n' \
  "$ME" "$TARGET" > "$TMP/units/claude-agent-ok.service"
run
[ "$RC" -eq 0 ] || fail "деплой упал: $(cat "$TMP/out")"
[ -x "$TARGET/agent-architecture/orchestration/watchdog.sh" ] || fail "нет watchdog.sh в копии"
[ -f "$TARGET/tg-plugin/plugin/node_modules/dep/index.js" ] || fail "нет node_modules в копии"
[ "$(cat "$TARGET/COMMIT")" = "$COMMIT" ] || fail "COMMIT не тот"
[ ! -e "$TARGET/secret.env" ] || fail "в копию попал незакоммиченный секрет"
grep -q draft "$TARGET/agent-architecture/README.md" && fail "в копию попала незакоммиченная правка"
[ ! -e "$TARGET/.git" ] || fail "в копию попал .git"
find "$TARGET" -perm -o+w | grep -q . && fail "в копии есть файлы с записью для всех"

# 3. Скиллы лаборатории обновлены из копии, метка указывает на копию.
[ -f "$TMP/lab/shared/skills/create-agent/SKILL.md" ] || fail "скиллы не синхронизированы"
[ "$(cat "$TMP/lab/shared/skills/.labops-repo")" = "$TARGET/agent-architecture" ] \
  || fail "метка скиллов не на копию: $(cat "$TMP/lab/shared/skills/.labops-repo")"
[ "$(readlink "$TMP/lab/dev/.claude/skills")" = "$TMP/lab/shared/skills" ] \
  || fail "skills/ агента не переведён на общую копию"

# 4. Юнит из checkout назван с командой перевода, юнит из копии — нет.
grep -q '  dev: ' "$TMP/out" || fail "юнит из checkout не назван: $(cat "$TMP/out")"
grep -q "labops-agent-unit dev $TARGET/agent-architecture/orchestration $TMP/lab" "$TMP/out" \
  || fail "нет команды перевода юнита"
grep -q '  ok: ' "$TMP/out" && fail "юнит из копии назван устаревшим"

# 5. Повторный деплой заменяет копию целиком: лишний файл пропадает, временных нет.
echo stray > "$TARGET/stray"
run
[ "$RC" -eq 0 ] || fail "повторный деплой упал: $(cat "$TMP/out")"
[ ! -e "$TARGET/stray" ] || fail "прежняя копия не заменена"
ls -A "$(dirname "$TARGET")" | grep -qE '\.(new|old)-' && fail "остались временные каталоги"

# 6. Аргументы и настройки проверяются.
run --source /tmp
[ "$RC" -ne 0 ] || fail "принят --source"
cp "$CONF" "$CONF.bak"
printf 'SOURCE=%s\nOWNER=root\n' "$SRC" > "$CONF"
run; [ "$RC" -ne 0 ] || fail "принят OWNER=root"
printf 'SOURCE=%s/../src\nOWNER=%s\n' "$TMP" "$ME" > "$CONF"
run; [ "$RC" -ne 0 ] || fail "принят SOURCE с .."
printf 'SOURCE=relative\nOWNER=%s\n' "$ME" > "$CONF"
run; [ "$RC" -ne 0 ] || fail "принят относительный SOURCE"
cp "$CONF.bak" "$CONF"
rm -rf "$SRC/tg-plugin/plugin/node_modules"
run
[ "$RC" -ne 0 ] || fail "без node_modules: принято"
grep -q 'bun install' "$TMP/out" || fail "без node_modules: не подсказано bun install"
[ -f "$TARGET/COMMIT" ] || fail "неудачный деплой задел прежнюю копию"
rm -f "$CONF"
run
[ "$RC" -ne 0 ] && grep -q 'install.sh' "$TMP/out" || fail "без настроек: нет внятного отказа"

echo "labops-runtime-deploy: ok"
