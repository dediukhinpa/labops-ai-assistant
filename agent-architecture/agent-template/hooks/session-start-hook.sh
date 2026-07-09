#!/usr/bin/env bash
set -euo pipefail

# sdk-guard: skip when running as Agent SDK child to prevent recursion (issue #143)
if [ "${CLAUDE_SDK_CHILD:-0}" = "1" ]; then
    exit 0
fi

# SessionStart hook -- runs once at the start of a Claude Code session.
# 1) Logs that a session started.
# 2) Rebuilds core/active/working-set.md via working-set-build.sh: fuses shared
#    second_brain recall (if creds present) with local passive/ lexical recall.
#    Runs even file-only -- it self-gates the shared half on env. Never edits
#    episodic.md.
#
# Wire via templates/settings.json.template (SessionStart hook).
# Non-blocking: any failure exits 0.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="${AGENT_WORKSPACE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
AGENT_ID="${AGENT_ID:-$(basename "$(dirname "$WS")")}"
LOGDIR="$WS/logs"
HOOK_LOG="$LOGDIR/hooks.log"
HANDOFF="$WS/core/active/handoff.md"

mkdir -p "$LOGDIR"
touch "$HOOK_LOG"

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [session-start] $1" >> "$HOOK_LOG"; }

log "session started (agent=${AGENT_ID})"

# Surface handoff to the user via stderr (visible in hook output)
if [ -f "$HANDOFF" ] && [ -s "$HANDOFF" ]; then
    log "handoff present: $(wc -l <"$HANDOFF") lines"
fi

# Rebuild the working set (materialised recall). Runs even without second_brain
# creds -- it self-gates the shared half and always does local passive recall.
BUILD_SCRIPT="$WS/scripts/working-set-build.sh"
if [ -f "$BUILD_SCRIPT" ]; then
    log "rebuilding working-set"
    AGENT_WORKSPACE="$WS" AGENT_ID="$AGENT_ID" bash "$BUILD_SCRIPT" >>"$HOOK_LOG" 2>&1 \
        || log "working-set-build returned non-zero"
fi

exit 0
