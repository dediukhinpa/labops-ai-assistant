#!/usr/bin/env bash
# Unit tests for lib/skills-external.sh — внешние скиллы ставятся по манифесту с закреплёнными SHA.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=skills.sh
. "$HERE/skills.sh"
# shellcheck source=skills-external.sh
. "$HERE/skills-external.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

LAB="$TMP/lab"; SH="$LAB/shared/skills"; BASE="$TMP/base"; MAN="$TMP/manifest"
SHA1="1111111111111111111111111111111111111111"
SHA2="2222222222222222222222222222222222222222"
SHA3="3333333333333333333333333333333333333333"
export SKILLS_EXTERNAL_BASE="file://$BASE"

# make_repo <owner/repo> <sha> <skill>... — тарболл как у GitHub: <repo>-<sha>/skills/<skill>/SKILL.md
make_repo() {
  local repo="$1" sha="$2"; shift 2
  local root="$TMP/build/${repo//\//_}-$sha" s
  rm -rf "$root"; mkdir -p "$root"
  for s in "$@"; do
    mkdir -p "$root/skills/$s/scripts"
    echo "$s@$sha" > "$root/skills/$s/SKILL.md"
    echo run > "$root/skills/$s/scripts/run.sh"
  done
  mkdir -p "$BASE/$repo/tar.gz"
  tar -czf "$BASE/$repo/tar.gz/$sha" -C "$TMP/build" "$(basename "$root")"
}

make_repo own/pack "$SHA1" alpha beta
make_repo other/pack "$SHA1" gamma
cat > "$MAN" <<EOF
# комментарий и пустые строки допустимы

alpha own/pack $SHA1 skills/alpha
beta  own/pack $SHA1 skills/beta
gamma other/pack $SHA1 skills/gamma
EOF

# 1. Установка: копия каталогом, вложенные файлы на месте, список записан.
out="$(sync_external_skills "$MAN" "$LAB")"
for s in alpha beta gamma; do
  [ -f "$SH/$s/SKILL.md" ] && [ ! -L "$SH/$s" ] || fail "$s не установлен"
done
[ -f "$SH/alpha/scripts/run.sh" ] || fail "вложенные файлы не скопированы"
echo "$out" | grep -q 'поставлено 3' || fail "итог не показан: $out"
grep -qxF "alpha $SHA1" "$SH/$SKILLS_EXTERNAL_LIST" || fail "список не записан"
ls -A "$SH" | grep -q '\.new\.\|\.old\.' && fail "остались временные каталоги"

# 2. Повтор без сети: актуальное не качается заново (тарболлы убраны) и не ломается.
mv "$BASE" "$TMP/base-away"
out="$(sync_external_skills "$MAN" "$LAB")"
echo "$out" | grep -q 'актуальны 3' || fail "повтор перекачал или упал: $out"
mv "$TMP/base-away" "$BASE"

# 3. Новая версия: SHA в манифесте меняется — скилл обновляется.
make_repo own/pack "$SHA2" alpha beta
sed -i "s/own\/pack $SHA1/own\/pack $SHA2/" "$MAN"
sync_external_skills "$MAN" "$LAB" >/dev/null
[ "$(cat "$SH/alpha/SKILL.md")" = "alpha@$SHA2" ] || fail "обновление не доехало"
[ "$(cat "$SH/gamma/SKILL.md")" = "gamma@$SHA1" ] || fail "чужой репозиторий задет"

# 4. Снятый из манифеста уходит, скилл оператора остаётся.
mkdir -p "$SH/operator-own"; echo own > "$SH/operator-own/SKILL.md"
sed -i '/^gamma /d' "$MAN"
out="$(sync_external_skills "$MAN" "$LAB")"
[ ! -e "$SH/gamma" ] || fail "снятый скилл остался"
echo "$out" | grep -q 'убран снятый внешний скилл: gamma' || fail "удаление не показано"
[ -f "$SH/operator-own/SKILL.md" ] || fail "скилл оператора удалён"

# 5. Одноимённый скилл репозитория и скилл оператора главнее внешнего.
printf 'alpha\n' > "$SH/$SKILLS_MANAGED_LIST"
echo local > "$SH/alpha/SKILL.md"
echo "operator-own own/pack $SHA2 skills/alpha" >> "$MAN"
out="$(sync_external_skills "$MAN" "$LAB" 2>&1)"
[ "$(cat "$SH/alpha/SKILL.md")" = local ] || fail "скилл репозитория перезаписан"
[ "$(cat "$SH/operator-own/SKILL.md")" = own ] || fail "скилл оператора перезаписан"
echo "$out" | grep -q 'alpha пропущен' || fail "коллизия с репозиторием не показана: $out"
echo "$out" | grep -q 'operator-own пропущен' || fail "коллизия с оператором не показана: $out"
sed -i '/^operator-own /d' "$MAN"; rm "$SH/$SKILLS_MANAGED_LIST"

# 6. Недоступный репозиторий: код 4, остальные ставятся, прежняя версия остаётся.
echo "delta missing/repo $SHA3 skills/delta" >> "$MAN"
rc=0; out="$(sync_external_skills "$MAN" "$LAB" 2>&1)" || rc=$?
[ "$rc" -eq 4 ] || fail "ожидался код 4, получен $rc"
echo "$out" | grep -q 'не скачан missing/repo' || fail "ошибка скачивания не показана: $out"
[ -f "$SH/beta/SKILL.md" ] || fail "доступные скиллы не поставлены"
[ ! -e "$SH/delta" ] || fail "недоступный скилл появился"
sed -i '/^delta /d' "$MAN"

# 7. Нет пути в репозитории — ошибка, не пустой скилл.
echo "ghost own/pack $SHA2 skills/ghost" >> "$MAN"
rc=0; out="$(sync_external_skills "$MAN" "$LAB" 2>&1)" || rc=$?
[ "$rc" -eq 4 ] && [ ! -e "$SH/ghost" ] || fail "отсутствующий путь принят (rc=$rc)"
echo "$out" | grep -q 'нет skills/ghost/SKILL.md' || fail "отсутствие пути не показано"
sed -i '/^ghost /d' "$MAN"

# 8. Симлинк внутри скилла — отказ.
root="$TMP/build/evil_pack-$SHA1"; rm -rf "$root"; mkdir -p "$root/skills/sly"
echo s > "$root/skills/sly/SKILL.md"; ln -s /etc/passwd "$root/skills/sly/leak"
mkdir -p "$BASE/evil/pack/tar.gz"
tar -czf "$BASE/evil/pack/tar.gz/$SHA1" -C "$TMP/build" "$(basename "$root")"
echo "sly evil/pack $SHA1 skills/sly" >> "$MAN"
rc=0; out="$(sync_external_skills "$MAN" "$LAB" 2>&1)" || rc=$?
[ "$rc" -eq 4 ] && [ ! -e "$SH/sly" ] || fail "скилл с симлинком принят (rc=$rc)"
echo "$out" | grep -q 'симлинки' || fail "симлинк не показан"
sed -i '/^sly /d' "$MAN"

# 9. Испорченный манифест: код 1, ничего не меняется.
for bad in "x own/pack deadbeef skills/x" \
           "x own/pack $SHA1 ../escape" \
           "x own/pack $SHA1 /abs/path" \
           "X own/pack $SHA1 skills/x" \
           "x ownpack $SHA1 skills/x" \
           "x own/pack $SHA1" \
           "x own/pack $SHA1 skills/x extra"; do
  printf '%s\n' "$bad" > "$TMP/bad"
  before="$(cat "$SH/$SKILLS_EXTERNAL_LIST")"
  rc=0; sync_external_skills "$TMP/bad" "$LAB" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 1 ] || fail "строка «$bad» принята (rc=$rc)"
  [ "$(cat "$SH/$SKILLS_EXTERNAL_LIST")" = "$before" ] || fail "список изменён на «$bad»"
done
rc=0; sync_external_skills "$TMP/нет-такого" "$LAB" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 1 ] || fail "нет манифеста: ожидался код 1, получен $rc"

echo "OK"
