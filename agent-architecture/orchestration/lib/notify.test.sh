#!/usr/bin/env bash
# Unit tests for lib/notify.sh — opt-in / throttle / non-fatal behaviour.
# No network: the Telegram sender is stubbed via NOTIFY_SEND_CMD.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SENT="$TMP/sent.log"
cat > "$TMP/fake-send.sh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$SENT"
exit 0
EOF
cat > "$TMP/fail-send.sh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$TMP/fake-send.sh" "$TMP/fail-send.sh"

export NOTIFY_SEND_CMD="$TMP/fake-send.sh"
export WATCHDOG_ALERT_COOLDOWN=300
# Изолируем файловые метки троттла от реального ~/.claude-lab.
export NOTIFY_STATE_DIR="$TMP/notify-state"

# shellcheck disable=SC1091
source "$HERE/notify.sh"

fail() { echo "FAIL: $1"; exit 1; }
lines() { [ -f "$SENT" ] && wc -l < "$SENT" | tr -d ' ' || echo 0; }

: > "$SENT"

# 1. first alert is delivered
notify_op demo "frozen turn"
[ "$(lines)" = "1" ] || fail "expected 1 send, got $(lines)"

# 2. identical alert within cooldown is suppressed (survives flapping)
notify_op demo "frozen turn"
[ "$(lines)" = "1" ] || fail "dedup failed: got $(lines)"

# 3. a DIFFERENT alert is delivered (per-message throttle, not global)
notify_op demo "no prompt rendered"
[ "$(lines)" = "2" ] || fail "distinct message should send: got $(lines)"

# 4. cooldown=0 lets the same message through again
WATCHDOG_ALERT_COOLDOWN=0 notify_op demo "frozen turn"
[ "$(lines)" = "3" ] || fail "cooldown bypass failed: got $(lines)"

# 5. disabled via WATCHDOG_TG_ALERTS=0 sends nothing
WATCHDOG_TG_ALERTS=0 notify_op demo "must not send"
[ "$(lines)" = "3" ] || fail "disable flag ignored: got $(lines)"

# 6. non-fatal: a failing sender must not abort a `set -e` caller
(
  set -e
  NOTIFY_SEND_CMD="$TMP/fail-send.sh" WATCHDOG_ALERT_COOLDOWN=0 notify_op demo "sender will fail"
  echo ok > "$TMP/survived"
)
[ -f "$TMP/survived" ] || fail "notify_op aborted a set -e caller on send failure"

# 7. NOTIFY_TAG overrides the displayed source label (used by second_brain-monitor)
: > "$SENT"
NOTIFY_TAG="sb-monitor" WATCHDOG_ALERT_COOLDOWN=0 notify_op demo "ping"
grep -q "sb-monitor" "$SENT" || fail "NOTIFY_TAG not honored in the message"
grep -q "watchdog/demo" "$SENT" && fail "default tag leaked while NOTIFY_TAG was set"

# 8. РЕГРЕССИЯ (2026-08-09): троттл обязан переживать рестарт демона.
# Раньше метки жили только в памяти процесса — падающий watchdog поднимался
# systemd'ом с чистым состоянием и слал оператору один и тот же алерт каждые
# ~2 минуты часами. Эмулируем рестарт: свежий bash, тот же NOTIFY_STATE_DIR.
: > "$SENT"
run_fresh() {   # отдельный процесс = «демон подняли заново»
  env NOTIFY_SEND_CMD="$TMP/fake-send.sh" WATCHDOG_ALERT_COOLDOWN=300 \
      NOTIFY_STATE_DIR="$TMP/notify-restart" \
      bash -c 'source "$1"; notify_op demo "restart flapping"' _ "$HERE/notify.sh"
}
run_fresh
[ "$(lines)" = "1" ] || fail "первый алерт после старта не ушёл: got $(lines)"
run_fresh
run_fresh
[ "$(lines)" = "1" ] || fail "троттл не пережил рестарт демона: got $(lines) отправок вместо 1"

# 9. Недоступный каталог состояния не должен ронять отправку (fallback в память).
: > "$SENT"
NOTIFY_STATE_DIR=/proc/nonexistent/notify WATCHDOG_ALERT_COOLDOWN=0 \
  notify_op demo "state dir unavailable"
[ "$(lines)" = "1" ] || fail "недоступный NOTIFY_STATE_DIR сломал отправку: got $(lines)"

# 10. Не роняет вызывающего с `set -e` (в т.ч. когда троттл глушит сообщение).
(
  set -euo pipefail
  notify_op demo "state dir unavailable"   # подавлено троттлом
  notify_op demo "restart flapping"        # подавлено файловой меткой
  echo ok > "$TMP/survived-throttle"
)
[ -f "$TMP/survived-throttle" ] || fail "notify_op уронил вызывающего с set -e при срабатывании троттла"

echo "notify.sh: all 10 checks passed"
