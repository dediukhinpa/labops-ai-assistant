#!/usr/bin/env bash
# Unit tests for lib/dangerous-mode.sh — запись согласия оператора на режим
# без проверок. Проверяется главное: чужие настройки переживают запись, битый
# файл не переписывается, повтор ничего не портит.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1091
source "$HERE/dangerous-mode.sh"

fail() { echo "FAIL: $1"; exit 1; }

# 1. Файла нет — согласия нет, и это не ошибка чтения.
CFG="$TMP/none/settings.json"
dangerous_mode_accepted "$CFG" && fail "согласие найдено там, где файла нет"

# 2. Запись создаёт и файл, и каталог.
dangerous_mode_record_consent "$CFG" || fail "согласие не записалось в новый файл"
dangerous_mode_accepted "$CFG" || fail "записанное согласие не читается обратно"

# 3. Чужие настройки переживают запись — файл пользователя, а не наш.
CFG2="$TMP/settings.json"
printf '{"model": "opus", "theme": "dark", "hooks": {"SessionStart": []}}' > "$CFG2"
dangerous_mode_record_consent "$CFG2" || fail "согласие не записалось в существующий файл"
python3 - "$CFG2" <<'PY' || fail "запись потеряла чужие ключи"
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert d["model"] == "opus", d
assert d["theme"] == "dark", d
assert d["hooks"] == {"SessionStart": []}, d
assert d["skipDangerousModePermissionPrompt"] is True, d
PY

# 4. Повтор идемпотентен: ни ошибки, ни изменения файла.
BEFORE="$(cat "$CFG2")"
dangerous_mode_record_consent "$CFG2" || fail "повторная запись вернула ошибку"
[ "$BEFORE" = "$(cat "$CFG2")" ] || fail "повторная запись изменила файл"

# 5. Битый JSON не переписываем: чужие настройки дороже нашего удобства.
CFG3="$TMP/broken.json"
printf '{ not json at all' > "$CFG3"
dangerous_mode_record_consent "$CFG3" && fail "битый файл переписан — потеряли бы чужие настройки"
grep -q 'not json at all' "$CFG3" || fail "битый файл всё-таки изменён"

# 6. Согласие «false» — это НЕ согласие: оператор мог снять его руками.
CFG4="$TMP/off.json"
printf '{"skipDangerousModePermissionPrompt": false}' > "$CFG4"
dangerous_mode_accepted "$CFG4" && fail "false принято за согласие"

echo "OK: dangerous-mode.sh — 6 проверок пройдено"
