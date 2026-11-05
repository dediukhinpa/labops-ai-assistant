#!/usr/bin/env bash
# Смоук-тест цепочки Claude Code -> LiteLLM -> «OpenAI» БЕЗ ключа и денег.
# Поднимает заглушку Responses API (mock_openai.py) и LiteLLM по настоящему config-шаблону,
# затем гоняет настоящий Claude Code: запрос -> вызов инструмента Bash -> результат -> ответ.
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

sed "s|__MODEL__|$MODEL|g" "$HERE/../config.template.yaml" \
  | sed "s|api_key: os.environ/OPENAI_API_KEY|api_key: sk-mock-upstream\n      api_base: http://127.0.0.1:$MOCK_PORT/v1|" \
  > "$TMP/config.yaml"

python3 "$HERE/mock_openai.py" "$MOCK_PORT" "$TMP/mock.jsonl" & PIDS+=("$!")
mkdir -p "$TMP/home" "$TMP/work"
LITELLM_MASTER_KEY="$KEY" LITELLM_LOCAL_MODEL_COST_MAP=True HOME="$TMP/home" \
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
echo "$OUT" | grep -q 'ГОТОВО: цепочка работает' || { echo "FAIL: нет итогового ответа"; exit 1; }
[ "$(wc -l < "$TMP/mock.jsonl")" -ge 2 ] || { echo "FAIL: нужно минимум 2 запроса к модели (инструмент и ответ)"; exit 1; }
grep -q '"function_call_output"' "$TMP/mock.jsonl" || { echo "FAIL: результат инструмента не дошёл до модели"; exit 1; }
echo "OK: Claude Code -> LiteLLM -> Responses API: запрос, вызов Bash, результат, ответ"
