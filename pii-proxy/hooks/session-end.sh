#!/usr/bin/env bash
# Хук SessionEnd: удаляет тред сессии в сервисе псевдонимизации.
# Вход: JSON хука в stdin (поле session_id). Ошибки хук не роняют: всегда exit 0.
# Окружение: PSEUDONYMIZER_URL, AGENT_ID, PSEUDONYMIZER_TOKEN_FILE (файл с Bearer-токеном).
set -euo pipefail

# Зачем exit 0 всегда: сбой очистки не должен ломать завершение сессии; тред и так
# удаляется сервисом по сроку хранения.
warn() { echo "pii-proxy session-end: $*" >&2; }

main() {
  local payload session_id token url
  payload="$(cat)"
  session_id="$(printf '%s' "$payload" | python3 -c \
    'import json,sys; print(json.load(sys.stdin).get("session_id",""))')" || session_id=""
  if [[ -z "$session_id" ]]; then warn "нет session_id во входных данных"; return 0; fi
  if [[ "$session_id" == */* ]]; then warn "session_id содержит «/»"; return 0; fi
  if [[ -z "${AGENT_ID:-}" || -z "${PSEUDONYMIZER_URL:-}" ]]; then
    warn "не заданы AGENT_ID или PSEUDONYMIZER_URL"; return 0
  fi
  if [[ ! -r "${PSEUDONYMIZER_TOKEN_FILE:-}" ]]; then warn "файл токена недоступен"; return 0; fi
  token="$(tr -d '\n' < "$PSEUDONYMIZER_TOKEN_FILE")"
  # Токен передаётся через stdin curl (-K -), чтобы не попасть в список процессов.
  url="${PSEUDONYMIZER_URL%/}/threads/${AGENT_ID}:${session_id}"
  if ! printf 'header = "Authorization: Bearer %s"\n' "$token" \
    | curl -sS -X DELETE --max-time 5 -o /dev/null -w '' --fail -K - "$url" 2>/dev/null; then
    warn "не удалось удалить тред"
  fi
  return 0
}

main || warn "неожиданная ошибка"
exit 0
