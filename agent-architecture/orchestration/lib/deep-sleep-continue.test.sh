#!/usr/bin/env bash
# Unit tests for lib/deep-sleep-continue.sh — метка глубокого сна печатает
# --continue и забирает себя; без метки — тихо и без ошибки.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1091
source "$HERE/deep-sleep-continue.sh"

fail() { echo "FAIL: $1"; exit 1; }

# 1. Метки нет — флага нет, и это не ошибка (тихий обычный старт).
MARKER="$TMP/none/deep-sleep-continue"
out="$(deep_sleep_continue_flag "$MARKER")" && fail "флаг найден там, где метки нет"
[ -z "$out" ] || fail "непустой вывод без метки: $out"

# 2. Метка есть — печатает --continue и убирает метку с диска.
MARKER="$TMP/home/.claude/state/deep-sleep-continue"
mkdir -p "$(dirname "$MARKER")"
: > "$MARKER"
out="$(deep_sleep_continue_flag "$MARKER")" || fail "флаг не напечатан при наличии метки"
[ "$out" = "--continue" ] || fail "неожиданный вывод: $out"
[ -f "$MARKER" ] && fail "метка не забрана — следующий краш-рестарт продолжил бы старую сессию"

# 3. Повторный вызов после потребления — снова тихо, без ошибки повторно.
out="$(deep_sleep_continue_flag "$MARKER")" && fail "флаг напечатан повторно — метка уже потреблена"
[ -z "$out" ] || fail "непустой вывод при повторном вызове: $out"

# 4. Без аргумента читает DEEP_SLEEP_MARKER из окружения.
export DEEP_SLEEP_MARKER="$TMP/env/.claude/state/deep-sleep-continue"
mkdir -p "$(dirname "$DEEP_SLEEP_MARKER")"
: > "$DEEP_SLEEP_MARKER"
out="$(deep_sleep_continue_flag)" || fail "флаг не напечатан по умолчанию из DEEP_SLEEP_MARKER"
[ "$out" = "--continue" ] || fail "неожиданный вывод по умолчанию: $out"

echo "OK: deep-sleep-continue.sh — 4 проверки пройдено"
