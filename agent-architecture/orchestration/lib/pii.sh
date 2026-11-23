#!/usr/bin/env bash
# pii.sh — общие функции псевдонимизации (pii-proxy) для установки и watchdog.
# SOURCE this file. Ничего не запускает при сорсинге.
#
# Модель: у агента есть свой pii-proxy на 127.0.0.1:<порт>. В норме агент ходит в модель через
# него (ANTHROPIC_BASE_URL в settings.json). «Есть ли у агента прокси» определяется ровно по
# этому ключу: настройка, которую читает сам claude, не может разойтись с проверкой watchdog.
#
# Решение владельца 23.11.2026: если прокси не отвечает, агент НЕ останавливается, а работает
# напрямую (запасной режим), и оператор получает предупреждение в Telegram. Пока прокси лежит,
# персональные данные уходят в модель без маскирования — это принятый владельцем риск.
# Текущий режим лежит файлом в рабочей папке агента (pii_mode_file): его пишут start-agent.sh
# и watchdog, читают session-exec.sh (claude), драйвер codex и doctor.sh.

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
  local f toml
  # Агент на Codex: прокси — model_provider labops-pii в CODEX_HOME/config.toml, его base_url
  # заканчивается путём бэкенда (/backend-api/codex); нужен корень прокси для /health.
  toml="$(pii_lab)/$1/.codex/config.toml"
  if [ -r "$toml" ]; then
    python3 - "$toml" <<'PY' 2>/dev/null || true
import re, sys, tomllib
try:
    with open(sys.argv[1], "rb") as fh:
        cfg = tomllib.load(fh)
    url = cfg.get("model_providers", {}).get(cfg.get("model_provider", ""), {}).get("base_url", "")
except Exception:
    url = ""
m = re.match(r"^(http://(127\.0\.0\.1|localhost):[0-9]+)(/|$)", url or "")
if m:
    print(m.group(1))
PY
    return 0
  fi
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

# pii_gate <agent> — отвечает ли прокси агента. 0: у агента нет прокси либо он жив;
# 1: прокси настроен, но не отвечает. Старт это больше не запрещает (см. pii_mode_resolve_start).
pii_gate() {
  local url
  url="$(pii_agent_base_url "$1")"
  if [ -z "$url" ]; then return 0; fi
  pii_proxy_healthy "$url"
}

# ── Режим «через прокси» / «напрямую» ────────────────────────────────────────
PII_MODE_PROXY="proxy"
PII_MODE_DIRECT="direct"
# Гистерезис работающего агента (проверка раз в проход watchdog, ~30с): столько неудачных
# проверок подряд переводят агента напрямую, столько удачных подряд возвращают через прокси.
# Один таймаут агента не дёргает.
PII_DOWN_AFTER_FAILS="${PII_DOWN_AFTER_FAILS:-3}"
PII_UP_AFTER_OKS="${PII_UP_AFTER_OKS:-2}"
# Сколько секунд ждать прокси после попытки поднять его юнит (на старте агента).
PII_REVIVE_WAIT_SEC="${PII_REVIVE_WAIT_SEC:-3}"
# Троттлинг одинаковых предупреждений о смене режима, секунд. Сообщения о падении и
# восстановлении чередуются и разделены гистерезисом, так что троттлинг гасит только повторы
# (например, если файл режима записать не удалось и каждый старт считает смену заново).
PII_MODE_ALERT_COOLDOWN="${PII_MODE_ALERT_COOLDOWN:-60}"
# Счётчики гистерезиса (глобальные: живут в процессе watchdog).
PII_FAIL_STREAK=0
PII_OK_STREAK=0
# Какой режим нужен агенту по итогам последней проверки (pii_watch_step); пусто - прокси нет.
PII_WANT=""

# pii_mode_file <agent> — файл текущего режима агента (proxy|direct).
pii_mode_file() { printf '%s/%s/.claude/state/pii-mode' "$(pii_lab)" "$1"; }

# pii_mode_get <agent> — текущий режим: direct, если так записано, иначе proxy.
pii_mode_get() {
  local m
  m="$(cat "$(pii_mode_file "$1")" 2>/dev/null || true)"
  if [ "$m" = "$PII_MODE_DIRECT" ]; then
    printf '%s\n' "$PII_MODE_DIRECT"
  else
    printf '%s\n' "$PII_MODE_PROXY"
  fi
}

# pii_mode_write <agent> <mode> — атомарно записать режим (ошибка записи не роняет вызывающего).
pii_mode_write() {
  local f tmp
  f="$(pii_mode_file "$1")"
  tmp="$f.tmp.$$"
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 0
  if printf '%s\n' "$2" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
  fi
  return 0
}

# pii_proxy_state <agent> — none (прокси у агента не настроен) | up | down.
pii_proxy_state() {
  local url
  url="$(pii_agent_base_url "$1")"
  if [ -z "$url" ]; then echo none; return 0; fi
  if pii_proxy_healthy "$url"; then echo up; else echo down; fi
}

# pii_proxy_revive <agent> — попытка поднять юнит прокси (без ожидания, ошибки не важны).
# PII_SYSTEMCTL подменяет systemctl (тесты, песочница).
pii_proxy_revive() {
  local sc="${PII_SYSTEMCTL:-systemctl}"
  command -v "$sc" >/dev/null 2>&1 || return 0
  XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" \
    "$sc" --user start "labops-pii-proxy@$1.service" >/dev/null 2>&1 || true
  return 0
}

# pii_mode_message <agent> <mode> — текст предупреждения оператору о смене режима.
pii_mode_message() {
  if [ "$2" = "$PII_MODE_DIRECT" ]; then
    printf '%s' "⚠️ pii-proxy недоступен — работаю напрямую: персональные данные" \
      " уходят в модель БЕЗ маскирования. Если ваше последнее сообщение не успело" \
      " обработаться, повторяю его уже без прокси. Когда прокси поднимется, вернусь через" \
      " него сам и сообщу. Проверить: systemctl --user status labops-pii-proxy@$1"
  else
    printf '%s' "✅ pii-proxy снова отвечает — работаю через него, персональные данные снова" \
      " маскируются."
  fi
}

# pii_mode_set <agent> <mode> — записать режим; при смене — предупреждение оператору (один раз
# на смену: повторная запись того же режима ничего не шлёт). notify_op берётся из notify.sh,
# если он подключён вызывающим. 0 - режим сменился, 1 - уже был таким.
pii_mode_set() {
  local agent="$1" mode="$2" old
  old="$(pii_mode_get "$agent")"
  pii_mode_write "$agent" "$mode"
  if [ "$old" = "$mode" ]; then return 1; fi
  if declare -F notify_op >/dev/null 2>&1; then
    NOTIFY_TAG="${NOTIFY_TAG:-$agent}" WATCHDOG_ALERT_COOLDOWN="$PII_MODE_ALERT_COOLDOWN" \
      notify_op "$agent" "$(pii_mode_message "$agent" "$mode")"
  fi
  return 0
}

# pii_mode_resolve_start <agent> — выбрать режим перед стартом агента и записать его.
# Прокси жив - proxy; молчит - одна попытка поднять юнит, повторная проверка, и если всё ещё
# молчит - direct (агент стартует напрямую, оператор получает предупреждение). У агента без
# прокси файл режима не нужен - удаляем, чтобы старый direct не повлиял на запуск.
# Печатает выбранный режим (none - прокси нет). Всегда возвращает 0.
pii_mode_resolve_start() {
  local agent="$1" state
  state="$(pii_proxy_state "$agent")"
  if [ "$state" = none ]; then
    rm -f "$(pii_mode_file "$agent")" 2>/dev/null || true
    echo none; return 0
  fi
  if [ "$state" = down ]; then
    pii_proxy_revive "$agent"
    sleep "$PII_REVIVE_WAIT_SEC"
    state="$(pii_proxy_state "$agent")"
  fi
  if [ "$state" = up ]; then
    pii_mode_set "$agent" "$PII_MODE_PROXY" || true
    echo "$PII_MODE_PROXY"
  else
    pii_mode_set "$agent" "$PII_MODE_DIRECT" || true
    echo "$PII_MODE_DIRECT"
  fi
  return 0
}

# pii_watch_step <agent> — одна проверка прокси работающего агента (зовёт watchdog раз в
# проход). Ведёт счётчики гистерезиса и ставит PII_WANT: какой режим нужен агенту сейчас
# (пусто - прокси у агента нет). На первой неудаче пробует поднять юнит прокси. Сам режим не
# меняет: как переключить без потери работы, решает вызывающий. Всегда возвращает 0.
pii_watch_step() {
  local agent="$1" state cur
  PII_WANT=""
  state="$(pii_proxy_state "$agent")"
  if [ "$state" = none ]; then
    PII_FAIL_STREAK=0; PII_OK_STREAK=0
    return 0
  fi
  cur="$(pii_mode_get "$agent")"
  PII_WANT="$cur"
  if [ "$state" = up ]; then
    PII_FAIL_STREAK=0
    PII_OK_STREAK=$(( PII_OK_STREAK + 1 ))
    if [ "$cur" = "$PII_MODE_DIRECT" ] && [ "$PII_OK_STREAK" -ge "$PII_UP_AFTER_OKS" ]; then
      PII_WANT="$PII_MODE_PROXY"
    fi
  else
    PII_OK_STREAK=0
    PII_FAIL_STREAK=$(( PII_FAIL_STREAK + 1 ))
    if [ "$PII_FAIL_STREAK" -eq 1 ]; then pii_proxy_revive "$agent"; fi
    if [ "$cur" = "$PII_MODE_PROXY" ] && [ "$PII_FAIL_STREAK" -ge "$PII_DOWN_AFTER_FAILS" ]; then
      PII_WANT="$PII_MODE_DIRECT"
    fi
  fi
  return 0
}

# pii_switch_due <agent> — нужна ли смена режима по итогам последней pii_watch_step.
pii_switch_due() {
  [ -n "$PII_WANT" ] && [ "$PII_WANT" != "$(pii_mode_get "$1")" ]
}

# pii_switch_continue_file <agent> — метка «следующий старт claude продолжает разговор»
# (--continue): watchdog ставит её перед перезапуском ради смены режима, session-exec.sh
# забирает. Так смена режима не стирает контекст диалога.
pii_switch_continue_file() {
  printf '%s/%s/.claude/state/pii-switch-continue' "$(pii_lab)" "$1"
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

# Сколько секунд ждём ответа сервиса определения страны (сеть может быть закрыта).
PII_GEO_TIMEOUT_SEC=4

# pii_geo_country — двухбуквенный код страны внешнего IP хоста; пусто, если определить нельзя.
# PII_GEO_CMD подменяет команду (тесты и закрытые сети).
pii_geo_country() {
  local c
  c="$(${PII_GEO_CMD:-curl -fsS --max-time $PII_GEO_TIMEOUT_SEC https://ipinfo.io/country} \
    2>/dev/null | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]' || true)"
  case "$c" in [A-Z][A-Z]) printf '%s' "$c";; esac
}

# pii_geo_check — предупреждение, если хост не в РФ (152-ФЗ, ст. 18 ч. 5: первичная запись и
# хранение ПДн граждан РФ - в базах на территории РФ). Установку НЕ блокирует; нет сети -
# проверка молча пропускается. Всегда возвращает 0. Нужны функции note/warn из ui.sh.
pii_geo_check() {
  local c
  c="$(pii_geo_country)"
  if [ -z "$c" ]; then
    note "страна хоста не определена (нет сети?) - проверка локализации 152-ФЗ пропущена"
  elif [ "$c" != "RU" ]; then
    warn "IP хоста определён вне РФ (страна: $c). Если рой будет обрабатывать персональные данные"
    warn "граждан РФ, 152-ФЗ требует локализации: хранение и первичная запись - на хосте в РФ."
    warn "Маскирование перед моделью локализацию НЕ заменяет. Установка продолжается."
  else
    ok "хост в РФ (локализация 152-ФЗ)"
  fi
  return 0
}
