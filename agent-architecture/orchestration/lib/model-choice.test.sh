#!/usr/bin/env bash
# Unit tests for lib/model-choice.sh — Haiku в выборе модели не принимается.
# Главное: haiku ведёт к новому вопросу, а без живого ввода установка
# останавливается, не зацикливаясь.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

# shellcheck disable=SC1091
source "$HERE/model-choice.sh"

fail() { echo "FAIL: $1"; exit 1; }

# run <модель> <stdin> [NONINTERACTIVE] — печатает итоговую модель последней строкой.
run() {
  printf '%b' "$2" | NONINTERACTIVE="${3:-0}" PRIMARY_MODEL="$1" bash -c '
    source "'"$HERE"'/model-choice.sh"
    confirm_primary_model
    echo "RESULT=$PRIMARY_MODEL"'
}

# 1. Семейство Haiku узнаётся и по алиасу, и по полному имени, в любом регистре.
for m in haiku Haiku claude-haiku-4-5-20251001; do
  is_haiku_model "$m" || fail "не узнал Haiku: $m"
done
for m in opus sonnet fable claude-sonnet-5 ""; do
  is_haiku_model "$m" && fail "принял за Haiku: $m"
done

# 2. Не Haiku — ни вопроса, ни предупреждения.
out="$(run opus '')"
[ "$out" = "RESULT=opus" ] || fail "opus: лишний вывод или смена модели: $out"

# 3. Haiku отвергается: ошибка и вопрос заново, итог — новая модель.
out="$(run haiku 'opus\n' 2>&1)"
echo "$out" | grep -q 'не поддерживается' || fail "haiku: нет ошибки: $out"
echo "$out" | grep -q 'RESULT=opus$' || fail "haiku: не переспросил: $out"
echo "$out" | grep -q "\[y/n\]" && fail "haiku: предложено оставить"

# 4. Haiku + Enter на новом вопросе — значение по умолчанию.
out="$(run claude-haiku-4-5-20251001 '\n' 2>&1)"
echo "$out" | grep -q 'RESULT=sonnet$' || fail "Enter после haiku не дал sonnet: $out"

# 5. Повторно ввели haiku — снова отказ, пока не выберут другую модель.
out="$(run haiku 'Haiku\nsonnet\n' 2>&1)"
[ "$(echo "$out" | grep -c 'не поддерживается')" -eq 2 ] || fail "повторный haiku прошёл: $out"
echo "$out" | grep -q 'RESULT=sonnet$' || fail "повтор: итог не sonnet: $out"

# 6. Haiku без живого ввода — установка останавливается, модель не записана.
rc=0; out="$(printf '' | NONINTERACTIVE=0 PRIMARY_MODEL=haiku timeout 5 bash -c '
    source "'"$HERE"'/model-choice.sh"
    confirm_primary_model
    echo "RESULT=$PRIMARY_MODEL"' 2>&1)" || rc=$?
[ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] || fail "закрытый stdin + haiku: не остановился (rc=$rc): $out"
echo "$out" | grep -q 'RESULT=' && fail "закрытый stdin + haiku: модель записана"

# 7. NONINTERACTIVE + haiku — остановка без вопроса.
rc=0; out="$(run haiku 'sonnet\n' 1 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "NONINTERACTIVE + haiku: не остановился: $out"
echo "$out" | grep -q 'RESULT=' && fail "NONINTERACTIVE + haiku: модель записана"

# 9. Имя модели: допустимые проходят, мусор от русской раскладки — нет.
for m in opus sonnet fable haiku claude-opus-5 'claude-opus-5[1m]' claude-haiku-4-5-20251001 'opus[1m]'; do
  is_valid_model_name "$m" || fail "отверг допустимое имя: $m"
done
for m in "" $'\xd1\x8b\xd1sonnet' 'ыsonnet' 'sonnet ы' 'son net' '-opus' 'opus;rm' 'opus"'; do
  is_valid_model_name "$m" && fail "принял недопустимое имя: $(printf '%q' "$m")"
done

# 10. Мусор в ответе — вопрос заново, итог чистый; байты показаны в виде %q.
out="$(run $'\xd1\x8b\xd1sonnet' 'sonnet\n' 2>&1)"
echo "$out" | grep -q 'Недопустимое имя модели' || fail "мусор: нет ошибки"
echo "$out" | grep -qF '\321sonnet' || fail "мусор: байты не показаны через %q: $out"
echo "$out" | grep -q 'RESULT=sonnet$' || fail "мусор: не переспросил: $out"

# 11. Мусор, затем Enter — значение по умолчанию; пробелы по краям срезаются.
out="$(run 'ыsonnet' '\n' 2>&1)"
echo "$out" | grep -q 'RESULT=sonnet$' || fail "мусор + Enter: не sonnet: $out"
out="$(run '  sonnet ' '' 2>&1)"
[ "$out" = "RESULT=sonnet" ] || fail "пробелы по краям не срезаны: $out"

# 12. Мусор без живого ввода — установка останавливается, а не пишет модель.
rc=0; out="$(run 'ыsonnet' '' 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "закрытый stdin + мусор: не остановился: $out"
echo "$out" | grep -q 'RESULT=' && fail "закрытый stdin + мусор: модель записана"
rc=0; out="$(run 'ыsonnet' 'sonnet\n' 1 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "NONINTERACTIVE + мусор: не остановился: $out"

# 13. Мусор, исправленный на haiku, всё равно отвергается.
out="$(run 'ыhaiku' 'haiku\nopus\n' 2>&1)"
echo "$out" | grep -q 'не поддерживается' || fail "мусор → haiku: нет отказа"
echo "$out" | grep -q 'RESULT=opus$' || fail "мусор → haiku → opus: $out"

echo "model-choice: ok"
