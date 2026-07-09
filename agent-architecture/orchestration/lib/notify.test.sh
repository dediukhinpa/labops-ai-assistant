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

echo "notify.sh: all 7 checks passed"
