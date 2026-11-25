#!/usr/bin/env bash
# Юнит-тесты switch-harness.sh: разбор аргументов, dry-run и контракт безопасности
# недостроенной команды (бэкап есть, swarm.env не трогается до реализации всех шагов).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SWITCH="$HERE/switch-harness.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
check() {
  local name="$1"; shift
  if "$@"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $name" >&2; fi
}
eq() { [ "$1" = "$2" ] || { echo "  ожидалось '$2', получено '$1'" >&2; return 1; }; }

# Лаборатория на claude с двумя агентами.
fresh_lab() {
  local lab="$TMP/lab-$1"
  mkdir -p "$lab/shared" "$lab/developer/.claude/core" "$lab/vanessa/.claude/core"
  printf 'HARNESS=%s\n' "${2:-claude}" > "$lab/shared/swarm.env"
  printf '%s' "$lab"
}
run() { CLAUDE_LAB="$1" bash "$SWITCH" "${@:2}" >/dev/null 2>&1; }

# 1. Неизвестный аргумент — отказ.
lab="$(fresh_lab 1)"
run "$lab" gemini; check "неизвестный харнес -> rc 1" eq "$?" "1"

# 2. Без харнеса — отказ.
run "$lab"; check "без харнеса -> rc 1" eq "$?" "1"

# 3. Целевой = текущий — no-op, rc 0, swarm.env не тронут.
run "$lab" claude; check "claude→claude no-op -> rc 0" eq "$?" "0"

# 4. dry-run ничего не меняет, rc 0.
lab="$(fresh_lab 4)"
CLAUDE_LAB="$lab" bash "$SWITCH" codex --dry-run >/dev/null 2>&1
check "dry-run -> rc 0" eq "$?" "0"
check "dry-run не создал бэкап" eq "$(ls "$lab/shared/backups" 2>/dev/null | wc -l)" "0"
check "dry-run не тронул swarm.env" eq "$(sed -n 's/^HARNESS=//p' "$lab/shared/swarm.env")" "claude"

# 5. Реальный запуск недостроенной команды: бэкап есть, но swarm.env НЕ переключён
#    (останавливается на первом нереализованном шаге до необратимых действий).
lab="$(fresh_lab 5)"
CLAUDE_LAB="$lab" bash "$SWITCH" codex >/dev/null 2>&1
check "недостроенная команда -> rc 1 (safe stop)" eq "$?" "1"
check "бэкап создан" eq "$([ -d "$lab/shared/backups" ] && echo y)" "y"
check "swarm.env всё ещё claude (не полупереключён)" \
  eq "$(sed -n 's/^HARNESS=//p' "$lab/shared/swarm.env")" "claude"
check "в бэкапе есть архивы агентов" \
  eq "$(find "$lab/shared/backups" -name 'developer.tgz' | wc -l)" "1"

# 6. Пустая лаборатория — отказ (переключать нечего).
empty="$TMP/empty"; mkdir -p "$empty/shared"; printf 'HARNESS=claude\n' > "$empty/shared/swarm.env"
run "$empty" codex; check "пустой рой -> rc 1" eq "$?" "1"

echo "switch-harness.test.sh: $PASS ok, $FAIL fail"
[ "$FAIL" -eq 0 ]
