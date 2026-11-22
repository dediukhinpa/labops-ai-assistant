#!/usr/bin/env bash
# lib/codex-watch.sh — проверки агента на харнесе Codex для watchdog и start-agent.
#
# У Codex в tmux-сессии агента работает не TUI, а плагин-драйвер (bun src/server.ts в режиме
# LABOPS_HARNESS=codex), который сам держит codex app-server. Экран разбирать не нужно:
#   * жив ли агент — процесс драйвера и его webhook-порт;
#   * не завис ли — heartbeat: драйвер пишет его на каждом событии нити и раз в минуту в
#     простое, так что старый heartbeat при живом процессе = зависший драйвер;
#   * есть ли вход — `codex login status` с CODEX_HOME агента: нужен вход через ChatGPT
#     (подписка), API-ключ не подходит.
#
# Функции без побочных эффектов, кроме чтения; решения принимает watchdog.

# Каталог CODEX_HOME агента.
codex_home_of() {   # <agent>
  printf '%s/%s/.codex' "${CLAUDE_LAB:-$HOME/.claude-lab}" "$1"
}

# Путь к бинарю codex: CODEX_BIN, затем закреплённая установщиком копия, затем PATH.
codex_bin() {
  if [ -n "${CODEX_BIN:-}" ] && [ -x "$CODEX_BIN" ]; then printf '%s\n' "$CODEX_BIN"; return 0; fi
  if [ -x "$HOME/.local/bin/codex" ]; then printf '%s\n' "$HOME/.local/bin/codex"; return 0; fi
  command -v codex 2>/dev/null || return 1
}

# Шаблон командной строки драйвера агента (для pgrep/pkill).
codex_driver_pattern() {   # <agent>
  printf '%s/%s/\\.claude/.*/plugin/src/server\\.ts' "${CLAUDE_LAB:-$HOME/.claude-lab}" "$1"
}

# PID драйвера агента или пусто.
codex_driver_pid() {   # <agent>
  pgrep -f "$(codex_driver_pattern "$1")" 2>/dev/null | head -1
}

# Шаблон app-server агента: его отличает адрес MCP канала с портом агента.
codex_appserver_pattern() {   # <webhook-port>
  printf 'codex.*app-server.*127\\.0\\.0\\.1:%s/mcp' "$1"
}

# codex_auth_state <agent> — печатает chatgpt | apikey | none | unknown.
#   chatgpt — вход по подписке (то, что нужно);
#   apikey  — вход по ключу API (не наш режим: оплата не из подписки);
#   none    — входа нет;
#   unknown — codex не найден или ответил непонятно (не повод тревожить оператора).
codex_auth_state() {
  local bin out rc=0
  bin="$(codex_bin)" || { echo unknown; return 0; }
  out="$(CODEX_HOME="$(codex_home_of "$1")" timeout 20 "$bin" login status 2>&1)" || rc=$?
  case "$out" in
    *"Logged in using ChatGPT"*) echo chatgpt ;;
    *"API key"*|*"api key"*) echo apikey ;;
    *"Not logged in"*) echo none ;;
    *) if [ "$rc" -ne 0 ]; then echo none; else echo unknown; fi ;;
  esac
  return 0
}

# Текст оператору, когда входа нет: что сделать руками (код подтверждения — в браузере).
codex_login_hint() {   # <agent>
  printf 'войдите в ChatGPT для агента: CODEX_HOME=%s codex login --device-auth' "$(codex_home_of "$1")"
}

# codex_heartbeat_stale <heartbeat-file> <max-age-sec> — heartbeat старше предела или нет.
codex_heartbeat_stale() {
  local hb now
  [ -f "$1" ] || return 0
  hb="$(cat "$1" 2>/dev/null || echo '')"
  case "$hb" in ''|*[!0-9]*) return 0 ;; esac
  now="$(date +%s)"
  [ "$((now - hb))" -gt "$2" ]
}
