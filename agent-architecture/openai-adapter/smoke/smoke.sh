#!/usr/bin/env bash
# Смоук-тест цепочки Claude Code -> LiteLLM (провайдер chatgpt/) -> «ChatGPT» БЕЗ подписки.
# Поднимает заглушку Responses API (mock_openai.py) вместо бэкенда ChatGPT и LiteLLM по
# настоящему config-шаблону с подставными токенами входа (auth.json), затем гоняет настоящий
# Claude Code: запрос -> вызов инструмента Bash -> результат -> ответ.
# Подписка Claude не используется: пустой HOME и подставной токен шлюза.
#
#   bash smoke.sh <путь к litellm> [путь к claude]
#
# Не входит в test.sh: нужны установленные LiteLLM и Claude Code.
set -euo pipefail

LITELLM="${1:?использование: smoke.sh <путь к litellm> [путь к claude]}"
CLAUDE="${2:-$(command -v claude)}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
MOCK_PORT=18081
LLM_PORT=18000
MODEL="gpt-smoke"
KEY="sk-smoke-local-key"
STARTUP_TRIES=60
PIDS=()

cleanup() { for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done; rm -rf "$TMP"; }
trap cleanup EXIT

sed "s|__MODEL__|$MODEL|g" "$HERE/../config.template.yaml" > "$TMP/config.yaml"

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

for ((i = 0; i < STARTUP_TRIES; i++)); do
  curl -fsS -m 2 "http://127.0.0.1:$LLM_PORT/health/liveliness" >/dev/null 2>&1 && break
  sleep 2
done
curl -fsS -m 2 "http://127.0.0.1:$LLM_PORT/health/liveliness" >/dev/null || { echo "FAIL: LiteLLM не поднялся"; tail -5 "$TMP/litellm.log"; exit 1; }

cd "$TMP/work"
OUT="$(env -i PATH="$PATH" HOME="$TMP/home" TERM=dumb \
  ANTHROPIC_BASE_URL="http://127.0.0.1:$LLM_PORT" ANTHROPIC_AUTH_TOKEN="$KEY" \
  CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 DISABLE_TELEMETRY=1 DISABLE_ERROR_REPORTING=1 \
  timeout 120 "$CLAUDE" -p "RUN_TOOL выполни команду" --model "$MODEL" --allowedTools Bash \
  --output-format json 2>/dev/null)"

echo "$OUT" | grep -q '"is_error":false' || { echo "FAIL: Claude Code вернул ошибку: $OUT"; exit 1; }
echo "$OUT" | grep -q 'ГОТОВО: цепочка работает' || { echo "FAIL: нет итогового ответа: ${OUT:0:600}"; tail -15 "$TMP/litellm.log"; cat "$TMP/mock.jsonl"; exit 1; }
[ "$(wc -l < "$TMP/mock.jsonl")" -ge 2 ] || { echo "FAIL: нужно минимум 2 запроса к модели (инструмент и ответ)"; cat "$TMP/mock.jsonl"; exit 1; }
grep -q '"function_call_output"' "$TMP/mock.jsonl" || { echo "FAIL: результат инструмента не дошёл до модели"; exit 1; }
grep -q '"path": "/responses"' "$TMP/mock.jsonl" || { echo "FAIL: запросы ушли не на /responses бэкенда подписки"; exit 1; }
grep -q '"auth": "Bearer fake"' "$TMP/mock.jsonl" || { echo "FAIL: токен входа не передан бэкенду"; exit 1; }
echo "OK: Claude Code -> LiteLLM (chatgpt/) -> Responses API: запрос, вызов Bash, результат, ответ"
