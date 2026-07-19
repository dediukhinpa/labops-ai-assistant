#!/usr/bin/env bash
set -euo pipefail

# brain-flush.sh -- safety-net flush of the agent's working state to the shared
# brain (second_brain) as an inbox handoff note.
#
# WHY: the write rules put dual-write on the model ("write immediately"), but
# nothing guaranteed a flush before the two moments knowledge is actually lost:
# context compaction and session end. This script is that guarantee -- wired to
# the PreCompact and SessionEnd hooks. It is a SAFETY NET, not a replacement
# for the write rules: it dumps the episodic tail + handoff into inbox/ via
# create_handoff so a human or the next session can recover; curated notes
# (decisions, knowledge) must still be written in-session by the model.
#
# Fail-open by design: no bearer / backend down / timeout -> exit 0 silently.
# Dedup: skips when the flushed content hash matches the previous flush.
#
# Usage: brain-flush.sh --reason precompact|session-end

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="${AGENT_WORKSPACE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
AGENT_ID="${AGENT_ID:-$(basename "$(dirname "$WS")")}"
EPISODIC="$WS/core/active/episodic.md"
HANDOFF="$WS/core/active/handoff.md"
STATE_DIR="$WS/state"
MARKER="$STATE_DIR/brain-flush.sha"
LOG="$WS/logs/hooks.log"
REASON="${2:-unknown}"; [ "${1:-}" = "--reason" ] || REASON="unknown"
FLUSH_TAIL_LINES="${BRAIN_FLUSH_TAIL_LINES:-120}"
TIMEOUT_S="${BRAIN_FLUSH_TIMEOUT_S:-3}"

mkdir -p "$STATE_DIR" "$(dirname "$LOG")"
log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [brain-flush] $1" >> "$LOG"; }

# Guard: same placeholder rule as everywhere else -- CHANGE_ME means "second
# brain not deployed yet", never a credential to send.
if [ -z "${AGENT_BEARER:-}" ] || [ "${AGENT_BEARER:-}" = "CHANGE_ME" ] \
   || [ -z "${SECOND_BRAIN_MEMORY_URL:-}" ]; then
    log "skip ($REASON): AGENT_BEARER/SECOND_BRAIN_MEMORY_URL unset"
    exit 0
fi

BODY_SRC=""
[ -s "$HANDOFF" ]  && BODY_SRC+="## handoff.md
$(cat "$HANDOFF")

"
[ -s "$EPISODIC" ] && BODY_SRC+="## episodic tail
$(tail -n "$FLUSH_TAIL_LINES" "$EPISODIC")"
if [ -z "$BODY_SRC" ]; then
    log "skip ($REASON): nothing to flush"
    exit 0
fi

SHA=$(printf '%s' "$BODY_SRC" | sha256sum | cut -d' ' -f1)
if [ "$(cat "$MARKER" 2>/dev/null || true)" = "$SHA" ]; then
    log "skip ($REASON): content unchanged since last flush"
    exit 0
fi

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
PAYLOAD=$(BODY_E="$BODY_SRC" AGENT_E="$AGENT_ID" TS_E="$TS" REASON_E="$REASON" python3 - <<'PY'
import json, os
print(json.dumps({
    "jsonrpc": "2.0", "id": 1, "method": "tools/call",
    "params": {"name": "create_handoff", "arguments": {
        "from_agent": os.environ["AGENT_E"],
        "to_agent": os.environ["AGENT_E"],
        "title": f"auto-flush ({os.environ['REASON_E']}) {os.environ['TS_E']}",
        "body": os.environ["BODY_E"],
    }},
}))
PY
) || { log "skip ($REASON): payload build failed"; exit 0; }

RESP=$(curl -sS -m "$TIMEOUT_S" -X POST "$SECOND_BRAIN_MEMORY_URL" \
    -H "Authorization: Bearer ${AGENT_BEARER}" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    --data "$PAYLOAD" 2>/dev/null) || { log "flush ($REASON) failed: backend unreachable"; exit 0; }

if printf '%s' "$RESP" | grep -qE '"error"[[:space:]]*:[[:space:]]*\{'; then
    log "flush ($REASON) rejected by backend"
    exit 0
fi
echo "$SHA" > "$MARKER"
log "flushed ($REASON) to shared brain inbox ($(printf '%s' "$BODY_SRC" | wc -c) bytes)"
exit 0
