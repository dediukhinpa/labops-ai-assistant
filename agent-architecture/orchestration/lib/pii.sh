#!/usr/bin/env bash
# pii.sh — общие функции псевдонимизации (pii-proxy) для установки и watchdog.
# SOURCE this file. Ничего не запускает при сорсинге.
#
# Модель: у агента есть свой pii-proxy на 127.0.0.1:<порт>. Агент ходит в модель только через
# него (ANTHROPIC_BASE_URL в settings.json). «Есть ли у агента прокси» определяется ровно по
# этому ключу: настройка, которую читает сам claude, не может разойтись с проверкой watchdog.

_PII_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v list_agents >/dev/null 2>&1 || . "$_PII_LIB_DIR/agents.sh"

# Диапазон портов прокси: 6300 + индекс агента в ростере. Webhook-порты плагина - 6000+,
# listener - 6100/6101, поэтому 6300-6399 с ними не пересекается.
PII_PROXY_BASE_PORT="${PII_PROXY_BASE_PORT:-6300}"
# Сколько подряд портов перебираем в поисках свободного (граница диапазона).
PII_PROXY_PORT_SPAN=100
# Порт и адрес общего на хост сервиса псевдонимизации.
PII_PSEUDONYMIZER_URL_DEFAULT="http://127.0.0.1:8300"
# Таймаут проверки /health, секунд: проверка локальная, дольше ждать незачем.
PII_HEALTH_TIMEOUT_SEC=3

# pii_enabled — включена ли установка прокси (по умолчанию да; отключение - SKIP_PII_PROXY=1).
pii_enabled() { [ "${SKIP_PII_PROXY:-0}" != "1" ]; }

# pii_lab — корень рабочих каталогов агентов.
pii_lab() { printf '%s' "${CLAUDE_LAB:-$HOME/.claude-lab}"; }

# pii_proxy_env_file <agent> — путь env-файла прокси агента (секреты, права 600).
pii_proxy_env_file() { printf '%s/%s/.claude/secrets/pii-proxy.env' "$(pii_lab)" "$1"; }

# pii_proxy_port <agent> — порт прокси агента: из его env-файла, иначе 6300 + индекс в ростере.
pii_proxy_port() {
  local agent="$1" f port idx=0 a
  f="$(pii_proxy_env_file "$agent")"
  if [ -r "$f" ]; then
    port="$(sed -n 's/^PII_PROXY_PORT=\([0-9][0-9]*\)$/\1/p' "$f" | head -n1)"
    if [ -n "$port" ]; then printf '%s\n' "$port"; return 0; fi
  fi
  while IFS= read -r a; do
    if [ "$a" = "$agent" ]; then printf '%s\n' $(( PII_PROXY_BASE_PORT + idx )); return 0; fi
    idx=$(( idx + 1 ))
  done < <(list_agents)
  return 1
}

# pii_port_taken <port> <skip-agent> — занят ли порт другим агентом (по env-файлам) или
# слушается ли он на хосте.
pii_port_taken() {
  local port="$1" skip="${2:-}" d name
  for d in "$(pii_lab)"/*/; do
    name="$(basename "$d")"
    [ "$name" = "$skip" ] && continue
    if grep -qsx "PII_PROXY_PORT=$port" "$(pii_proxy_env_file "$name")"; then return 0; fi
  done
  if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -qE "127\.0\.0\.1:${port}\b"; then
    return 0
  fi
  return 1
}

# pii_pick_port <agent> — свободный порт для нового прокси: начиная с 6300 + индекс.
pii_pick_port() {
  local agent="$1" port i
  port="$(pii_proxy_port "$agent" 2>/dev/null || true)"
  port="${port:-$PII_PROXY_BASE_PORT}"
  for i in $(seq 0 "$PII_PROXY_PORT_SPAN"); do
    if ! pii_port_taken $(( port + i )) "$agent"; then printf '%s\n' $(( port + i )); return 0; fi
  done
  return 1
}

# pii_agent_base_url <agent> — ANTHROPIC_BASE_URL из settings.json агента, только локальный
# (127.0.0.1/localhost). Пусто - у агента прокси нет.
pii_agent_base_url() {
  local f
  f="$(pii_lab)/$1/.claude/settings.json"
  [ -r "$f" ] || return 0
  python3 - "$f" <<'PY' 2>/dev/null || true
import json, re, sys
try:
    url = json.load(open(sys.argv[1])).get("env", {}).get("ANTHROPIC_BASE_URL", "")
except Exception:
    url = ""
if re.match(r"^http://(127\.0\.0\.1|localhost):[0-9]+/?$", url or ""):
    print(url.rstrip("/"))
PY
}

# pii_proxy_healthy <base-url> — отвечает ли прокси на GET /health.
pii_proxy_healthy() {
  curl -fsS --max-time "$PII_HEALTH_TIMEOUT_SEC" -o /dev/null "${1%/}/health" 2>/dev/null
}

# pii_gate <agent> — можно ли стартовать claude. 0: у агента нет прокси либо он жив;
# 1: прокси настроен, но не отвечает (стартовать в обход нельзя).
pii_gate() {
  local url
  url="$(pii_agent_base_url "$1")"
  if [ -z "$url" ]; then return 0; fi
  pii_proxy_healthy "$url"
}

# pii_stuck_file <agent> — файл событий session_stuck, куда пишет прокси.
pii_stuck_file() { printf '%s/%s/.claude/state/pii-session-stuck.jsonl' "$(pii_lab)" "$1"; }

# pii_stuck_poll <agent> — сколько событий session_stuck появилось с прошлого вызова.
# Печатает число (0, если нового нет) и запоминает позицию в файле .seen рядом.
pii_stuck_poll() {
  local f seen total prev
  f="$(pii_stuck_file "$1")"
  seen="$f.seen"
  if [ ! -f "$f" ]; then echo 0; return 0; fi
  total="$(wc -l < "$f" | tr -d ' ')"
  prev="$(cat "$seen" 2>/dev/null || echo 0)"
  case "$prev" in ''|*[!0-9]*) prev=0;; esac
  # Файл усекли или заменили - читаем с начала.
  if [ "$total" -lt "$prev" ]; then prev=0; fi
  printf '%s' "$total" > "$seen" 2>/dev/null || true
  echo $(( total - prev ))
}
