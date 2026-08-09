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

# ── Накопители вердикта ──────────────────────────────────────────────────────
# FIXED — что удалось починить; BROKEN — что требует человека. Обычные строки с
# переводами строк (а не массивы) — вывод всё равно склеивается в текст.
FIXED=""
BROKEN=""
NOTE=""     # диагностика без вердикта (для --quiet=0, в Telegram не уходит)

add_fixed()  { FIXED="${FIXED}${FIXED:+; }$1"; }
add_broken() { BROKEN="${BROKEN}${BROKEN:+
}⛔ $1"; }
add_note()   { NOTE="${NOTE}${NOTE:+
}$1"; }

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
  if tmux has-session -t "$SESSION" 2>/dev/null; then
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
capture() { tmux capture-pane -pt "$SESSION" -S -8 2>/dev/null || true; }

check_pane() {
  if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    return 0        # сессии нет — об этом уже сказано выше
  fi
  local tail
  tail="$(capture)"

  if has_auth_error "$tail"; then
    add_broken "агент не может обращаться к модели: не проходит вход Claude — нужно войти заново на сервере"
    return 0
  fi

  if ! has_prompt "$tail"; then
    # Полноэкранный вывод слэш-команды выглядит как мёртвый TUI. Escape
    # закрывает оверлей и ничего не делает с реально зависшим — он и различает.
    tmux send-keys -t "$SESSION" Escape 2>/dev/null || true
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
  if ! tmux has-session -t "$SESSION" 2>/dev/null; then
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
check_second_brain() {
  local url port dead=""
  for port in 5001 5002; do
    url="http://127.0.0.1:$port/mcp"
    if ! curl -s -o /dev/null -m 3 "$url" 2>/dev/null; then
      dead="${dead}${dead:+,}$port"
    fi
  done
  if [ -n "$dead" ]; then
    add_note "общая память недоступна (порты $dead) — агент работает, но без долгой памяти"
  fi
  return 0
}

check_credentials
check_unit
check_session
check_pane
check_plumbing
check_second_brain

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

if [ "$QUIET" -eq 0 ] && [ -n "$NOTE" ]; then
  OUT="$OUT

$NOTE"
fi

printf '%s\n' "$OUT"
[ -z "$BROKEN" ]
