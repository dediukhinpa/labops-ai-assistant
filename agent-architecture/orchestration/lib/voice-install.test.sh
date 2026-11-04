#!/usr/bin/env bash
# Unit tests for lib/voice-install.sh — установщик сам ставит сервис голоса и раздаёт
# токен агентам. systemctl, curl и pip подменены: проверяются пути, права, токен,
# идемпотентность и то, что токен не попадает в командные строки.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

ME="$(id -un)"
SRC="$HERE/../../../voice-transcriber"
[ -f "$SRC/pyproject.toml" ] || fail "нет подпроекта voice-transcriber: $SRC"

# Заглушки: каждая пишет свой argv в общий журнал.
BIN="$TMP/bin"; mkdir -p "$BIN"
LOG="$TMP/calls.log"; : > "$LOG"
HEALTH="$TMP/health"; printf '{"status":"ready"}' > "$HEALTH"
cat > "$BIN/systemctl" <<EOF
#!/usr/bin/env bash
echo "systemctl \$*" >> "$LOG"
EOF
cat > "$BIN/curl" <<EOF
#!/usr/bin/env bash
echo "curl \$*" >> "$LOG"
cat "$HEALTH"
EOF
cat > "$BIN/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$BIN"/*

# Готовый .venv-заглушка: install_code не создаёт настоящий venv и не ходит в PyPI.
DIR="$TMP/opt/voice"
mkdir -p "$DIR/.venv/bin"
printf '#!/usr/bin/env bash\necho "pip $*" >> "%s"\n' "$LOG" > "$DIR/.venv/bin/pip"
printf '#!/usr/bin/env bash\nexit 0\n' > "$DIR/.venv/bin/python"
chmod +x "$DIR/.venv/bin/"*

MODEL_SRC="$TMP/model-src"; mkdir -p "$MODEL_SRC"; echo weights > "$MODEL_SRC/model.bin"
HOME_A="$TMP/home-agent"; mkdir -p "$HOME_A"

run_install() {
  env -u CLAUDE_LAB PATH="$BIN:$PATH" SUDO="" \
    LABOPS_VOICE_DIR="$DIR" LABOPS_VOICE_ETC="$TMP/etc" LABOPS_VOICE_MODELS="$TMP/models" \
    LABOPS_VOICE_UNIT_DIR="$TMP/units" LABOPS_VOICE_USER="$ME" LABOPS_VOICE_OWNER="$ME" \
    LABOPS_VOICE_MODEL_SOURCE="$MODEL_SRC" LABOPS_VOICE_PYTHON="python3" \
    LABOPS_VOICE_SRC="${1:-$SRC}" \
    bash -c '
      ok() { echo "OK $*"; }; warn() { echo "WARN $*"; }; step() { echo "STEP $*"; }
      note() { echo "NOTE $*"; }
      . "'"$HERE"'/voice-install.sh"
      VOICE_MIN_FREE_MB=0
      mkdir -p "$LABOPS_VOICE_UNIT_DIR"
      voice_install "'"$ME"'" "'"$HOME_A"'"'
}

# voice_pick_python требует 3.12+: в constraints.txt зависимости закреплены под 3.12.
python3 -c 'import sys; sys.exit(0 if sys.version_info[:2] >= (3, 12) else 1)' \
  || { echo "SKIP: python3 старше 3.12 — сервис голоса здесь не ставится"; exit 0; }

# 1. Полная установка.
OUT="$(run_install 2>&1)" || fail "установка не прошла: $OUT"
ENV="$TMP/etc/voice-transcriber.env"
TOKEN_FILE="$HOME_A/.claude-lab/shared/secrets/voice-transcriber-token"
[ -f "$ENV" ] || fail "нет env-файла"
[ "$(stat -c %a "$ENV")" = "640" ] || fail "права env-файла не 640: $(stat -c %a "$ENV")"
TOKEN="$(sed -n 's/^VOICE_TRANSCRIBER_API_TOKEN=//p' "$ENV")"
[ "${#TOKEN}" -ge 32 ] || fail "токен короче 32 знаков"
grep -qx "VOICE_MODEL_DIR=$TMP/models" "$ENV" || fail "VOICE_MODEL_DIR не переписан"
[ -f "$TMP/models/faster-whisper-small/model.bin" ] || fail "модель не на месте"
[ -d "$TMP/models/faster-whisper-small.part" ] && fail "остался недокачанный каталог .part"
[ -f "$DIR/voice_transcriber/__main__.py" ] || fail "код сервиса не скопирован"
UNIT="$TMP/units/labops-voice-transcriber.service"
[ -f "$UNIT" ] || fail "юнит не установлен"
grep -q '__[A-Z_]*__' "$UNIT" && fail "в юните остались плейсхолдеры"
grep -qx "User=$ME" "$UNIT" || fail "в юните не тот пользователь"
grep -qx "EnvironmentFile=$ENV" "$UNIT" || fail "в юните не тот env-файл"
for c in "systemctl daemon-reload" "systemctl enable labops-voice-transcriber.service" \
         "systemctl restart labops-voice-transcriber.service"; do
  grep -qxF "$c" "$LOG" || fail "не вызвано: $c"
done
grep -q "^pip install .*-c $DIR/constraints.txt $DIR\$" "$LOG" || fail "pip без constraints.txt"
[ -f "$TOKEN_FILE" ] || fail "токен не передан агентам"
[ "$(stat -c %a "$TOKEN_FILE")" = "600" ] || fail "права файла токена не 600"
[ "$(cat "$TOKEN_FILE")" = "$TOKEN" ] || fail "токен агентов не совпадает с токеном сервиса"
[ "$(stat -c %a "$HOME_A/.claude-lab/shared/secrets")" = "700" ] || fail "права secrets не 700"
grep -qF "$TOKEN" "$LOG" && fail "токен попал в командную строку"
echo "$OUT" | grep -qF "$TOKEN" && fail "токен попал в вывод"

# 2. Повторная установка не меняет токен: иначе голос отвалился бы у всех агентов.
OUT="$(run_install 2>&1)" || fail "повторная установка не прошла: $OUT"
[ "$(sed -n 's/^VOICE_TRANSCRIBER_API_TOKEN=//p' "$ENV")" = "$TOKEN" ] || fail "токен сменился"
[ "$(cat "$TOKEN_FILE")" = "$TOKEN" ] || fail "токен агентов сменился"
echo "$OUT" | grep -q "модель small уже на месте" || fail "модель скачивалась заново"

# 3. Модель не загрузилась — шаг сообщает о сбое, а не о готовности.
printf '{"status":"failed"}' > "$HEALTH"
OUT="$(run_install 2>&1)" && fail "провал загрузки модели принят за успех"
echo "$OUT" | grep -q "не загрузил модель" || fail "нет причины сбоя: $OUT"
printf '{"status":"ready"}' > "$HEALTH"

# 4. Без подпроекта голоса (standalone agent-architecture) — отказ без изменений.
OUT="$(run_install "$TMP/nope" 2>&1)" && fail "установка без подпроекта прошла"
echo "$OUT" | grep -q "нет подпроекта voice-transcriber" || fail "нет причины: $OUT"

# 5. voice_env.py: без токена в env-файле export-token отказывает.
printf 'VOICE_MODEL_DIR=/x\n' > "$TMP/empty.env"
python3 "$HERE/voice_env.py" export-token "$TMP/empty.env" "$TMP/t" 2>/dev/null \
  && fail "export-token принял env без токена"
[ -e "$TMP/t" ] && fail "export-token создал файл без токена"

echo "OK: voice-install.sh — все проверки пройдены"
