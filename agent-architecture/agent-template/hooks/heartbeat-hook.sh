#!/usr/bin/env bash
set -euo pipefail

# Drain stdin first (Claude passes JSON on it). Делаем это ДО любого раннего
# выхода: если слить после sdk-guard, пишущий в нас процесс словит SIGPIPE на
# гонке (мы вышли раньше, чем он успел записать). Слив всегда — читатель есть.
cat >/dev/null 2>&1 || true

# sdk-guard: skip when running as Agent SDK child to prevent recursion.
if [ "${CLAUDE_SDK_CHILD:-0}" = "1" ]; then
    exit 0
fi

# Heartbeat hook -- writes a liveness timestamp the watchdog reads to tell
# "alive" from "wedged" WITHOUT scraping the TUI (❯ / "bypass permissions" text
# is version-fragile). Wired to several events (SessionStart / UserPromptSubmit /
# PreToolUse / PostToolUse / Notification / Stop) in settings.json.template, so
# it ticks at every turn and tool boundary.
#
# Deliberately minimal: this fires on EVERY tool call, so no python, no recall,
# no logging — just one atomic write. Fail-open: any error exits 0 so the harness
# is never blocked.
#
# IMPORTANT for consumers: hooks fire at event/tool boundaries, NOT continuously.
# A long model response with no tool calls will not tick the heartbeat. So a
# FRESH heartbeat is proof-of-life (safe to suppress a restart), but a STALE one
# is only a hint — corroborate it with the pane, never restart on staleness
# alone. See orchestration/watchdog.sh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="${AGENT_WORKSPACE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
STATE_DIR="$WS/state"
HEARTBEAT="$STATE_DIR/heartbeat"

mkdir -p "$STATE_DIR" 2>/dev/null || exit 0

# Atomic write: tmp + rename, so the watchdog never reads a half-written value.
tmp="$HEARTBEAT.tmp.$$"
if date +%s > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$HEARTBEAT" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
fi
exit 0
