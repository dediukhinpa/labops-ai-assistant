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

# Checkpoint: every N turns, nudge in-session consolidation (fail-open, background).
CHECKPOINT_N="${MEMORY_CHECKPOINT_EVERY_N_TURNS:-20}"
COUNTER="$WS/core/active/.turn-counter"
count=$(( $(cat "$COUNTER" 2>/dev/null || echo 0) + 1 ))
echo "$count" > "$COUNTER"
NUDGE="$SCRIPT_DIR/../scripts/reflect-nudge.sh"
if [ -f "$NUDGE" ] && [ "$CHECKPOINT_N" -gt 0 ] && [ $(( count % CHECKPOINT_N )) -eq 0 ]; then
    log "checkpoint: ${count} turns → nudging consolidation"
    ( AGENT_WORKSPACE="$WS" AGENT_ID="$AGENT_ID" bash "$NUDGE" --reason checkpoint >/dev/null 2>&1 || true ) &
fi

# Housekeeping: decay-sweep + archive-roll, at most once per day, in the
# background. Previously these existed only as an OPTIONAL cron the installer
# printed as text — if the operator never set it up, nothing bounded the growth
# of the memory layers. Wiring them here makes rotation a default, not advice.
HK_INTERVAL="${MEMORY_HOUSEKEEPING_INTERVAL_SEC:-86400}"
HK_MARKER="$WS/state/last-housekeeping"
now=$(date +%s)
last=$(cat "$HK_MARKER" 2>/dev/null || echo 0)
case "$last" in ''|*[!0-9]*) last=0;; esac
if [ "$HK_INTERVAL" -gt 0 ] && [ $(( now - last )) -ge "$HK_INTERVAL" ]; then
    mkdir -p "$WS/state"
    echo "$now" > "$HK_MARKER"
    log "housekeeping: running decay-sweep + archive-roll (last run $((now - last))s ago)"
    (
        for hk in decay-sweep.sh archive-roll.sh; do
            [ -f "$SCRIPT_DIR/../scripts/$hk" ] || continue
            AGENT_WORKSPACE="$WS" AGENT_ID="$AGENT_ID" \
                bash "$SCRIPT_DIR/../scripts/$hk" >>"$HOOK_LOG" 2>&1 || true
        done
    ) &
fi

log "appended episodic entry and verbose line"
exit 0
