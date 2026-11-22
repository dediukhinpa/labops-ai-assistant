#!/usr/bin/env bash
# Юнит-тесты lib/codex-watch.sh: состояние входа Codex, heartbeat, пути и шаблоны процессов.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export CLAUDE_LAB="$TMP/lab"
# shellcheck source=codex-watch.sh
. "$HERE/codex-watch.sh"

pass=0; fail=0
eq() { if [ "$1" = "$2" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $3 (got '$1', want '$2')"; fi; }

# Поддельный codex: отвечает на `login status` текстом из FAKE_LOGIN и кодом FAKE_RC; пишет,
# с каким CODEX_HOME его позвали.
cat > "$TMP/codex" <<'EOF'
#!/usr/bin/env bash
[ "$1 $2" = "login status" ] || exit 2
printf '%s' "$CODEX_HOME" > "$FAKE_HOME_LOG"
echo "WARNING: something noisy"
echo "$FAKE_LOGIN"
exit "${FAKE_RC:-0}"
EOF
chmod +x "$TMP/codex"
export CODEX_BIN="$TMP/codex" FAKE_HOME_LOG="$TMP/home.log"

eq "$(codex_home_of dev)" "$TMP/lab/dev/.codex" "CODEX_HOME агента"
eq "$(codex_bin)" "$TMP/codex" "CODEX_BIN главнее PATH"

FAKE_LOGIN="Logged in using ChatGPT" eq "$(FAKE_LOGIN="Logged in using ChatGPT" codex_auth_state dev)" chatgpt "вход по подписке"
eq "$(cat "$TMP/home.log")" "$TMP/lab/dev/.codex" "login status зовётся с CODEX_HOME агента"
eq "$(FAKE_LOGIN="Logged in using an API key - sk-***" codex_auth_state dev)" apikey "вход по ключу API"
eq "$(FAKE_LOGIN="Not logged in" FAKE_RC=1 codex_auth_state dev)" none "входа нет"
eq "$(FAKE_LOGIN="???" FAKE_RC=0 codex_auth_state dev)" unknown "непонятный ответ — не тревога"
eq "$(PATH=/nonexistent HOME="$TMP" CODEX_BIN="$TMP/missing" codex_auth_state dev)" "unknown" "бинаря нет — не тревога о входе"
case "$(codex_login_hint dev)" in *"CODEX_HOME=$TMP/lab/shared/codex codex login --device-auth"*) pass=$((pass + 1)) ;; *) fail=$((fail + 1)); echo "FAIL: подсказка входа" ;; esac
eq "$(FAKE_LOGIN="Logged in using ChatGPT" codex_auth_state_home "$TMP/lab/shared/codex")" chatgpt "вход по общему CODEX_HOME"
eq "$(cat "$TMP/home.log")" "$TMP/lab/shared/codex" "общий вход проверяется в общем каталоге"

# Общий вход: ссылки на auth.json и lock-файлы; свой вход агента переезжает в общий.
mkdir -p "$TMP/lab/a1/.codex" "$TMP/lab/a2/.codex"
echo '{"own":1}' > "$TMP/lab/a1/.codex/auth.json"
codex_link_shared_auth a1; eq "$?" 0 "ссылки агента a1"
eq "$(readlink "$TMP/lab/a1/.codex/auth.json")" "$TMP/lab/shared/codex/auth.json" "auth.json — ссылка на общий"
eq "$(cat "$TMP/lab/shared/codex/auth.json")" '{"own":1}' "свой вход a1 стал общим"
eq "$(stat -c %a "$TMP/lab/shared/codex/auth.json")" 600 "общий auth.json 600"
eq "$(stat -c %a "$TMP/lab/shared/codex")" 700 "общий каталог 700"
[ -f "$TMP/lab/shared/codex/auth.lock" ] && [ -L "$TMP/lab/a1/.codex/auth.json.lock" ]; eq "$?" 0 "lock-файлы общие"
echo '{"other":1}' > "$TMP/lab/a2/.codex/auth.json"
codex_link_shared_auth a2
eq "$(cat "$TMP/lab/a2/.codex/auth.json")" '{"own":1}' "второй агент видит общий вход"
eq "$(ls "$TMP/lab/a2/.codex" | grep -c '^auth.json.bak-')" 1 "чужой вход a2 отложен в .bak"
codex_link_shared_auth a2; eq "$?" 0 "повторный вызов идемпотентен"
eq "$(ls "$TMP/lab/a2/.codex" | grep -c '^auth.json.bak-')" 1 "повтор ничего не откладывает"

HB="$TMP/hb"
codex_heartbeat_stale "$HB" 60; eq "$?" 0 "нет heartbeat = устарел"
date +%s > "$HB"
codex_heartbeat_stale "$HB" 60; eq "$?" 1 "свежий heartbeat"
echo $(( $(date +%s) - 120 )) > "$HB"
codex_heartbeat_stale "$HB" 60; eq "$?" 0 "старый heartbeat"
echo "мусор" > "$HB"
codex_heartbeat_stale "$HB" 60; eq "$?" 0 "нечисловой heartbeat = устарел"

# Шаблоны процессов: драйвер этого агента, а не соседа; app-server по порту агента.
eq "$(printf '%s' "$TMP/lab/dev/.claude/labops-tg-plugin/plugin/src/server.ts" | grep -cE "$(codex_driver_pattern dev)")" 1 "драйвер агента"
eq "$(printf '%s' "$TMP/lab/devops/.claude/labops-tg-plugin/plugin/src/server.ts" | grep -cE "$(codex_driver_pattern dev)")" 0 "драйвер соседа не задет"
eq "$(printf '%s' '/x/codex app-server -c mcp_servers.labops-channel.url="http://127.0.0.1:6003/mcp"' | grep -cE "$(codex_appserver_pattern 6003)")" 1 "app-server по порту"
eq "$(printf '%s' '/x/codex app-server -c mcp_servers.labops-channel.url="http://127.0.0.1:60031/mcp"' | grep -cE "$(codex_appserver_pattern 6003)")" 0 "чужой порт не задет"

echo "codex-watch.test.sh: $pass ok, $fail fail"
[ "$fail" -eq 0 ]
