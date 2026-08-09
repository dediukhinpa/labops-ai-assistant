#!/usr/bin/env bash
# doctor-request.test.sh — очередь запросов /doctor и аварийный приём команды.
#
# Проверяется главное свойство: запрос исполняется РОВНО один раз, а команда,
# принятая напрямую из Telegram, не повторяется бесконечно — offset=-1 всегда
# отдаёт один и тот же последний апдейт, поэтому без учёта update_id watchdog
# лечил бы агента по кругу.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export CLAUDE_LAB="$TMP/lab"
. "$HERE/doctor-request.sh"

pass=0; fail=0
ok()  { echo "✓ $*"; pass=$((pass+1)); }
bad() { echo "✗ $*"; fail=$((fail+1)); }

# ── Очередь ──────────────────────────────────────────────────────────────────
doctor_request_pending dev && bad "пустая очередь считается непустой" || ok "пустая очередь: запроса нет"

doctor_request_put dev 12345 && ok "запрос кладётся" || bad "запрос не положился"
doctor_request_pending dev && ok "запрос виден" || bad "положенный запрос не виден"

got="$(doctor_request_take dev)" && rc=0 || rc=$?
if [ "$rc" -eq 0 ] && [ "$got" = "12345" ]; then
  ok "запрос забирается вместе с chat_id"
else
  bad "запрос забрался неверно (rc=$rc, chat=«$got»)"
fi

doctor_request_take dev >/dev/null 2>&1 && bad "один запрос забрали дважды" \
  || ok "повторный забор невозможен (запрос исполняется один раз)"

doctor_request_put dev "" && [ "$(doctor_request_take dev)" = "" ] \
  && ok "запрос без chat_id допустим" || bad "запрос без chat_id сломался"

# ── Аварийный приём из Telegram ──────────────────────────────────────────────
# Подменяем и curl (ответ Telegram), и сеть целиком — тест не ходит наружу.
MOCKS="$TMP/bin"; mkdir -p "$MOCKS"
cat > "$MOCKS/curl" <<'EOF'
#!/usr/bin/env bash
cat "${MOCK_TG_RESPONSE:-/dev/null}"
EOF
chmod +x "$MOCKS/curl"
export PATH="$MOCKS:$PATH"

mk_update() {   # <update_id> <text> <возраст в секундах>
  local now; now="$(date +%s)"
  cat > "$TMP/resp.json" <<EOF
{"ok":true,"result":[{"update_id":$1,"message":{"message_id":7,"date":$((now - $3)),
"chat":{"id":124546645,"type":"private"},"text":"$2"}}]}
EOF
  printf '%s' "$TMP/resp.json"
}

export MOCK_TG_RESPONSE

MOCK_TG_RESPONSE="$(mk_update 100 "/doctor" 5)"
if doctor_poll_telegram tg TOKEN && [ "$(doctor_request_take tg)" = "124546645" ]; then
  ok "свежая команда /doctor принимается, chat_id извлекается"
else
  bad "свежая /doctor не принята"
fi

# Тот же апдейт ещё раз: offset=-1 отдаёт последний вечно — второй раз лечить нельзя.
if doctor_poll_telegram tg TOKEN; then
  bad "та же команда принята повторно — watchdog лечил бы агента по кругу"
else
  ok "повторный тот же апдейт игнорируется (учёт update_id)"
fi

MOCK_TG_RESPONSE="$(mk_update 101 "/doctor@christopher_coderbot" 5)"
doctor_poll_telegram tg TOKEN && ok "команда с @упоминанием бота принимается" \
  || bad "/doctor@bot не распознан"
doctor_request_take tg >/dev/null 2>&1 || true

MOCK_TG_RESPONSE="$(mk_update 102 "/doctor" 4000)"
if doctor_poll_telegram tg TOKEN; then
  bad "исполнена протухшая команда — после простоя агент лечился бы на ровном месте"
else
  ok "протухшая команда игнорируется"
fi

MOCK_TG_RESPONSE="$(mk_update 103 "привет" 5)"
doctor_poll_telegram tg TOKEN && bad "обычный текст принят за команду" \
  || ok "обычное сообщение командой не считается"

MOCK_TG_RESPONSE="$(mk_update 104 "/status" 5)"
doctor_poll_telegram tg TOKEN && bad "чужая команда принята за /doctor" \
  || ok "чужая слэш-команда не срабатывает"

# Неотвечающий Telegram не должен ронять вызывающий демон (тот идёт под set -e).
printf '' > "$TMP/empty.json"
MOCK_TG_RESPONSE="$TMP/empty.json"
doctor_poll_telegram tg TOKEN && bad "пустой ответ принят за команду" \
  || ok "пустой ответ Telegram безвреден"

printf 'not json at all' > "$TMP/garbage.json"
MOCK_TG_RESPONSE="$TMP/garbage.json"
doctor_poll_telegram tg TOKEN && bad "мусор принят за команду" \
  || ok "нечитаемый ответ Telegram безвреден"

# Под `set -e` ни одна ветка не должна убивать вызывающего.
if ( set -euo pipefail; . "$HERE/doctor-request.sh"
     MOCK_TG_RESPONSE="$TMP/garbage.json" doctor_poll_telegram tg TOKEN || true
     doctor_request_pending nobody || true
     doctor_request_take nobody || true
     exit 0 ); then
  ok "библиотека не роняет демон под set -e"
else
  bad "под set -e библиотека убивает вызывающий демон"
fi

echo
echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
