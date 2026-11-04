#!/usr/bin/env bash
# Unit tests for lib/operator-profile.sh — USER.md второго агента берётся у первого.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

unset USER_MD_SOURCE
# shellcheck disable=SC1091
source "$HERE/operator-profile.sh"

fail() { echo "FAIL: $1"; exit 1; }

LAB="$TMP/lab"
mkdir -p "$LAB/developer/.claude/core" "$LAB/analyst/.claude" "$LAB/shared/.claude"
printf '# USER.md\n\n**Address as:** Сергей\n**Language:** Russian -- talk to me in it\n' \
  > "$LAB/developer/.claude/core/USER.md"

# 1. Источник — первый агент роя с профилем; сам создаваемый не в счёт.
printf 'developer\nanalyst\n' > "$LAB/agents.conf"
[ "$(operator_profile_source "$LAB" analyst)" = "$LAB/developer/.claude/core/USER.md" ] \
  || fail "не нашёл профиль первого агента"
[ -z "$(operator_profile_source "$LAB" developer)" ] \
  || fail "взял профиль у самого создаваемого агента"

# 2. Без agents.conf — по каталогам, служебный shared пропускается.
rm "$LAB/agents.conf"
[ "$(operator_profile_source "$LAB" analyst)" = "$LAB/developer/.claude/core/USER.md" ] \
  || fail "без agents.conf профиль не найден"

# 3. Явный USER_MD_SOURCE важнее роя; несуществующий — пусто, не чужой файл.
printf '**Language:** English\n' > "$TMP/custom.md"
[ "$(USER_MD_SOURCE="$TMP/custom.md" operator_profile_source "$LAB" analyst)" = "$TMP/custom.md" ] \
  || fail "USER_MD_SOURCE проигнорирован"
[ -z "$(USER_MD_SOURCE="$TMP/nope.md" operator_profile_source "$LAB" analyst)" ] \
  || fail "несуществующий USER_MD_SOURCE подменён профилем из роя"

# 4. Язык читается без хвоста «-- talk to me in it».
[ "$(operator_profile_language "$LAB/developer/.claude/core/USER.md")" = "Russian" ] \
  || fail "язык прочитан неверно"
[ "$(operator_profile_language "$TMP/custom.md")" = "English" ] || fail "язык без хвоста не прочитан"
[ -z "$(operator_profile_language "$TMP/nope.md")" ] || fail "язык у несуществующего файла"

# 5. Копия появляется в новом воркспейсе; существующий профиль не перезаписывается.
WS="$LAB/analyst/.claude"
operator_profile_copy "$LAB/developer/.claude/core/USER.md" "$WS" >/dev/null || fail "копия не удалась"
cmp -s "$LAB/developer/.claude/core/USER.md" "$WS/core/USER.md" || fail "копия отличается"
printf 'своё\n' > "$WS/core/USER.md"
operator_profile_copy "$LAB/developer/.claude/core/USER.md" "$WS" >/dev/null || fail "повтор упал"
[ "$(cat "$WS/core/USER.md")" = "своё" ] || fail "существующий профиль перезаписан"
operator_profile_copy "$TMP/nope.md" "$WS" && fail "копия несуществующего источника прошла"

echo "OK: operator-profile.sh — все проверки пройдены"
