#!/usr/bin/env bash
set -euo pipefail

# sdk-guard: skip when running as Agent SDK child to prevent recursion.
if [ "${CLAUDE_SDK_CHILD:-0}" = "1" ]; then
    exit 0
fi

# UserPromptSubmit hook -- proactive recall on substantive prompts.
#
# A worthiness gate (pure-bash salience heuristic) drops acknowledgements/short
# follow-ups so recall does not fire on "ok"/"спасибо". For worthy prompts it
# rebuilds core/active/working-set.md keyed on the prompt itself, in the
# BACKGROUND so the turn is never delayed (working-set-build also self-caps its
# shared recall with a hard timeout). Fail-open: any error exits 0.
#
# Wire via templates/settings.json.template (UserPromptSubmit hook).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="${AGENT_WORKSPACE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
AGENT_ID="${AGENT_ID:-$(basename "$(dirname "$WS")")}"
LOGDIR="$WS/logs"; mkdir -p "$LOGDIR"
HOOK_LOG="$LOGDIR/hooks.log"
log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [user-prompt-submit] $1" >> "$HOOK_LOG"; }

PAYLOAD=$(cat || true)
[ -z "$PAYLOAD" ] && exit 0

# Extract the prompt text (JSON field or raw).
PROMPT=$(PAYLOAD_E="$PAYLOAD" python3 - <<'PY' 2>/dev/null
import json, os
raw = os.environ["PAYLOAD_E"]
text = ""
try:
    obj = json.loads(raw)
    for k in ("prompt", "user_prompt", "text", "message", "input"):
        v = obj.get(k)
        if isinstance(v, str) and v.strip():
            text = v.strip(); break
except Exception:
    text = raw.strip()
print(text.replace("\n", " ")[:300])
PY
)
[ -z "$PROMPT" ] && exit 0

# Worthiness gate: reuse the salience classifier; skip ephemeral acks.
WRITER="$SCRIPT_DIR/../scripts/active-writer.sh"
worthy=1
if [ -f "$WRITER" ]; then
    # shellcheck source=/dev/null
    source "$WRITER"
    [ "$(classify_salience "$PROMPT")" = "ephemeral" ] && worthy=0
fi
if [ "$worthy" -eq 0 ]; then
    log "prompt not recall-worthy (ephemeral); skip"
    exit 0
fi

BUILD="$SCRIPT_DIR/../scripts/working-set-build.sh"
if [ -f "$BUILD" ]; then
    log "recall-worthy prompt → refreshing working-set (bg)"
    ( AGENT_WORKSPACE="$WS" AGENT_ID="$AGENT_ID" WORKING_SET_QUERY="$PROMPT" \
        bash "$BUILD" >>"$HOOK_LOG" 2>&1 || true ) &
fi
exit 0
