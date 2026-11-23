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

# Общий вход роя в ChatGPT: один `codex login` на всех агентов. В CODEX_HOME каждого агента
# auth.json и оба файла блокировки — ссылки сюда. Проверено на codex 0.171.0: обновлённый
# токен пишется сквозь ссылку, перед обновлением codex перечитывает файл с диска, а общие
# lock-файлы не дают двум агентам обновлять токен одновременно.
CODEX_SHARED_AUTH_FILES="auth.json auth.json.lock auth.lock"
codex_shared_home() {
  printf '%s/shared/codex' "${CLAUDE_LAB:-$HOME/.claude-lab}"
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

# Сколько ждать, пока драйвер сам выйдет после SIGTERM/SIGHUP: перед выходом он сбрасывает
# память в общий мозг (brain-flush), его дедлайн остановки — 30 с (SHUTDOWN_DEADLINE_MS в
# плагине), плюс запас. Переопределяется CODEX_STOP_WAIT (как в start-agent.sh).
CODEX_STOP_WAIT_DEFAULT_SEC=35

# codex_stop_driver <agent> [webhook-port] — штатно остановить драйвер: SIGTERM, ожидание
# brain-flush, и только потом SIGKILL; затем добить app-server агента по порту.
# Печатает none | graceful | killed.
codex_stop_driver() {
  local agent="$1" port="${2:-}" wait="${CODEX_STOP_WAIT:-$CODEX_STOP_WAIT_DEFAULT_SEC}" i result
  if [ -z "$(codex_driver_pid "$agent")" ]; then
    result=none
  else
    pkill -TERM -f "$(codex_driver_pattern "$agent")" 2>/dev/null || true
    for ((i = 0; i < wait; i++)); do
      [ -z "$(codex_driver_pid "$agent")" ] && break
      sleep 1
    done
    if [ -z "$(codex_driver_pid "$agent")" ]; then
      result=graceful
    else
      pkill -9 -f "$(codex_driver_pattern "$agent")" 2>/dev/null || true
      result=killed
    fi
  fi
  if [ -n "$port" ]; then
    pkill -9 -f "$(codex_appserver_pattern "$port")" 2>/dev/null || true
  fi
  printf '%s\n' "$result"
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
  codex_auth_state_home "$(codex_home_of "$1")"
}

# codex_auth_state_home <codex-home> — то же для произвольного CODEX_HOME (общий вход роя).
codex_auth_state_home() {
  local bin out rc=0
  bin="$(codex_bin)" || { echo unknown; return 0; }
  out="$(CODEX_HOME="$1" timeout 20 "$bin" login status 2>&1)" || rc=$?
  case "$out" in
    *"Logged in using ChatGPT"*) echo chatgpt ;;
    *"API key"*|*"api key"*) echo apikey ;;
    *"Not logged in"*) echo none ;;
    *) if [ "$rc" -ne 0 ]; then echo none; else echo unknown; fi ;;
  esac
  return 0
}

# Текст оператору, когда входа нет: что сделать руками (код подтверждения — в браузере).
# Вход общий на рой, поэтому и команда одна для любого агента.
codex_login_hint() {   # [agent] — не используется, оставлен для единообразия вызовов
  printf 'войдите в ChatGPT (один вход на весь рой): CODEX_HOME=%s codex login --device-auth' "$(codex_shared_home)"
}

# codex_link_shared_auth <agent> — сделать вход агента ссылками на общий вход роя.
# Свой auth.json агента (вошли раньше вручную) переносится в общий, если общего ещё нет, иначе
# откладывается в auth.json.bak-<время>: два разных входа в одном рое не нужны.
codex_link_shared_auth() {
  local home shared f stamp
  home="$(codex_home_of "$1")"
  shared="$(codex_shared_home)"
  mkdir -p "$home" "$shared" || return 1
  chmod 700 "$shared" 2>/dev/null || true
  stamp="$(date +%Y%m%d%H%M%S)"
  for f in $CODEX_SHARED_AUTH_FILES; do
    if [ -f "$home/$f" ] && [ ! -L "$home/$f" ]; then
      if [ "$f" = "auth.json" ] && [ ! -e "$shared/$f" ]; then
        mv "$home/$f" "$shared/$f" || return 1
      else
        mv "$home/$f" "$home/$f.bak-$stamp" || return 1
      fi
    fi
    if [ "$f" != "auth.json" ] && [ ! -e "$shared/$f" ]; then
      ( umask 077; : > "$shared/$f" ) || return 1
    fi
    ln -sfn "$shared/$f" "$home/$f" || return 1
  done
  [ ! -e "$shared/auth.json" ] || chmod 600 "$shared/auth.json"
  return 0
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
