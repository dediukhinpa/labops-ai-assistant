#!/usr/bin/env bash
# shellcheck disable=SC2012
set -euo pipefail

# sdk-guard: skip when running as Agent SDK child to prevent recursion (issue #143)
if [ "${CLAUDE_SDK_CHILD:-0}" = "1" ]; then
    exit 0
fi

# PreCompact hook -- snapshot episodic.md before Claude Code auto-compacts context.
# Keeps the last N pre-compact snapshots so you can recover state if compaction
# loses information you cared about.
#
# Wire via templates/settings.json.template (PreCompact hook).
# Non-blocking: any failure exits 0.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="${AGENT_WORKSPACE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
AGENT_ID="${AGENT_ID:-$(basename "$(dirname "$WS")")}"
ACTIVE="$WS/core/active/episodic.md"
SNAP_DIR="$WS/core/active/pre-compact"
LOGDIR="$WS/logs"
HOOK_LOG="$LOGDIR/hooks.log"
KEEP_SNAPSHOTS="${KEEP_SNAPSHOTS:-10}"

mkdir -p "$SNAP_DIR" "$LOGDIR"
touch "$HOOK_LOG"

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [precompact] $1" >> "$HOOK_LOG"; }

if [ ! -f "$ACTIVE" ] || [ ! -s "$ACTIVE" ]; then
    log "no episodic.md to snapshot"
    exit 0
fi

TS=$(date -u +%Y%m%d-%H%M%S)
SNAP="$SNAP_DIR/recent-${TS}.md"
cp "$ACTIVE" "$SNAP" || { log "snapshot copy failed"; exit 0; }
log "snapshot saved: $SNAP ($(wc -c <"$SNAP") bytes)"

# Safety-net flush to the shared brain BEFORE compaction can lose context —
# the write rules alone ("write immediately") had no mechanical guarantee.
# Fail-open, short timeout, no-op while AGENT_BEARER is the placeholder.
FLUSH="$SCRIPT_DIR/../scripts/brain-flush.sh"
if [ -f "$FLUSH" ]; then
    AGENT_WORKSPACE="$WS" AGENT_ID="$AGENT_ID" bash "$FLUSH" --reason precompact || true
fi

# Rotate: keep newest N
COUNT=$(ls -1 "$SNAP_DIR"/recent-*.md 2>/dev/null | wc -l | tr -d ' ')
if [ "$COUNT" -gt "$KEEP_SNAPSHOTS" ]; then
    REMOVE=$((COUNT - KEEP_SNAPSHOTS))
    ls -1t "$SNAP_DIR"/recent-*.md | tail -n "$REMOVE" | while read -r old; do
        rm -f "$old"
        log "rotated out: $old"
    done
fi

exit 0
