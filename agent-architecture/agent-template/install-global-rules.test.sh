#!/usr/bin/env bash
# Поведенческий тест: общие правила агентов не теряются молча, если у пользователя
# уже есть свой ~/.claude/CLAUDE.md.
#
# Правила git, безопасности и смены модели живут только в глобальном файле. Раньше
# install.sh при существующем файле просто его пропускал -- тогда это было терпимо,
# те же правила дублировались в агентских файлах. Без дублей такой пропуск оставил
# бы агента совсем без них.
#
# Гоняется настоящий install.sh в неинтерактивном режиме. Весь след -- в подменённых
# HOME и CLAUDE_LAB во временном каталоге; каталог скиллов не линкуется (ENABLE_ALL=n).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

MARKER='# Global Rules -- All Agents'

run_install() {   # <home> <файл-вывода>
  HOME="$1" CLAUDE_LAB="$1/lab" NONINTERACTIVE=1 AGENT_NAME=probe ENABLE_ALL=n \
    bash "$HERE/install.sh" >"$2" 2>&1 </dev/null
}

# 1. Чистый пользователь: общие правила ложатся на место, запасного файла нет.
H1="$TMP/clean"; mkdir -p "$H1"
run_install "$H1" "$TMP/out1.txt" || fail "install.sh упал на чистом пользователе"
grep -qxF "$MARKER" "$H1/.claude/CLAUDE.md" || fail "общие правила не установлены"
[ ! -e "$H1/.claude/CLAUDE.md.labops-new" ] || fail "запасной файл создан без причины"

# 2. Свой глобальный файл: его не трогаем, наши правила кладём рядом и говорим об этом.
H2="$TMP/own"; mkdir -p "$H2/.claude"
printf '# my own rules\n- keep me\n' > "$H2/.claude/CLAUDE.md"
run_install "$H2" "$TMP/out2.txt" || fail "install.sh упал при своём глобальном файле"
[ "$(cat "$H2/.claude/CLAUDE.md")" = "$(printf '# my own rules\n- keep me')" ] \
  || fail "свой глобальный файл владельца изменён"
grep -qxF "$MARKER" "$H2/.claude/CLAUDE.md.labops-new" \
  || fail "общие правила не положены рядом со своим файлом"
grep -q 'CLAUDE.md.labops-new' "$TMP/out2.txt" \
  || fail "оператору не сказано, что правила нужно перенести"

# 3. Запасной файл отрендерен так же, как основной: без сырых плейсхолдеров.
grep -q '{{' "$H2/.claude/CLAUDE.md.labops-new" && fail "в запасном файле остались плейсхолдеры"

# 4. Повторный запуск поверх наших же правил не принимает их за чужие.
run_install "$H1" "$TMP/out3.txt" || fail "повторный запуск упал"
[ ! -e "$H1/.claude/CLAUDE.md.labops-new" ] || fail "свои же правила приняты за чужие"

echo "OK: install.sh global rules — 4 проверки пройдено"
