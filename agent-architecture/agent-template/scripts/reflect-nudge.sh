#!/usr/bin/env bash
set -euo pipefail

# reflect-nudge.sh -- ask the LIVE session to consolidate memory.
#
# `claude -p` is forbidden repo-wide, so reflection (episodic -> passive insights)
# is NOT done by a background model call. Instead this script nudges the running
# session via agent_router.notify (the same proven path night-learnings.sh uses);
# the session then runs the `memory-consolidate` skill with its own tools.
#
# Graceful degrade: if the shared brain is unreachable (single-agent / file-only),
# it drops a request marker the session picks up on its next turn. Fail-open.
#
# Usage:  reflect-nudge.sh --reason checkpoint|idle
# Env:    AGENT_WORKSPACE, AGENT_ID, AGENT_BEARER,
#         SECOND_BRAIN_AGENT_ROUTER_URL (default http://localhost:5000/mcp),
#         MEMORY_NUDGE_COOLDOWN (s, default 120), MEMORY_NUDGE_DRYRUN (1 => print payload).

REASON="checkpoint"
while [ $# -gt 0 ]; do
    case "$1" in
        --reason) REASON="${2:-checkpoint}"; shift 2 ;;
        *) shift ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="${AGENT_WORKSPACE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
AGENT_ID="${AGENT_ID:-$(basename "$(dirname "$WS")")}"
ROUTER_URL="${SECOND_BRAIN_AGENT_ROUTER_URL:-http://localhost:5000/mcp}"
COOLDOWN="${MEMORY_NUDGE_COOLDOWN:-120}"
LOGDIR="$WS/logs"; mkdir -p "$LOGDIR"
HOOK_LOG="$LOGDIR/hooks.log"
STAMP="$WS/core/active/.last-nudge"
MARKER="$WS/core/active/consolidate.request"

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [reflect-nudge] $1" >> "$HOOK_LOG"; }

# shellcheck source=mcp-call.sh
. "$SCRIPT_DIR/mcp-call.sh"

# Bearer: prefer env, else parse the agent's own .mcp.json (as night-learnings does).
bearer() {
    if [ -n "${AGENT_BEARER:-}" ]; then printf '%s' "$AGENT_BEARER"; return; fi
    local mcp="$WS/.mcp.json"
    [ -f "$mcp" ] || return 0
    grep -A3 'agent_router' "$mcp" 2>/dev/null | grep 'Authorization' \
        | grep -oE 'Bearer [^"]+' | head -1 | sed 's/^Bearer //'
}

BODY="Reflection nudge (${REASON}). Run the memory-consolidate skill: read new \
core/active/episodic.md entries since core/passive/.consolidated-at, distil \
insights (decisions/errors/preferences/facts) into core/passive/*, add \
provenance + decay frontmatter, dual-write important ones to second_brain \
(recall-before-write), then update the watermark."

# Build a valid agent_router.notify payload.
# Полноценный JSON-RPC: без "jsonrpc"/"id" и с методом "agent_router.notify"
# сервер отвечал "-32602 Validation error: 9 validation errors for JSONRPC", и
# побудка на консолидацию памяти не срабатывала ни разу за 45 дней -- 235
# попыток на двух агентах, ноль успехов. Имя инструмента идёт в params.name,
# как это делает brain-flush.sh.
PAYLOAD=$(BODY_E="$BODY" AGENT_E="$AGENT_ID" REASON_E="$REASON" python3 - <<'PY'
import json, os
print(json.dumps({
    "jsonrpc": "2.0",
    "id": 1,
    "method": "tools/call",
    "params": {"name": "notify", "arguments": {
        "to_agent": os.environ["AGENT_E"],
        "payload": {
            "title": "Memory consolidation",
            "body": os.environ["BODY_E"],
            "instruction_type": "memory_consolidate",
            "reason": os.environ["REASON_E"],
            "priority": "low",
        },
    }},
}, ensure_ascii=False))
PY
)

# Dry-run: emit payload for tests, no side effects.
if [ "${MEMORY_NUDGE_DRYRUN:-0}" = "1" ]; then
    printf '%s\n' "$PAYLOAD"
    exit 0
fi

# Cooldown: don't spam the session on back-to-back triggers.
now=$(date -u +%s)
if [ -f "$STAMP" ]; then
    last=$(cat "$STAMP" 2>/dev/null || echo 0)
    if [ $((now - last)) -lt "$COOLDOWN" ]; then
        log "cooldown active (${COOLDOWN}s), skip ${REASON}"
        exit 0
    fi
fi
echo "$now" > "$STAMP"

drop_marker() {
    { echo "# consolidate requested: ${REASON} @ $(date -u +%Y-%m-%dT%H:%M:%SZ)"; } >> "$MARKER"
    log "shared layer off -> dropped marker for file-only reflection (${REASON})"
}

TOKEN="$(bearer || true)"
if [ -z "$TOKEN" ]; then
    drop_marker
    exit 0
fi

# Через рукопожатие: FastMCP отвергает одиночный tools/call ("Missing session
# ID"), поэтому побудка молча падала в маркер каждый раз (см. mcp-call.sh).
MCP_TIMEOUT_S=5
RESP=$(mcp_tools_call "$ROUTER_URL" "$TOKEN" "$PAYLOAD" 2>&1 || echo "ERROR")

if printf '%s' "$RESP" | grep -qiE '"error"|\bERROR\b|^null$'; then
    log "notify failed (${REASON}); falling back to marker: ${RESP:0:120}"
    drop_marker
else
    log "notify queued (${REASON})"
fi
exit 0
