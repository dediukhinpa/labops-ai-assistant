#!/usr/bin/env bash
# Смоук-тест цепочки Claude Code -> LiteLLM (провайдер chatgpt/) -> «ChatGPT» БЕЗ подписки.
# Поднимает заглушку Responses API (mock_openai.py) вместо бэкенда ChatGPT и LiteLLM по
# настоящему config-шаблону с подставными токенами входа (auth.json), затем:
#   1. гоняет юнит-тесты хука (если есть каталог ../tests);
#   2. проверяет SSE-поток /v1/messages на уровне протокола (check_stream.py);
#   3. гоняет настоящий Claude Code по сценариям: запрос -> вызовы Bash -> результаты -> ответ.
# Подписка Claude не используется: пустой HOME и подставной токен шлюза.
#
#   bash smoke.sh <путь к litellm> [путь к claude]
#
# Переменные окружения:
#   SMOKE_MOCK_PORT, SMOKE_LLM_PORT — порты мока и шлюза (по умолчанию 18081 и 18000);
#   SMOKE_MODEL — имя модели (по умолчанию gpt-smoke; мок принимает любое);
#   SMOKE_HOOK — путь к хуку (по умолчанию ../flatten_system.py), для мутационной проверки.
# Не останавливается на первом провале: печатает итог по всем сценариям, код выхода 1,
# если упал хоть один. Не входит в test.sh: нужны установленные LiteLLM и Claude Code.
set -euo pipefail

LITELLM="${1:?использование: smoke.sh <путь к litellm> [путь к claude]}"
CLAUDE="${2:-$(command -v claude)}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${SMOKE_HOOK:-$HERE/../flatten_system.py}"
TMP="$(mktemp -d)"
MOCK_PORT="${SMOKE_MOCK_PORT:-18081}"
LLM_PORT="${SMOKE_LLM_PORT:-18000}"
TOKEN_MOCK_PORT="${SMOKE_TOKEN_MOCK_PORT:-18091}"
TOKEN_LLM_PORT="${SMOKE_TOKEN_LLM_PORT:-18092}"
MODEL="${SMOKE_MODEL:-gpt-smoke}"
KEY="sk-smoke-local-key"
FINAL_TEXT="ГОТОВО: цепочка работает"
STARTUP_TRIES=60
STARTUP_SLEEP=2
CLAUDE_TIMEOUT=180
# Сценарии, которые гоняются через настоящий Claude Code (EMPTY — только поток).
CLAUDE_SCENARIOS=(RUN_TOOL PARALLEL_NODELTA PARALLEL_DELTA MIXED LONG)
MIN_BACKEND_REQUESTS=2
LOG_TAIL=10
PIDS=()
FAILS=0

cleanup() {
  for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done
  rm -rf "$TMP"
}
trap cleanup EXIT

fail() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }
ok() { echo "OK: $*"; }

[ -f "$HOOK" ] || { echo "FAIL: нет файла хука: $HOOK"; exit 1; }
PYBIN="$(dirname "$LITELLM")/python"
[ -x "$PYBIN" ] || PYBIN="python3"

# --- 1. Юнит-тесты хука (их каталог появляется вместе с исправлением хука) ---
TESTS_DIR="$HERE/../tests"
if [ -d "$TESTS_DIR" ]; then
  echo "== юнит-тесты хука =="
  if "$PYBIN" -c 'import pytest' 2>/dev/null; then
    (cd "$HERE/.." && "$PYBIN" -m pytest -q tests) || fail "юнит-тесты хука (pytest)"
  else
    (cd "$HERE/.." && "$PYBIN" -m unittest discover -s tests -t .) \
      || fail "юнит-тесты хука (unittest)"
  fi
else
  echo "SKIP: каталога openai-adapter/tests нет, юнит-тесты хука пропущены"
fi

sed "s|__MODEL__|$MODEL|g" "$HERE/../config.template.yaml" > "$TMP/config.yaml"
cp "$HOOK" "$TMP/flatten_system.py"

# Подставные токены входа: живые на сутки, настоящему бэкенду они не подойдут.
mkdir -p "$TMP/tokens"
python3 -I -c "
import json, sys, time
json.dump({'access_token': 'fake.access.token', 'refresh_token': 'fake-refresh',
           'expires_at': int(time.time()) + 86400, 'account_id': 'acct-smoke'},
          open(sys.argv[1], 'w'))" "$TMP/tokens/auth.json"

python3 "$HERE/mock_openai.py" "$MOCK_PORT" "$TMP/mock.jsonl" & PIDS+=("$!")
mkdir -p "$TMP/home" "$TMP/work"
LITELLM_MASTER_KEY="$KEY" LITELLM_LOCAL_MODEL_COST_MAP=True HOME="$TMP/home" \
  CHATGPT_TOKEN_DIR="$TMP/tokens" CHATGPT_API_BASE="http://127.0.0.1:$MOCK_PORT" \
  "$LITELLM" --config "$TMP/config.yaml" --host 127.0.0.1 --port "$LLM_PORT" \
  >"$TMP/litellm.log" 2>&1 & PIDS+=("$!")

LIVE_URL="http://127.0.0.1:$LLM_PORT/health/liveliness"
for ((i = 0; i < STARTUP_TRIES; i++)); do
  curl -fsS -m 2 "$LIVE_URL" >/dev/null 2>&1 && break
  sleep "$STARTUP_SLEEP"
done
if ! curl -fsS -m 2 "$LIVE_URL" >/dev/null; then
  echo "FAIL: LiteLLM не поднялся"
  tail -5 "$TMP/litellm.log"
  exit 1
fi

# --- 2. Поток /v1/messages на уровне протокола ---
echo "== поток SSE (протокол) =="
"$PYBIN" "$HERE/check_stream.py" "http://127.0.0.1:$LLM_PORT" "$KEY" \
  || FAILS=$((FAILS + 1))
: > "$TMP/mock.jsonl"  # запросы проверки потока не нужны сценариям Claude Code

# --- 3. Настоящий Claude Code ---
# Прогон одного сценария: ключевое слово в промпте выбирает ответ мока.
run_claude_scenario() {
  local name="$1" start out log marker bad=0
  start="$(wc -l < "$TMP/mock.jsonl")"
  out="$(cd "$TMP/work" && env -i PATH="$PATH" HOME="$TMP/home" TERM=dumb \
    ANTHROPIC_BASE_URL="http://127.0.0.1:$LLM_PORT" ANTHROPIC_AUTH_TOKEN="$KEY" \
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 DISABLE_TELEMETRY=1 DISABLE_ERROR_REPORTING=1 \
    timeout "$CLAUDE_TIMEOUT" "$CLAUDE" -p "$name выполни команду" --model "$MODEL" \
    --allowedTools Bash --output-format json 2>/dev/null)" || true
  log="$TMP/mock.$name.jsonl"
  tail -n "+$((start + 1))" "$TMP/mock.jsonl" > "$log"

  if ! echo "$out" | grep -q '"is_error":false'; then
    fail "сценарий $name: Claude Code вернул ошибку: ${out:0:300}"; return
  fi
  echo "$out" | grep -q "$FINAL_TEXT" \
    || { fail "сценарий $name: нет итогового ответа: ${out:0:300}"; return; }
  if [ "$(wc -l < "$log")" -lt "$MIN_BACKEND_REQUESTS" ]; then
    fail "сценарий $name: нужно минимум $MIN_BACKEND_REQUESTS запроса к модели"; return
  fi
  grep -q '"function_call_output"' "$log" \
    || { fail "сценарий $name: результат инструмента не дошёл до модели"; return; }
  grep -q '"path": "/responses"' "$log" \
    || { fail "сценарий $name: запросы ушли не на /responses бэкенда подписки"; return; }
  grep -q '"auth": "Bearer fake"' "$log" \
    || { fail "сценарий $name: токен входа не передан бэкенду"; return; }
  if grep -q 'InputValidationError' "$log" || echo "$out" | grep -q 'InputValidationError'; then
    fail "сценарий $name: InputValidationError (инструмент вызван с пустым input)"; bad=1
  fi
  while IFS= read -r marker; do
    [ -n "$marker" ] || continue
    grep -qF -- "$marker" "$log" \
      || { fail "сценарий $name: в результатах Bash нет «$marker» (команда не выполнена)"; bad=1; }
  done < <(python3 "$HERE/mock_openai.py" --markers "$name")
  [ "$bad" -eq 0 ] && ok "Claude Code, сценарий $name: вызовы Bash выполнены, ответ получен"
  return 0
}

echo "== обновление токена (401 token_expired -> обмен refresh_token) =="
TOK_DIR="$TMP/tok-refresh"; mkdir -p "$TOK_DIR"
python3 -I -c "
import base64, json, sys, time
enc = lambda o: base64.urlsafe_b64encode(json.dumps(o).encode()).decode().rstrip('=')
t = '.'.join([enc({'alg': 'none'}), enc({'iat': int(time.time()) - 3600, 'exp': int(time.time()) + 864000}), 's'])
json.dump({'access_token': t, 'refresh_token': 'r1', 'id_token': t,
           'expires_at': int(time.time()) + 864000, 'account_id': 'a'}, open(sys.argv[1], 'w'))" "$TOK_DIR/auth.json"
python3 "$HERE/mock_token_server.py" "$TOKEN_MOCK_PORT" "$TMP/token-mock.log" & PIDS+=("$!")
sed "s|__MODEL__|$MODEL|g" "$HERE/../config.template.yaml" > "$TMP/config-token.yaml"
SMOKE_OAUTH_URL="http://127.0.0.1:$TOKEN_MOCK_PORT/oauth/token" PYTHONPATH="$HERE/site" \
  LITELLM_MASTER_KEY="$KEY" LITELLM_LOCAL_MODEL_COST_MAP=True HOME="$TMP/home" \
  CHATGPT_TOKEN_DIR="$TOK_DIR" CHATGPT_API_BASE="http://127.0.0.1:$TOKEN_MOCK_PORT" \
  "$LITELLM" --config "$TMP/config-token.yaml" --host 127.0.0.1 --port "$TOKEN_LLM_PORT" \
  >"$TMP/litellm-token.log" 2>&1 & PIDS+=("$!")
for ((i = 0; i < STARTUP_TRIES; i++)); do
  curl -fsS -m 2 "http://127.0.0.1:$TOKEN_LLM_PORT/health/liveliness" >/dev/null 2>&1 && break
  sleep "$STARTUP_SLEEP"
done
token_req() {
  curl -s -m 60 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$TOKEN_LLM_PORT/v1/messages" \
    -H "x-api-key: $KEY" -H 'anthropic-version: 2023-06-01' -H 'content-type: application/json' \
    -d "{\"model\":\"$MODEL\",\"max_tokens\":20,\"stream\":true,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}"
}
FIRST="$(token_req)"; SECOND="$(token_req)"
[ "$FIRST" = "401" ] || fail "обновление токена: первый запрос должен получить 401, получил $FIRST"
[ "$SECOND" = "200" ] || fail "обновление токена: после обмена refresh_token запрос должен пройти (200), получил $SECOND"
[ "$(grep -c 'oauth refresh' "$TMP/token-mock.log")" = "1" ] \
  || fail "обновление токена: ожидался ровно один обмен refresh_token"
[ "$FIRST $SECOND" = "401 200" ] && ok "токен отвергнут сервером (401) -> хук обновил его -> следующий запрос прошёл"

echo "== Claude Code =="
for scenario in "${CLAUDE_SCENARIOS[@]}"; do
  run_claude_scenario "$scenario"
done

echo "== итог =="
if [ "$FAILS" -gt 0 ]; then
  echo "FAIL: провалено проверок: $FAILS"
  echo "--- строки хука в логе LiteLLM (патч установлен или нет) ---"
  grep -i 'flatten_system' "$TMP/litellm.log" | tail -n "$LOG_TAIL" || true
  exit 1
fi
echo "OK: Claude Code -> LiteLLM (chatgpt/) -> Responses API: все сценарии прошли"
