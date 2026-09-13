#!/usr/bin/env bash
# Unit tests for lib/model-choice.sh — предупреждение при выборе Haiku.
# Главное: haiku не проходит молча, отказ ведёт к новому выбору, а без живого
# ввода установка не зацикливается и не падает.
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

# 3. Haiku + согласие — модель остаётся, предупреждение показано.
out="$(run haiku 'y\n')"
echo "$out" | grep -q 'может не отвечать' || fail "haiku: нет предупреждения"
echo "$out" | grep -q 'RESULT=haiku$' || fail "haiku + y: модель не сохранилась: $out"
out="$(run haiku 'да\n')"
echo "$out" | grep -q 'RESULT=haiku$' || fail "haiku + да: модель не сохранилась"

# 4. Haiku + Enter (по умолчанию «нет») + новый выбор.
out="$(run haiku '\nsonnet\n')"
echo "$out" | grep -q 'RESULT=sonnet$' || fail "отказ не привёл к новому выбору: $out"

# 5. Отказ + Enter на новом вопросе — значение по умолчанию.
out="$(run haiku 'n\n\n')"
echo "$out" | grep -q 'RESULT=sonnet$' || fail "Enter на новом вопросе не дал sonnet: $out"

# 6. Повторно ввели haiku — спрашиваем снова, а не пропускаем.
out="$(run haiku 'n\nhaiku\ny\n')"
[ "$(echo "$out" | grep -c 'может не отвечать')" -eq 2 ] || fail "повторный haiku прошёл без вопроса"
echo "$out" | grep -q 'RESULT=haiku$' || fail "повтор + согласие: модель не сохранилась"

# 7. Закрытый stdin — не зацикливается, выбор оставлен, предупреждение есть.
out="$(printf '' | NONINTERACTIVE=0 PRIMARY_MODEL=haiku timeout 5 bash -c '
    source "'"$HERE"'/model-choice.sh"
    confirm_primary_model
    echo "RESULT=$PRIMARY_MODEL"')" || fail "закрытый stdin: зависание или падение"
echo "$out" | grep -q 'может не отвечать' || fail "закрытый stdin: нет предупреждения"
echo "$out" | grep -q 'RESULT=haiku$' || fail "закрытый stdin: модель изменилась"

# 8. NONINTERACTIVE — без вопроса, но с предупреждением.
out="$(run haiku 'n\nsonnet\n' 1)"
echo "$out" | grep -q "\[y/n\]" && fail "NONINTERACTIVE: задан вопрос"
echo "$out" | grep -q 'может не отвечать' || fail "NONINTERACTIVE: нет предупреждения"
echo "$out" | grep -q 'RESULT=haiku$' || fail "NONINTERACTIVE: модель изменилась"

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

# 13. Мусор, исправленный на haiku, всё равно проходит через предупреждение.
out="$(run 'ыhaiku' 'haiku\ny\n' 2>&1)"
echo "$out" | grep -q 'может не отвечать' || fail "мусор → haiku: нет предупреждения"
echo "$out" | grep -q 'RESULT=haiku$' || fail "мусор → haiku + y: $out"

echo "model-choice: ok"
