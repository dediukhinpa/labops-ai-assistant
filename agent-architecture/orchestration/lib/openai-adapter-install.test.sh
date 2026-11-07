#!/usr/bin/env bash
# Unit tests for lib/openai-adapter-install.sh - установка адаптера Claude Code -> ChatGPT (подписка).
# systemctl, curl, useradd, openssl, pip и вход в ChatGPT подменены: проверяются пути, права,
# ключи, идемпотентность и то, что токены входа и ключ шлюза не попадают ни в argv, ни в вывод.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

ME="$(id -un)"
SRC="$HERE/../../openai-adapter"
[ -f "$SRC/requirements.lock" ] || fail "нет requirements.lock: $SRC"
[ -f "$SRC/config.template.yaml" ] || fail "нет config.template.yaml: $SRC"
grep -q -- '--hash=sha256:' "$SRC/requirements.lock" || fail "в lock-файле нет хэшей"

BIN="$TMP/bin"; mkdir -p "$BIN"
for t in bash env cat sed grep install mktemp rm id awk df tr dirname head tail cp touch test chmod sh; do
  p="$(type -P "$t")" && ln -sf "$p" "$BIN/$t"
done
LOG="$TMP/calls.log"; : > "$LOG"
HEALTH="$TMP/health"; echo up > "$HEALTH"
stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$BIN/$1"; chmod +x "$BIN/$1"; }
stub systemctl "echo \"systemctl \$*\" >> \"$LOG\""
stub useradd "echo \"useradd \$*\" >> \"$LOG\""
stub sleep 'exit 0'
# fakesudo понимает «-u пользователь»: так установщик запускает вход от имени службы.
stub fakesudo 'if [ "${1:-}" = "-u" ]; then shift 2; fi; exec "$@"'
stub openssl 'echo 00112233445566778899aabbccddeeff0011223344556677'
stub curl "echo \"curl \$*\" >> \"$LOG\"; [ -s \"$HEALTH\" ]"
stub python3 'exit 0'

# Готовый .venv-заглушка: pip не ходит в сеть, а его аргументы пишутся в журнал.
DIR="$TMP/opt/adapter"
mkdir -p "$DIR/.venv/bin"
printf '#!/usr/bin/env bash\necho "pip $*" >> "%s"\n' "$LOG" > "$DIR/.venv/bin/pip"
# «python» venv - это вход в ChatGPT: кладёт токены в CHATGPT_TOKEN_DIR, как это делает LiteLLM.
LOGIN_TOKEN="fake-access-token-9f8e7d6c"
cat > "$DIR/.venv/bin/python" <<PYSTUB
#!/usr/bin/env bash
echo "login \$CHATGPT_TOKEN_DIR" >> "$LOG"
echo "cwd \$(pwd -P)" >> "$LOG"
echo "Sign in with ChatGPT using device code: https://auth.openai.com/codex/device CODE-1234"
[ -z "\${LOGIN_FAIL:-}" ] || exit 1
[ -n "\${LOGIN_NO_FILE:-}" ] || printf '{"access_token":"$LOGIN_TOKEN"}' > "\$CHATGPT_TOKEN_DIR/auth.json"
PYSTUB
chmod +x "$DIR/.venv/bin/"*

HOME_A="$TMP/home-agent"; mkdir -p "$HOME_A"
ETC="$TMP/etc"; UNITS="$TMP/units"; STATE="$TMP/state"; mkdir -p "$UNITS"

run_install() {   # окружение подаётся снаружи через ENV_EXTRA
  env -i PATH="$BIN" HOME="$HOME_A" SUDO="$BIN/fakesudo" ${ENV_EXTRA:-} \
    LABOPS_LLM_SRC="$SRC" LABOPS_LLM_DIR="$DIR" LABOPS_LLM_ETC="$ETC" \
    LABOPS_LLM_UNIT_DIR="$UNITS" LABOPS_LLM_STATE="$STATE" LABOPS_LLM_USER="$ME" LABOPS_LLM_OWNER="$ME" \
    LABOPS_LLM_PYTHON="$BIN/python3" \
    bash -c '
      ok() { echo "OK $*"; }; warn() { echo "WARN $*"; }; note() { echo "NOTE $*"; }
      . "'"$HERE"'/openai-adapter-install.sh"
      LLM_MIN_FREE_MB=0
      openai_adapter_install "'"$ME"'" "'"$HOME_A"'"'
}

# 1. Полная установка.
ENV_EXTRA="LABOPS_OPENAI_MODEL=gpt-test-1"
OUT="$(run_install 2>&1)" || fail "установка не прошла: $OUT"
CONF="$ETC/config.yaml"; ENVF="$ETC/adapter.env"; UNIT="$UNITS/labops-openai-adapter.service"
SHARED="$HOME_A/.claude-lab/shared/secrets/openai-adapter.env"
grep -q 'model_name: gpt-test-1' "$CONF" || fail "в конфиге нет имени модели"
grep -q 'model: chatgpt/gpt-test-1' "$CONF" || fail "в конфиге нет chatgpt/<модель>"
grep -qx '  callbacks: flatten_system.flatten_system' "$CONF" || fail "в конфиге нет хука flatten_system"
cmp -s "$SRC/flatten_system.py" "$ETC/flatten_system.py" || fail "хук не установлен рядом с конфигом"
[ "$(stat -c %a "$ETC/flatten_system.py")" = "640" ] || fail "права хука не 640"
# На сервер ставится только сам хук: юнит-тесты и смоук остаются в репозитории.
STRAY="$(find "$ETC" "$DIR" -path "$DIR/.venv" -prune -o \( -name tests -o -name smoke \) -print)"
[ -z "$STRAY" ] || fail "в /etc или каталог адаптера попали tests/ или smoke/"
[ "$(find "$ETC" -name '*.py' | wc -l)" -eq 1 ] || fail "в каталоге конфига лишние .py, кроме хука"
grep -q 'mode: responses' "$CONF" || fail "режим responses не задан: новая модель уйдёт в chat/completions"
grep -q '__MODEL__' "$CONF" && fail "в конфиге остался плейсхолдер"
grep -qi 'api_key\|OPENAI_API_KEY' "$CONF" && fail "в конфиге остались следы ключа API"
[ "$(stat -c %a "$ENVF")" = "640" ] || fail "права env-файла не 640: $(stat -c %a "$ENVF")"
grep -q '^OPENAI_API_KEY' "$ENVF" && fail "в env-файле остался ключ API"
grep -qx "CHATGPT_TOKEN_DIR=$STATE" "$ENVF" || fail "юнит не знает, где токены входа"
grep -q '^LITELLM_MASTER_KEY=sk-' "$ENVF" || fail "в env-файле нет ключа шлюза"
MASTER="$(sed -n 's/^LITELLM_MASTER_KEY=//p' "$ENVF")"
grep -qx 'LITELLM_LOCAL_MODEL_COST_MAP=True' "$ENVF" || fail "адаптер будет качать таблицу цен"
[ "$(stat -c %a "$STATE")" = "700" ] || fail "каталог токенов не 700: $(stat -c %a "$STATE")"
[ "$(stat -c %a "$STATE/auth.json")" = "600" ] || fail "токены входа не 600"
grep -qx "login $STATE" "$LOG" || fail "вход в ChatGPT не запускался в каталоге токенов"
grep -qx "cwd $(cd "$STATE" && pwd -P)" "$LOG" || fail "вход запущен не из каталога токенов: у службы нет доступа к чужой папке"
echo "$OUT" | grep -q "CODE-1234" || fail "человеку не показан код входа"
grep -q -- '--host 127.0.0.1' "$UNIT" || fail "юнит слушает не только 127.0.0.1"
grep -q -- '--port 4000' "$UNIT" || fail "в юните не тот порт"
grep -qx "EnvironmentFile=$ETC/adapter.env" "$UNIT" || fail "в юните не тот env-файл"
grep -qx "User=$ME" "$UNIT" || fail "в юните не тот пользователь"
grep -q "^pip install .*--require-hashes -r $DIR/requirements.lock" "$LOG" \
  || fail "зависимости ставятся не по lock-файлу с хэшами"
grep -qx "systemctl restart labops-openai-adapter.service" "$LOG" || fail "юнит не перезапущен"
grep -q "curl .*liveliness" "$LOG" || fail "нет проверки готовности"
[ -f "$SHARED" ] || fail "ключ шлюза не передан агентам"
[ "$(stat -c %a "$SHARED")" = "600" ] || fail "права файла для агентов не 600"
grep -qx "ANTHROPIC_AUTH_TOKEN=$MASTER" "$SHARED" || fail "в файле агентов не тот токен"
grep -qx "LABOPS_OPENAI_MODEL=gpt-test-1" "$SHARED" || fail "в файле агентов нет модели"
grep -qF "$LOGIN_TOKEN" "$SHARED" "$CONF" "$ENVF" "$UNIT" && fail "токен входа попал не в каталог токенов"
grep -qF "$MASTER" "$LOG" && fail "ключ шлюза попал в командную строку"
echo "$OUT" | grep -qF "$LOGIN_TOKEN" && fail "токен входа попал в вывод"
echo "$OUT" | grep -qF "$MASTER" && fail "ключ шлюза попал в вывод"

# 2. Повтор: ключ шлюза не меняется (иначе агенты потеряли бы доступ), модель можно сменить.
: > "$LOG"; ENV_EXTRA="LABOPS_OPENAI_MODEL=gpt-test-2"
run_install >/dev/null 2>&1 || fail "повторная установка не прошла"
[ "$(sed -n 's/^LITELLM_MASTER_KEY=//p' "$ENVF")" = "$MASTER" ] || fail "ключ шлюза сменился"
grep -q 'model_name: gpt-test-2' "$CONF" || fail "модель не обновилась"
grep -qx "LABOPS_OPENAI_MODEL=gpt-test-2" "$SHARED" || fail "модель в файле агентов не обновилась"

# 3. Недопустимое имя модели - ничего не ставится.
rm -rf "$ETC"; : > "$LOG"
ENV_EXTRA="LABOPS_OPENAI_MODEL=gpt;rm" OUT="$(run_install 2>&1)" \
  && fail "принято недопустимое имя модели"
echo "$OUT" | grep -q "недопустимые символы" || fail "нет объяснения про имя модели"
[ -e "$ETC/adapter.env" ] && fail "env-файл создан при ошибке в имени модели"

# 4. Без модели и без терминала берётся рекомендуемая: вопрос задать некому.
rm -rf "$ETC"
ENV_EXTRA="X=1" OUT="$(run_install 2>&1 </dev/null)" || fail "без модели установка должна взять рекомендуемую: $OUT"
grep -q 'model: chatgpt/gpt-6.1-sol' "$ETC/config.yaml" || fail "рекомендуемая модель не подставлена"

# 5. Вход не завершён - установка честно падает и службу не запускает.
rm -rf "$ETC" "$STATE"; : > "$LOG"
ENV_EXTRA="LABOPS_OPENAI_MODEL=gpt-test-1 LOGIN_FAIL=1" OUT="$(run_install 2>&1)" \
  && fail "установка прошла без входа в ChatGPT"
echo "$OUT" | grep -q "вход в ChatGPT не завершён" || fail "нет сообщения про незавершённый вход"
grep -q "systemctl restart" "$LOG" && fail "служба запущена без входа"

# 5b. Вход «прошёл», но токенов нет - тоже провал.
rm -rf "$ETC" "$STATE"
ENV_EXTRA="LABOPS_OPENAI_MODEL=gpt-test-1 LOGIN_NO_FILE=1" OUT="$(run_install 2>&1)" \
  && fail "установка прошла без файла токенов"
echo "$OUT" | grep -q "нет файла токенов" || fail "нет сообщения про отсутствие токенов"

# 5c. Адаптер не поднялся - установка честно падает.
rm -rf "$ETC" "$STATE"; : > "$HEALTH"
ENV_EXTRA="LABOPS_OPENAI_MODEL=gpt-test-1" OUT="$(run_install 2>&1)" \
  && fail "установка прошла, хотя адаптер не отвечает"
echo "$OUT" | grep -q "не ответил" || fail "нет сообщения про неответивший адаптер"
echo up > "$HEALTH"

# 6. Нет lock-файла - адаптер не ставится (без хэшей зависимости не ставим).
EMPTY="$TMP/empty-src"; mkdir -p "$EMPTY"
OUT="$(env -i PATH="$BIN" HOME="$HOME_A" SUDO="$BIN/fakesudo" LABOPS_OPENAI_MODEL=m \
    LABOPS_LLM_SRC="$EMPTY" bash -c '
      ok() { :; }; warn() { echo "WARN $*"; }; note() { :; }
      . "'"$HERE"'/openai-adapter-install.sh"; openai_adapter_install x /tmp' 2>&1)" \
  && fail "установка прошла без lock-файла"
echo "$OUT" | grep -q "requirements.lock" || fail "нет объяснения про lock-файл"

echo "OK: openai-adapter-install.sh - все проверки пройдены"
