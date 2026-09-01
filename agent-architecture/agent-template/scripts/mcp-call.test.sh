#!/usr/bin/env bash
# mcp-call.test.sh -- юнит-тест рукопожатия MCP на подменённом curl.
#
# Регрессия, которую он держит: хуки слали одиночный tools/call без initialize,
# FastMCP отвечал "Missing session ID", и сброс памяти в общий мозг молча не
# доходил (fail-open прятал отказ в одну строку лога).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pass=0; fail=0
ok()  { echo "✓ $*"; pass=$((pass+1)); }
bad() { echo "✗ $*"; fail=$((fail+1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
CALLS="$WORK/calls.log"

# Подменяем curl: пишет аргументы в лог, отдаёт сессию в заголовках и тело.
mk_curl() {   # mk_curl <выдавать-ли-session-id>
    cat > "$WORK/curl" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$CALLS"
hdr=""
prev=""
for a in "\$@"; do
  [ "\$prev" = "-D" ] && hdr="\$a"
  prev="\$a"
done
if [ -n "\$hdr" ]; then
  printf 'HTTP/1.1 200 OK\r\n' > "\$hdr"
  [ "$1" = "yes" ] && printf 'mcp-session-id: sess-123\r\n' >> "\$hdr"
  printf '\r\n' >> "\$hdr"
fi
echo '{"jsonrpc":"2.0","id":2,"result":{"isError":false}}'
EOF
    chmod +x "$WORK/curl"
}

run_call() {
    PATH="$WORK:$PATH" bash -c ". '$HERE/mcp-call.sh'; mcp_tools_call http://x/mcp tok '{\"id\":2}'"
}

# ---- сервер выдал сессию: полный цикл ---------------------------------------
mk_curl yes; : > "$CALLS"
out="$(run_call)"; rc=$?
[ $rc -eq 0 ] && ok "вызов успешен, когда сервер выдал сессию" \
              || bad "вызов провалился при живой сессии (rc=$rc)"
printf '%s' "$out" | grep -q '"isError":false' \
    && ok "тело ответа возвращается вызывающей стороне" \
    || bad "тело ответа потеряно: $out"
grep -q 'initialize' "$CALLS" && ok "рукопожатие: initialize отправлен" \
                              || bad "initialize не отправлен"
grep -q 'notifications/initialized' "$CALLS" \
    && ok "рукопожатие: notifications/initialized отправлен" \
    || bad "notifications/initialized не отправлен"
# Считаем вхождения, а не строки: аргумент с заголовком попадает в лог вместе
# с переносами из тела запроса, и построчный подсчёт их не видит.
if [ "$(tr -s '[:space:]' ' ' < "$CALLS" | grep -o 'mcp-session-id: sess-123' | wc -l)" -ge 2 ]; then
    ok "session-id проброшен и в уведомление, и в сам вызов"
else
    bad "session-id не проброшен во все запросы"
fi

# ---- сессия закрывается: иначе сервер копит брошенные сессии ------------------
# Регрессия 2026-09-01: без DELETE memory_router рос на 56 КБ за сессию, поллер
# открывал по сессии каждые 5 секунд, и сервис выел весь swap хоста.
if grep -q 'DELETE' "$CALLS"; then
    ok "сессия закрывается (DELETE отправлен)"
else
    bad "сессия не закрывается — сервер будет копить брошенные сессии"
fi
if [ "$(tr -s '[:space:]' ' ' < "$CALLS" | grep -o 'X DELETE' | wc -l)" -eq 1 ]; then
    ok "DELETE ровно один на вызов"
else
    bad "DELETE отправлен не один раз"
fi

# ---- сервер не выдал сессию: не притворяемся успехом -------------------------
mk_curl no; : > "$CALLS"
run_call >/dev/null 2>&1
[ $? -ne 0 ] && ok "без session-id возвращается ошибка, а не мнимый успех" \
             || bad "без session-id вызов доложил об успехе"
grep -q '"id":2' "$CALLS" \
    && bad "сам tools/call отправлен без сессии (тот самый баг)" \
    || ok "tools/call не отправляется без сессии"

echo
echo "passed=$pass failed=$fail"
[ $fail -eq 0 ]
