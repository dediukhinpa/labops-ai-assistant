#!/usr/bin/env bash
set -euo pipefail

# sdk-guard: skip when running as Agent SDK child to prevent recursion (issue #143)
if [ "${CLAUDE_SDK_CHILD:-0}" = "1" ]; then
    exit 0
fi

# Stop hook -- runs at the end of each Claude Code turn.
# Appends a salience-tagged episodic entry to core/active/episodic.md (via
# active-writer.sh), and a verbose JSON line to logs/verbose-YYYY-MM-DD.jsonl.
#
# Claude Code passes JSON on stdin describing the stopped turn. We do not block
# the harness: any failure exits 0.
#
# Wire via templates/settings.json.template (Stop hook).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="${AGENT_WORKSPACE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
AGENT_ID="${AGENT_ID:-$(basename "$(dirname "$WS")")}"
ACTIVE="$WS/core/active/episodic.md"
LOGDIR="$WS/logs"
HOOK_LOG="$LOGDIR/hooks.log"
DAY=$(date -u +%Y-%m-%d)
VERBOSE_LOG="$LOGDIR/verbose-${DAY}.jsonl"

mkdir -p "$(dirname "$ACTIVE")" "$LOGDIR"
touch "$ACTIVE" "$HOOK_LOG"

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [stop-hook] $1" >> "$HOOK_LOG"; }

# Read stdin (may be empty if invoked manually)
PAYLOAD=$(cat || true)

# sdk-guard: skip when payload signals an Agent SDK child entrypoint
if [ -n "$PAYLOAD" ]; then
    if python3 -c "import json,sys; d=json.loads(sys.argv[1] or '{}'); sys.exit(0 if d.get('entrypoint')=='sdk-ts' else 1)" "$PAYLOAD" 2>/dev/null; then
        log "sdk-guard: entrypoint=sdk-ts, skipping"
        exit 0
    fi
fi

if [ -z "$PAYLOAD" ]; then
    log "no stdin payload; nothing to record"
    exit 0
fi

ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Verbose: append raw payload (one JSON object per line). If it's not valid JSON,
# wrap it in a minimal envelope so the file stays JSONL-parseable.
SAFE_LINE=$(PAYLOAD_E="$PAYLOAD" ISO_E="$ISO" AGENT_E="$AGENT_ID" python3 - <<'PY' 2>>"$HOOK_LOG"
import json, os
raw = os.environ["PAYLOAD_E"]
iso = os.environ["ISO_E"]
agent = os.environ["AGENT_E"]
try:
    obj = json.loads(raw)
    obj.setdefault("_ts", iso)
    obj.setdefault("_agent", agent)
    print(json.dumps(obj, ensure_ascii=False))
except Exception:
    print(json.dumps({"_ts": iso, "_agent": agent, "raw": raw}, ensure_ascii=False))
PY
) || SAFE_LINE=""

if [ -n "$SAFE_LINE" ]; then
    printf '%s\n' "$SAFE_LINE" >> "$VERBOSE_LOG"
fi

# Episodic entry: delegate to active-writer.sh (snippet extraction + salience tag).
printf '%s' "$PAYLOAD" | AGENT_WORKSPACE="$WS" bash "$SCRIPT_DIR/../scripts/active-writer.sh" --source stop-hook || true

log "appended episodic entry and verbose line"
exit 0
