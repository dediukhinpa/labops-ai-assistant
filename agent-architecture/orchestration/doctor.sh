#!/usr/bin/env bash
# doctor.sh — одна кнопка «проверь и почини агента».
#
# Usage: doctor.sh <agent> [--fix] [--quiet]
#
# Зачем отдельный скрипт, если есть watchdog: watchdog реагирует на СВОЙ цикл и
# молчит о рутине (см. «Что оператор действительно хочет знать» в watchdog.sh).
# Оператору нужна возможность спросить «что с агентом?» в любой момент и получить
# один короткий ответ на человеческом языке — без чтения логов и без tmux.
# Отсюда два требования к выводу:
#   • не больше нескольких строк, никакой внутренней кухни;
#   • вердикт по существу: работает / починил вот это / сам не починю, нужно вот что.
#
# Без --fix только диагностирует. С --fix чинит то, что чинится безопасно.
# ВАЖНО: рестарт сессии УНИЧТОЖАЕТ контекст диалога агента, поэтому применяется
# последним средством — только когда TUI действительно не отвечает.
#
# Exit code: 0 — агент на связи (возможно, после починки); 1 — нужен оператор.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(realpath "$0")")" && pwd)"

AGENT=""
FIX=0
QUIET=0
for arg in "$@"; do
  case "$arg" in
    --fix)   FIX=1 ;;
    --quiet) QUIET=1 ;;
    -*)      echo "unknown option: $arg" >&2; exit 2 ;;
    *)       [ -n "$AGENT" ] || AGENT="$arg" ;;
  esac
done
[ -n "$AGENT" ] || { echo "usage: doctor.sh <agent> [--fix] [--quiet]" >&2; exit 2; }

SESSION="labops-$AGENT"
CLAUDE_LAB="${CLAUDE_LAB:-$HOME/.claude-lab}"
AGENT_WS="$CLAUDE_LAB/$AGENT/.claude"
# DOCTOR_START_SCRIPT — только для теста: настоящий старт агента поднимает tmux и
# сессию Claude, в юнит-тесте его подменяют заглушкой.
START_SCRIPT="${DOCTOR_START_SCRIPT:-$SCRIPT_DIR/start-agent.sh}"
CREDENTIALS="${CLAUDE_CREDENTIALS_FILE:-$HOME/.claude/.credentials.json}"
# Сколько секунд ждать, пока вопрос о каналах уйдёт после ответа (тест ставит 0).
DOCTOR_DEV_CHANNELS_WAIT="${DOCTOR_DEV_CHANNELS_WAIT:-10}"

# shellcheck source=lib/pane.sh
source "$SCRIPT_DIR/lib/pane.sh"
# shellcheck source=lib/task-poller-launch.sh
source "$SCRIPT_DIR/lib/task-poller-launch.sh"
# ВАЖНО: pane-recover.sh при сорсинге перезаписывает SCRIPT_DIR на .../lib —
# источаем его ПОСЛЕДНИМ и дальше собственный SCRIPT_DIR не используем.
DOCTOR_DIR="$SCRIPT_DIR"
# shellcheck source=lib/pane-recover.sh
source "$SCRIPT_DIR/lib/pane-recover.sh"
SCRIPT_DIR="$DOCTOR_DIR"
# Харнес роя: у агента на Codex свои проверки входа и живости (TUI-панели нет).
# shellcheck source=lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"
# shellcheck source=lib/codex-watch.sh
source "$SCRIPT_DIR/lib/codex-watch.sh"
# shellcheck source=lib/agent-env.sh
source "$SCRIPT_DIR/lib/agent-env.sh"
# shellcheck source=lib/pii.sh
source "$SCRIPT_DIR/lib/pii.sh"
DOCTOR_HARNESS="$(harness_current 2>/dev/null || echo claude)"
# Сколько секунд heartbeat драйвера Codex считается свежим (драйвер пишет его раз в минуту).
DOCTOR_CODEX_HEARTBEAT_STALE="${DOCTOR_CODEX_HEARTBEAT_STALE:-300}"

# ── Накопители вердикта ──────────────────────────────────────────────────────
# FIXED — что удалось починить; BROKEN — что требует человека. Обычные строки с
# переводами строк (а не массивы) — вывод всё равно склеивается в текст.
FIXED=""
BROKEN=""
NOTE=""     # диагностика без вердикта (для --quiet=0, в Telegram не уходит)
WARN=""     # предупреждение без вердикта: агент на связи, но оператор должен знать (всегда)

add_fixed()  { FIXED="${FIXED}${FIXED:+; }$1"; }
add_broken() { BROKEN="${BROKEN}${BROKEN:+
}⛔ $1"; }
add_note()   { NOTE="${NOTE}${NOTE:+
}$1"; }
add_warn()   { WARN="${WARN}${WARN:+
}⚠️ $1"; }

# ── 1. Вход в Claude Code ────────────────────────────────────────────────────
# Первое, что должен знать оператор: жива ли подписка. Проверяем refresh-токен,
# а НЕ access-токен: короткий access истекает каждые несколько часов и штатно
# обновляется сам — его истечение поломкой не является.
check_credentials() {
  if [ ! -f "$CREDENTIALS" ]; then
    add_broken "нет входа в Claude Code на сервере — нужно войти заново"
    return 0
  fi
  local exp now
  exp="$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print(""); raise SystemExit(0)
o = d.get("claudeAiOauth") or {}
# refreshTokenExpiresAt есть не во всех версиях — тогда судить не по чему.
print(o.get("refreshTokenExpiresAt") or "")
' "$CREDENTIALS" 2>/dev/null || true)"
  case "$exp" in ''|*[!0-9]*) add_note "срок входа не читается — пропускаю проверку"; return 0 ;; esac
  now="$(date +%s)"
  # Метка в миллисекундах.
  if [ "$((exp / 1000))" -lt "$now" ]; then
    add_broken "подписка Claude недействительна — нужно заново войти на сервере"
  fi
  return 0
}

# ── 2. Служба ────────────────────────────────────────────────────────────────
# Юнит поднимает и стережёт watchdog. Своими силами его не стартуем: для этого
# нужен sudo с паролем, а doctor должен работать без интерактива.
check_unit() {
  local unit="claude-agent-$AGENT.service"
  if ! systemctl list-unit-files "$unit" >/dev/null 2>&1; then
    add_note "служба $unit не установлена"
    return 0
  fi
  if ! systemctl is-active --quiet "$unit" 2>/dev/null; then
    add_broken "служба агента остановлена — нужен запуск с правами root: sudo systemctl start $unit"
  fi
  return 0
}

# ── 3. Сессия ────────────────────────────────────────────────────────────────
check_session() {
  if tmux has-session -t "=$SESSION" 2>/dev/null; then
    return 0
  fi
  if [ "$FIX" -eq 0 ]; then
    add_broken "агент не запущен"
    return 0
  fi
  if "$START_SCRIPT" "$AGENT" >/dev/null 2>&1; then
    add_fixed "запустил агента заново"
  else
    add_broken "агент не запускается"
  fi
  return 0
}

# ── 4. Панель: отвечает ли TUI ───────────────────────────────────────────────
# Порядок важен: сначала ошибка доступа (её рестарт не лечит и лечить нечем),
# потом отсутствие промпта, потом залипший ввод.
capture() { tmux capture-pane -pt "=$SESSION:^.{top-left}" -S -8 2>/dev/null || true; }

check_pane() {
  if ! tmux has-session -t "=$SESSION" 2>/dev/null; then
    return 0        # сессии нет — об этом уже сказано выше
  fi
  local tail
  tail="$(capture)"

  if has_auth_error "$tail"; then
    add_broken "агент не может обращаться к модели: не проходит вход Claude — нужно войти заново на сервере"
    return 0
  fi

  # Гейт «Bypass Permissions mode». Подтвердить его может только оператор за
  # своей клавиатурой (почему — см. lib/pane.sh), поэтому даже с --fix мы здесь
  # ничего не нажимаем: говорим ровно то, что нужно сделать человеку. Без этой
  # ветки доктор списывал экран в «агент не отвечает» и перезапускал сессию —
  # та вставала на том же вопросе.
  if looks_like_bypass_permissions_prompt "$tail"; then
    add_broken "$(bypass_permissions_hint "$SESSION")"
    return 0
  fi

  # Вопрос о каналах разработки на старте claude. Разбираем ДО застрявшего
  # ввода: выбранный пункт меню начинается с «❯», и экран проходит и has_prompt,
  # и is_stuck_input — --fix перепечатал бы строку меню с Enter, а на «2. Exit»
  # это закрыло бы claude. Отвечаем тем же, что и watchdog (lib/pane.sh).
  if looks_like_dev_channels_prompt "$tail"; then
    if [ "$FIX" -eq 0 ]; then
      add_broken "агент ждёт ответа на стартовый вопрос Claude Code — /doctor подтвердит сам"
      return 0
    fi
    # Починкой считаем только ушедший вопрос: отправленный Enter ещё не значит,
    # что claude его принял.
    if answer_dev_channels_prompt "$SESSION" "$tail" \
       && dev_channels_prompt_wait_gone "$SESSION" "$DOCTOR_DEV_CHANNELS_WAIT"; then
      add_fixed "подтвердил стартовый вопрос Claude Code — агент продолжает запуск"
    else
      add_broken "стартовый вопрос Claude Code не принимает ответ — нужна помощь на сервере"
    fi
    return 0
  fi

  if ! has_prompt "$tail"; then
    # Полноэкранный вывод слэш-команды выглядит как мёртвый TUI. Escape
    # закрывает оверлей и ничего не делает с реально зависшим — он и различает.
    tmux send-keys -t "=$SESSION:^.{top-left}" Escape 2>/dev/null || true
    sleep 2
    tail="$(capture)"
    if ! has_prompt "$tail"; then
      if [ "$FIX" -eq 0 ]; then
        add_broken "агент не отвечает"
        return 0
      fi
      # Последнее средство: рестарт стирает контекст диалога, поэтому только
      # здесь — TUI доказанно не откликается.
      if "$START_SCRIPT" "$AGENT" >/dev/null 2>&1; then
        add_fixed "перезапустил зависшего агента (переписка начата заново)"
      else
        add_broken "агент завис и не перезапускается"
      fi
      return 0
    fi
  fi

  # Застрявшее сообщение: канал доставил текст, но не отправил его.
  if is_stuck_input "$tail"; then
    if [ "$FIX" -eq 0 ]; then
      add_broken "сообщение застряло в поле ввода и не дошло до агента"
      return 0
    fi
    local rc=0
    recover_stuck_input "$SESSION" || rc=$?
    if [ "$rc" -eq 1 ]; then
      add_broken "сообщение застряло в поле ввода и не дошло до агента"
    elif [ "$rc" -eq 0 ]; then
      if [ "${RECOVER_TRUNCATED:-0}" -eq 1 ]; then
        add_fixed "дослал застрявшее сообщение, но уцелела только последняя строка — пришлите его ещё раз"
      else
        add_fixed "дослал застрявшее сообщение"
      fi
    fi
  fi
  return 0
}

# ── 5. Обвязка сессии ────────────────────────────────────────────────────────
# Молча, если всё на месте: оператору интересен итог, а не инвентаризация.
check_plumbing() {
  if ! tmux has-session -t "=$SESSION" 2>/dev/null; then
    return 0
  fi

  # Осиротевшие channel-серверы: родительский claude умер, bun крутится.
  local p
  for p in $(pgrep -f "\.claude-lab/$AGENT/\.claude/plugins/labops-channel/plugin/src/server\.ts" 2>/dev/null || true); do
    if [ "$(awk '{print $4}' "/proc/$p/stat" 2>/dev/null)" = "1" ]; then
      if [ "$FIX" -eq 1 ]; then
        kill -9 "$p" 2>/dev/null || true
        add_note "убрал зависший вспомогательный процесс"
      fi
    fi
  done

  # Межагентный task-поллер.
  if [ "$FIX" -eq 1 ]; then
    if [ "$(ensure_task_poller "$AGENT" "$AGENT_WS")" = "launched" ]; then
      add_fixed "поднял приём задач от других агентов"
    fi
  fi
  return 0
}

# ── 6. Общая память (second-brain) ───────────────────────────────────────────
# Не влияет на «агент на связи», поэтому не вердикт, а примечание: без неё агент
# отвечает, но теряет долгую память.
#
# Адреса — те, которыми пользуется сам агент: .mcp.json (Claude Code), config.toml (Codex),
# затем agent.env; иначе прежние 5001/5002. Раньше порты были зашиты, и мозг на других портах
# (песочница, второй рой на хосте) считался мёртвым, а живой по умолчанию — проверялся чужой.
DOCTOR_BRAIN_DEFAULT_URLS=("http://127.0.0.1:5001/mcp" "http://127.0.0.1:5002/mcp")

# brain_urls — две строки: адрес memory и memory_router агента (пустая — не нашлось).
brain_urls() {
  python3 - "$AGENT_WS" "$CLAUDE_LAB/$AGENT/.codex/config.toml" <<'PY' 2>/dev/null || true
import json
import re
import sys
from pathlib import Path

ws, toml_path = Path(sys.argv[1]), Path(sys.argv[2])
servers = (("second_brain-memory", "SECOND_BRAIN_MEMORY_URL"),
           ("second_brain-memory_router", "SECOND_BRAIN_MEMORY_ROUTER_URL"))


def usable(url: object) -> str:
    """Адрес, если это настоящий http(s)-адрес, а не плейсхолдер шаблона."""
    return url if isinstance(url, str) and url.startswith("http") and "${" not in url else ""


def from_mcp_json(name: str) -> str:
    try:
        data = json.loads((ws / ".mcp.json").read_text(encoding="utf-8"))
        return usable(data["mcpServers"][name]["url"])
    except Exception:
        return ""


def from_toml(name: str) -> str:
    try:
        import tomllib
        data = tomllib.loads(toml_path.read_text(encoding="utf-8"))
        return usable(data["mcp_servers"][name]["url"])
    except Exception:
        return ""


def from_agent_env(var: str) -> str:
    value = ""
    try:
        for line in (ws / "agent.env").read_text(encoding="utf-8").splitlines():
            m = re.match(rf"""^(?:export\s+)?{var}=(["']?)(.*)\1\s*$""", line.strip())
            if m:
                value = m.group(2)
    except OSError:
        return ""
    return usable(value)


for name, var in servers:
    print(from_mcp_json(name) or from_toml(name) or from_agent_env(var))
PY
}

check_second_brain() {
  local url label dead="" i=0 found=()
  mapfile -t found < <(brain_urls)
  for i in 0 1; do
    url="${found[$i]:-}"
    url="${url:-${DOCTOR_BRAIN_DEFAULT_URLS[$i]}}"
    # В примечании — порт, как и раньше; адрес без порта показываем целиком.
    label="$(printf '%s' "$url" | sed -nE 's|^[a-z]+://[^/]*:([0-9]+).*|\1|p')"
    label="${label:-$url}"
    if ! curl -s -o /dev/null -m 3 "$url" 2>/dev/null; then
      dead="${dead}${dead:+,}$label"
    fi
  done
  if [ -n "$dead" ]; then
    add_note "общая память недоступна (порты $dead) — агент работает, но без долгой памяти"
  fi
  return 0
}

# ── 7. Маскирование ПДн (pii-proxy) ──────────────────────────────────────────
# Не вердикт: без прокси агент работает напрямую (решение владельца 23.11.2026), но оператор
# должен знать, что персональные данные сейчас уходят в модель без маскирования. Поэтому это
# предупреждение, которое видно и в Telegram, а при норме — только примечание с режимом.
check_pii() {
  local state mode
  state="$(pii_proxy_state "$AGENT")"
  [ "$state" != none ] || return 0
  mode="$(pii_mode_get "$AGENT")"
  if [ "$state" = down ] && [ "$FIX" -eq 1 ]; then
    pii_proxy_revive "$AGENT"
    sleep "$PII_REVIVE_WAIT_SEC"
    state="$(pii_proxy_state "$AGENT")"
    if [ "$state" = up ]; then add_fixed "поднял pii-proxy"; fi
  fi
  if [ "$state" = down ] \
     && [ "$(pii_proxy_down_reason "$AGENT")" = "$PII_DOWN_REASON_PSEUDONYMIZER" ]; then
    # Прокси жив, но сервис псевдонимизации нет: перезапуск прокси тут не поможет.
    add_warn "сервис псевдонимизации недоступен (pii-proxy жив, маскировать нечем) — агент\
 работает напрямую, персональные данные уходят в модель без маскирования. Проверьте:\
 systemctl --user status labops-pseudonymizer"
  elif [ "$state" = down ]; then
    add_warn "pii-proxy не отвечает — агент работает напрямую, персональные данные уходят\
 в модель без маскирования. Проверьте: systemctl --user status labops-pii-proxy@$AGENT"
  elif [ "$mode" = "$PII_MODE_DIRECT" ]; then
    add_warn "pii-proxy снова отвечает, но агент пока работает напрямую —\
 вернётся через прокси сам, в простое"
  else
    add_note "режим ПДн: через pii-proxy (маскирование работает)"
  fi
  return 0
}

# ── Codex: вход в ChatGPT и живость драйвера ─────────────────────────────────
check_codex_login() {
  case "$(codex_auth_state "$AGENT")" in
    none) add_broken "Codex не вошёл в ChatGPT — $(codex_login_hint "$AGENT")" ;;
    apikey) add_broken "Codex вошёл по API-ключу, а нужна подписка ChatGPT — $(codex_login_hint "$AGENT")" ;;
  esac
  return 0
}

check_codex_driver() {
  local why="" port
  tmux has-session -t "=$SESSION" 2>/dev/null || return 0   # это уже разобрал check_session
  port="$(agent_env_webhook_port "$AGENT" 2>/dev/null || true)"
  if [ -z "$(codex_driver_pid "$AGENT")" ]; then
    why="драйвер не работает"
  elif [ -n "$port" ] && ! ss -ltn 2>/dev/null | grep -qE "127\.0\.0\.1:$port\b"; then
    why="канал не слушает порт $port"
  elif codex_heartbeat_stale "$AGENT_WS/state/heartbeat" "$DOCTOR_CODEX_HEARTBEAT_STALE"; then
    why="драйвер не отвечает (heartbeat устарел)"
  fi
  [ -n "$why" ] || return 0
  if [ "$FIX" -eq 0 ]; then
    add_broken "$why"
  elif "$START_SCRIPT" "$AGENT" >/dev/null 2>&1; then
    add_fixed "перезапустил агента ($why)"
  else
    add_broken "$why, перезапуск не помог"
  fi
  return 0
}

# Codex молча обрезает AGENTS.md сверх project_doc_max_bytes, а память (decisions.md,
# preferences.md) только растёт. Размер пишет сборка AGENTS.md (codex_workspace.py) в
# state/agents-md-size.json; здесь он превращается в вердикт: выше порога — предупреждение,
# выше предела — поломка (агент работает, но часть памяти для него уже не существует).
# Нет файла — сборки ещё не было или агент старый: молчим, выдумывать поломку незачем.
check_codex_agents_md_size() {
  local status="$AGENT_WS/state/agents-md-size.json" level="" detail=""
  [ -f "$status" ] || return 0
  # Две строки: уровень (ok|warn|over) и описание «N из M байт; крупнейшие: …».
  { read -r level; read -r detail; } < <(python3 - "$status" <<'PY' 2>/dev/null || true
import json
import sys

TOP = 3  # сколько источников назвать в вердикте для Telegram
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        data = json.load(fh)
    size, limit = int(data["bytes"]), int(data["limit"])
    fraction = float(data.get("warn_fraction", 0.75))
    level = "over" if size > limit else "warn" if size >= limit * fraction else "ok"
    top = ", ".join(f"{s['path']} ({s['bytes']} Б)" for s in data.get("sources", [])[:TOP])
    print(level)
    print(f"{size} из {limit} байт; крупнейшие: {top}")
except Exception:
    pass
PY
) || true
  case "$level" in
    over) add_broken "AGENTS.md агента больше предела Codex ($detail) — хвост памяти обрезается; сократить или консолидировать decisions.md / preferences.md" ;;
    warn) add_warn "AGENTS.md агента близок к пределу Codex ($detail) — пора сократить или консолидировать decisions.md / preferences.md" ;;
  esac
  return 0
}

if [ "$DOCTOR_HARNESS" = "codex" ]; then
  check_codex_login
  check_unit
  check_session
  check_codex_driver
  check_codex_agents_md_size
  check_plumbing
  check_second_brain
  check_pii
else
check_credentials
check_unit
check_session
check_pane
check_plumbing
check_second_brain
check_pii
fi

# ── Вердикт ──────────────────────────────────────────────────────────────────
# Формат заточен под Telegram: заголовок с именем агента и максимум пара строк.
NAME="$(printf '%s' "$AGENT" | sed 's/^./\U&/')"
OUT="🩺 $NAME"

if [ -n "$BROKEN" ]; then
  OUT="$OUT
$BROKEN"
  if [ -n "$FIXED" ]; then
    OUT="$OUT
🔧 попутно починил: $FIXED"
  fi
elif [ -n "$FIXED" ]; then
  OUT="$OUT
🔧 починил: $FIXED
✅ агент на связи"
else
  OUT="$OUT
✅ всё в порядке, агент на связи"
fi

if [ -n "$WARN" ]; then
  OUT="$OUT
$WARN"
fi

if [ "$QUIET" -eq 0 ] && [ -n "$NOTE" ]; then
  OUT="$OUT

$NOTE"
fi

printf '%s\n' "$OUT"
[ -z "$BROKEN" ]
