#!/usr/bin/env bash
# Юнит-тесты lib/harness.sh: чтение и запись харнеса роя в shared/swarm.env.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# shellcheck source=lib/harness.sh
. "$HERE/harness.sh"

PASS=0; FAIL=0
check() {
  local name="$1"; shift
  if "$@"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $name" >&2; fi
}
fresh_lab() {
  export CLAUDE_LAB="$TMP/lab-$1"
  mkdir -p "$CLAUDE_LAB"
}
eq() { [ "$1" = "$2" ] || { echo "  ожидалось '$2', получено '$1'" >&2; return 1; }; }

# 1. Нет swarm.env — прежний рой, claude.
fresh_lab 1
check "нет swarm.env -> claude" eq "$(harness_current)" "claude"

# 2. Значение из файла, с кавычками и пробелом в конце.
fresh_lab 2
mkdir -p "$CLAUDE_LAB/shared"
printf 'FOO=1\nHARNESS="codex" \n' > "$CLAUDE_LAB/shared/swarm.env"
check "кавычки и пробел срезаются" eq "$(harness_current)" "codex"

# 3. Мусор в файле — ошибка, а не тихий claude.
fresh_lab 3
mkdir -p "$CLAUDE_LAB/shared"
printf 'HARNESS=gemini\n' > "$CLAUDE_LAB/shared/swarm.env"
harness_current >/dev/null 2>&1; rc=$?
check "неизвестный харнес -> код 1 (rc)" eq "$rc" "1"

# 4. Файл не исполняется: подстановка команды в значении остаётся строкой.
fresh_lab 4
mkdir -p "$CLAUDE_LAB/shared"
# shellcheck disable=SC2016
printf 'HARNESS=$(touch %s/pwned)\n' "$TMP" > "$CLAUDE_LAB/shared/swarm.env"
harness_current >/dev/null 2>&1
check "swarm.env не исполняется" test ! -e "$TMP/pwned"

# 5. Запись в пустую лабораторию: файл 600, значение читается, прочие строки целы.
fresh_lab 5
mkdir -p "$CLAUDE_LAB/shared"
printf 'OTHER=keep\nHARNESS=claude\n' > "$CLAUDE_LAB/shared/swarm.env"
harness_set_swarm codex >/dev/null
check "запись codex" eq "$(harness_current)" "codex"
check "прочие строки сохранены" grep -qx 'OTHER=keep' "$CLAUDE_LAB/shared/swarm.env"
check "HARNESS ровно один" eq "$(grep -c '^HARNESS=' "$CLAUDE_LAB/shared/swarm.env")" "1"
check "права 600" eq "$(stat -c %a "$CLAUDE_LAB/shared/swarm.env")" "600"

# 6. Повторная запись того же харнеса при живых агентах — без ошибки.
fresh_lab 6
mkdir -p "$CLAUDE_LAB/dev/.codex"
# Первая запись при уже существующем агенте .codex: харнес по умолчанию claude, а
# агенты есть — отказ. Так и должно быть: рой без swarm.env считается claude.
check "без swarm.env и с агентом смена на codex — отказ" \
  bash -c ". '$HERE/harness.sh'; CLAUDE_LAB='$CLAUDE_LAB' harness_set_swarm codex >/dev/null 2>&1; [ \$? -ne 0 ]"
mkdir -p "$CLAUDE_LAB/shared"; printf 'HARNESS=codex\n' > "$CLAUDE_LAB/shared/swarm.env"
check "тот же харнес при агентах — ок" harness_set_swarm codex

# 7. Смена харнеса при существующих агентах — отказ, файл не меняется.
fresh_lab 7
mkdir -p "$CLAUDE_LAB/dev/.claude" "$CLAUDE_LAB/shared"
printf 'HARNESS=claude\n' > "$CLAUDE_LAB/shared/swarm.env"
harness_set_swarm codex >/dev/null 2>&1; rc=$?
check "смена при агентах — код 1" eq "$rc" "1"
check "смена при агентах — файл прежний" eq "$(harness_current)" "claude"

# 8. Каталог shared не считается агентом.
fresh_lab 8
mkdir -p "$CLAUDE_LAB/shared/.claude"
check "shared — не агент" bash -c ". '$HERE/harness.sh'; CLAUDE_LAB='$CLAUDE_LAB' harness_swarm_has_agents; [ \$? -ne 0 ]"

# 9. Неизвестный харнес не записывается.
fresh_lab 9
harness_set_swarm gemini >/dev/null 2>&1; rc=$?
check "запись неизвестного — код 1" eq "$rc" "1"
check "запись неизвестного — файла нет" test ! -e "$CLAUDE_LAB/shared/swarm.env"

# 10. Модели по умолчанию и бинари.
check "модель claude" eq "$(harness_default_model claude)" "sonnet"
check "модель codex" eq "$(harness_default_model codex)" "gpt-6.2-sol"
check "бинарь codex" eq "$(harness_bin codex)" "codex"
harness_default_model gemini >/dev/null 2>&1; rc=$?
check "модель неизвестного — код 1" eq "$rc" "1"

# 11. Установщик от root: харнес из лаборатории пользователя агентов (у root swarm.env нет).
U="$TMP/users"
mkdir -p "$U/agents/.claude-lab/shared" "$U/other" "$U/second/.claude-lab/shared"
printf 'HARNESS=codex\n' > "$U/agents/.claude-lab/shared/swarm.env"
cat > "$TMP/passwd" <<EOF2
root:x:0:0:root:/root:/bin/bash
daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin
agents:x:1001:1001::$U/agents:/bin/bash
other:x:1002:1002::$U/other:/bin/bash
EOF2
export HARNESS_PASSWD_FILE="$TMP/passwd"
check "root: харнес из лаборатории пользователя агентов" \
  eq "$(harness_read_swarm_agent_users)" "codex"
check "root: AGENT_OS_USER без лаборатории — пусто" \
  eq "$(AGENT_OS_USER=other harness_read_swarm_agent_users)" ""
check "root: AGENT_OS_USER с лабораторией" \
  eq "$(AGENT_OS_USER=agents harness_read_swarm_agent_users)" "codex"
printf 'second:x:1003:1003::%s/second:/bin/bash\n' "$U" >> "$TMP/passwd"
printf 'HARNESS=claude\n' > "$U/second/.claude-lab/shared/swarm.env"
harness_read_swarm_agent_users >/dev/null; rc=$?
check "root: у пользователей разные харнесы — код 2, без догадок" eq "$rc" "2"
check "root: AGENT_OS_USER снимает неоднозначность" \
  eq "$(AGENT_OS_USER=second harness_read_swarm_agent_users)" "claude"
printf 'HARNESS=codex\n' > "$U/second/.claude-lab/shared/swarm.env"
check "root: одинаковый харнес у нескольких — он и есть" \
  eq "$(harness_read_swarm_agent_users)" "codex"
unset HARNESS_PASSWD_FILE

echo "harness.test.sh: $PASS ok, $FAIL fail"
[ "$FAIL" -eq 0 ]
