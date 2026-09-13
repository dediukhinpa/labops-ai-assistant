#!/usr/bin/env bash
# Unit tests for lib/ui.sh — значки вывода и вопрос да/нет.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

fail() { echo "FAIL: $1"; exit 1; }

# yn <stdin> <default> [NONINTERACTIVE] [предзаданное значение] — печатает вывод,
# последней строкой RESULT=<ответ> EOF=<0|1>.
yn() {
  printf '%b' "$1" | NONINTERACTIVE="${3:-0}" ANS="${4:-}" bash -c '
    source "'"$HERE"'/ui.sh"
    ask_yn ANS "Продолжить?" "'"$2"'"
    echo; echo "RESULT=$ANS EOF=$UI_ASK_EOF"'
}
last() { tail -n1 <<<"$1"; }

# 1. Вопрос показывается как [?] … [y/n], без заглавной подсказки по умолчанию.
out="$(yn 'y\n' n)"
grep -q '\[?\].*Продолжить? \[y/n\]: ' <<<"$out" || fail "формат вопроса: $out"
[ "$(last "$out")" = "RESULT=y EOF=0" ] || fail "y: $(last "$out")"

# 2. Ответы: русские и английские, в любом регистре из перечисленных.
for a in y Y yes YES д Д да Да; do
  [ "$(last "$(yn "$a\n" n)")" = "RESULT=y EOF=0" ] || fail "не принял как да: $a"
done
for a in n N no NO н Н нет Нет; do
  [ "$(last "$(yn "$a\n" y)")" = "RESULT=n EOF=0" ] || fail "не принял как нет: $a"
done

# 3. Enter — ответ по умолчанию.
[ "$(last "$(yn '\n' y)")" = "RESULT=y EOF=0" ] || fail "Enter при default=y"
[ "$(last "$(yn '\n' n)")" = "RESULT=n EOF=0" ] || fail "Enter при default=n"

# 4. Непонятный ответ переспрашивается, а не считается «да».
out="$(yn 'может\nn\n' y)"
[ "$(grep -o '\[y/n\]' <<<"$out" | wc -l)" -eq 2 ] || fail "мусорный ответ не переспрошен"
[ "$(last "$out")" = "RESULT=n EOF=0" ] || fail "после переспроса: $(last "$out")"

# 5. Закрытый stdin — ответ по умолчанию, флаг EOF, без зацикливания.
out="$(printf '' | timeout 5 bash -c 'source "'"$HERE"'/ui.sh"; ask_yn A "Q" n; echo "RESULT=$A EOF=$UI_ASK_EOF"')" \
  || fail "закрытый stdin: зависание или падение"
[ "$(last "$out")" = "RESULT=n EOF=1" ] || fail "закрытый stdin: $(last "$out")"

# 6. Под set -e закрытый stdin не обрывает скрипт.
out="$(printf '' | bash -c 'set -euo pipefail; source "'"$HERE"'/ui.sh"; ask_yn A "Q" y; echo "alive $A"')"
[ "$(last "$out")" = "alive y" ] || fail "set -e: скрипт оборвался на EOF"

# 7. NONINTERACTIVE и предзаданное значение — без вопроса.
out="$(yn 'n\n' y 1)"
grep -q '\[y/n\]' <<<"$out" && fail "NONINTERACTIVE: задан вопрос"
[ "$(last "$out")" = "RESULT=y EOF=0" ] || fail "NONINTERACTIVE: $(last "$out")"
out="$(yn 'y\n' y 0 no)"
grep -q '\[y/n\]' <<<"$out" && fail "предзаданное значение: задан вопрос"
[ "$(last "$out")" = "RESULT=n EOF=0" ] || fail "предзаданное no: $(last "$out")"

# 8. Значки: у каждого уровня свой, die уходит в stderr и завершает с ошибкой.
# shellcheck source=ui.sh
source "$HERE/ui.sh"
[[ "$(say x)" == *"▶ x"* ]] || fail "say без ▶"
[[ "$(ok x)" == *"✓ x"* ]] || fail "ok без ✓"
[[ "$(warn x)" == *"⚠ x"* ]] || fail "warn без ⚠"
[[ "$(step x)" == *"→ x"* ]] || fail "step без →"
[[ "$(note x)" == *"ℹ x"* ]] || fail "note без ℹ"
err_out="$( (die boom) 2>&1 >/dev/null )"; rc=0; (die boom) >/dev/null 2>&1 || rc=$?
[[ "$err_out" == *"✗ boom"* ]] && [ "$rc" -ne 0 ] || fail "die: не в stderr или код 0"

# 9. err — ✗ в stderr, но без выхода; ask_text — [?] и ответ, закрытый stdin = пусто.
err_out="$( (err oops; echo alive >&2) 2>&1 >/dev/null )"
[[ "$err_out" == *"✗ oops"*alive* ]] || fail "err: не в stderr или завершил скрипт"
out="$(printf 'два слова\n' | bash -c 'source "'"$HERE"'/ui.sh"; ask_text V "Имя"; echo; echo "RESULT=$V"')"
grep -q '\[?\].*Имя: ' <<<"$out" || fail "ask_text: формат вопроса: $out"
[ "$(last "$out")" = "RESULT=два слова" ] || fail "ask_text: ответ: $(last "$out")"
out="$(printf '' | bash -c 'set -euo pipefail; source "'"$HERE"'/ui.sh"; V=old; ask_text V "Имя"; echo; echo "RESULT=[$V]"')"
[ "$(last "$out")" = "RESULT=[]" ] || fail "ask_text: закрытый stdin: $(last "$out")"

echo "ui: ok"
