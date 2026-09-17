#!/usr/bin/env bash
# Unit tests for lib/skills.sh — общие скиллы копируются, агенты ссылаются на копию.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=skills.sh
. "$HERE/skills.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

SRC="$TMP/repo/skills"; LAB="$TMP/lab"; SH="$LAB/shared/skills"
mkdir -p "$SRC/alpha/scripts" "$SRC/alpha/tests" "$SRC/beta" "$SRC/not-a-skill"
echo a > "$SRC/alpha/SKILL.md"; echo run > "$SRC/alpha/scripts/run.sh"
echo t > "$SRC/alpha/alpha.test.sh"; echo t > "$SRC/alpha/tests/x.py"
echo b > "$SRC/beta/SKILL.md"; echo readme > "$SRC/README.md"

# 1. Копия, а не ссылка; тесты и не-скиллы не копируются.
sync_shared_skills "$SRC" "$LAB" >/dev/null
[ -d "$SH/alpha" ] && [ ! -L "$SH/alpha" ] || fail "alpha не скопирован каталогом"
[ -f "$SH/alpha/scripts/run.sh" ] || fail "вложенные файлы не скопированы"
[ ! -e "$SH/alpha/alpha.test.sh" ] && [ ! -e "$SH/alpha/tests" ] || fail "тесты скопированы"
[ ! -e "$SH/not-a-skill" ] || fail "каталог без SKILL.md скопирован"
[ -f "$SH/README.md" ] || fail "README не скопирован"
[ "$(cat "$SH/.labops-repo")" = "$TMP/repo" ] || fail "метка репозитория: $(cat "$SH/.labops-repo")"

# 2. Удаление репозитория не трогает копию.
mv "$TMP/repo" "$TMP/repo-moved"
[ "$(cat "$SH/alpha/SKILL.md")" = a ] || fail "копия зависит от репозитория"
mv "$TMP/repo-moved" "$TMP/repo"

# 3. Обновление: правка доезжает, снятый скилл уходит, чужой остаётся.
mkdir -p "$SH/operator-own"; echo own > "$SH/operator-own/SKILL.md"
echo a2 > "$SRC/alpha/SKILL.md"; rm -rf "$SRC/beta"
out="$(sync_shared_skills "$SRC" "$LAB")"
[ "$(cat "$SH/alpha/SKILL.md")" = a2 ] || fail "обновление не доехало"
[ ! -e "$SH/beta" ] || fail "снятый скилл остался"
echo "$out" | grep -q 'убран снятый скилл: beta' || fail "удаление не показано: $out"
[ -f "$SH/operator-own/SKILL.md" ] || fail "скилл оператора удалён"
ls -A "$SH" | grep -q '\.new\.\|\.old\.' && fail "остались временные каталоги"

# 4. Воркспейс: пусто → ссылка; ссылка на репо → на общую; повтор — без изменений.
WS="$LAB/dev/.claude"; mkdir -p "$WS"
link_workspace_skills "$WS" "$LAB" >/dev/null
[ "$(readlink "$WS/skills")" = "$SH" ] || fail "ссылка не создана"
ln -sfn "$SRC" "$WS/skills"
out="$(link_workspace_skills "$WS" "$LAB")"
[ "$(readlink "$WS/skills")" = "$SH" ] || fail "ссылка на репозиторий не переведена"
echo "$out" | grep -q 'было' || fail "перевод ссылки не показан"
[ -z "$(link_workspace_skills "$WS" "$LAB")" ] || fail "повтор что-то менял"
[ -f "$WS/skills/alpha/SKILL.md" ] || fail "скилл не виден через ссылку"
ls -A "$WS" | grep -q '\.skills\.link' && fail "остался временный симлинк"

# 5. Собственный каталог агента не трогается.
WS2="$LAB/own/.claude"; mkdir -p "$WS2/skills/mine"
rc=0; link_workspace_skills "$WS2" "$LAB" 2>/dev/null || rc=$?
[ "$rc" -eq 2 ] && [ -d "$WS2/skills/mine" ] && [ ! -L "$WS2/skills" ] || fail "свой каталог задет"

# 6. Скилл-ссылка в общей папке от старого install.sh (create-agent → репо)
#    заменяется копией.
rm -rf "$SH/alpha"; ln -s "$SRC/alpha" "$SH/alpha"
sync_shared_skills "$SRC" "$LAB" >/dev/null
[ -d "$SH/alpha" ] && [ ! -L "$SH/alpha" ] || fail "ссылка на скилл в репо не заменена копией"
[ -f "$SRC/alpha/SKILL.md" ] || fail "замена ссылки задела репозиторий"

echo "skills: ok"
