#!/usr/bin/env bash
# Unit tests for second_brain-monitor.sh — transition alerting, no-spam, port probe.
# systemctl / curl / the Telegram sender are all stubbed; no real services touched.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
MON="$HERE/second_brain-monitor.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SENT="$TMP/sent.log"
cat > "$TMP/send.sh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$SENT"
EOF
# stub systemctl: is-active <- \$TMP/active ; show -p NRestarts <- \$TMP/nrestarts
cat > "$TMP/systemctl.sh" <<EOF
#!/usr/bin/env bash
case "\$1" in
  is-active) cat "$TMP/active" 2>/dev/null || echo inactive ;;
  show)      cat "$TMP/nrestarts" 2>/dev/null || echo 0 ;;
  *)         exit 0 ;;
esac
EOF
# stub curl: exit code from \$TMP/curlrc (0 = reachable, 7 = refused)
cat > "$TMP/curl.sh" <<EOF
#!/usr/bin/env bash
exit "\$(cat "$TMP/curlrc" 2>/dev/null || echo 0)"
EOF
chmod +x "$TMP"/*.sh

export NOTIFY_SEND_CMD="$TMP/send.sh"
export MONITOR_SYSTEMCTL="$TMP/systemctl.sh"
export MONITOR_CURL="$TMP/curl.sh"
export MONITOR_STATE_DIR="$TMP/state"
export MONITOR_AGENT="demo"
export MONITOR_COMPONENTS="memory|second_brain-memory-mcp|5001"
export WATCHDOG_ALERT_COOLDOWN=0

fail(){ echo "FAIL: $1"; exit 1; }
lines(){ [ -f "$SENT" ] && wc -l < "$SENT" | tr -d ' ' || echo 0; }

echo active > "$TMP/active"; echo 0 > "$TMP/nrestarts"; echo 0 > "$TMP/curlrc"

# 1. healthy → no alert
bash "$MON" >/dev/null 2>&1
[ "$(lines)" = "0" ] || fail "healthy should not alert (got $(lines))"

# 2. unit inactive → exactly one DOWN alert
echo inactive > "$TMP/active"
bash "$MON" >/dev/null 2>&1
[ "$(lines)" = "1" ] || fail "expected 1 down alert (got $(lines))"
grep -q "🔴" "$SENT" || fail "down alert should carry 🔴"

# 3. still down → no new alert (transition-only, survives a flapping timer)
bash "$MON" >/dev/null 2>&1
[ "$(lines)" = "1" ] || fail "repeat-down must not re-alert (got $(lines))"

# 4. recovers → one recovery alert
echo active > "$TMP/active"
bash "$MON" >/dev/null 2>&1
[ "$(lines)" = "2" ] || fail "expected recovery alert (got $(lines))"
grep -q "🟢" "$SENT" || fail "recovery alert should carry 🟢"

# 5. unit active but port unreachable → DOWN alert (catches wedged-but-alive)
echo 7 > "$TMP/curlrc"
bash "$MON" >/dev/null 2>&1
[ "$(lines)" = "3" ] || fail "port-unreachable should alert (got $(lines))"

echo "second_brain-monitor.sh: all 5 checks passed"
