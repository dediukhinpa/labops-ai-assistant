#!/usr/bin/env bash
set -euo pipefail

# working-set-build.sh -- materialise core/active/working-set.md for the current task.
#
# Replaces second_brain-memory_router-on-start.sh. Recall is a *view*, not an edit
# of episodic memory: it never touches episodic.md. Two sources, fused:
#   1) shared brain  -- second_brain memory_router `recall` (RRF over embeddings)
#   2) local passive -- lexical keyword-overlap over core/passive/*.md (file-only path)
#
# Every hit is logged to core/recall-events.jsonl (the reinforcement signal that
# decay-sweep replays). Non-blocking: a hard timeout skips the shared recall rather
# than delaying the session. Fail-open (exit 0 on any non-fatal error).
#
# Env: AGENT_WORKSPACE AGENT_ID SECOND_BRAIN_MEMORY_ROUTER_URL AGENT_BEARER
#      RECALL_LIMIT(5) RECALL_TIMEOUT_MS(1000) RECALL_MIN_OVERLAP(2)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="${AGENT_WORKSPACE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
AGENT_ID="${AGENT_ID:-$(basename "$(dirname "$WS")")}"
HANDOFF="$WS/core/active/handoff.md"
EPISODIC="$WS/core/active/episodic.md"
PASSIVE_DIR="$WS/core/passive"
WORKING_SET="$WS/core/active/working-set.md"
EVENTS="$WS/core/recall-events.jsonl"
LOGDIR="$WS/logs"; mkdir -p "$LOGDIR" "$(dirname "$WORKING_SET")"
LOG="$LOGDIR/working-set.log"
LIMIT="${RECALL_LIMIT:-5}"
MIN_OVERLAP="${RECALL_MIN_OVERLAP:-2}"
TIMEOUT_MS="${RECALL_TIMEOUT_MS:-1000}"
# curl -m is whole seconds; round up, floor 1.
TIMEOUT_S=$(( (TIMEOUT_MS + 999) / 1000 )); [ "$TIMEOUT_S" -lt 1 ] && TIMEOUT_S=1

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [working-set] $1" >> "$LOG"; }
ISO() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# --- 1) build query: explicit override (e.g. the just-submitted prompt), else
#        last handoff, else episodic tail ------------------------------------
QUERY="${WORKING_SET_QUERY:-}"
if [ -z "$QUERY" ] && [ -f "$HANDOFF" ] && [ -s "$HANDOFF" ]; then
    QUERY=$(grep -vE '^[[:space:]]*$' "$HANDOFF" | tail -n 3 | tr '\n' ' ' | head -c 300)
fi
if [ -z "$QUERY" ] && [ -f "$EPISODIC" ] && [ -s "$EPISODIC" ]; then
    QUERY=$(grep -vE '^[[:space:]]*$|^###' "$EPISODIC" | tail -n 5 | tr '\n' ' ' | head -c 300)
fi
QUERY=$(printf '%s' "$QUERY" | tr -d '\r' | sed 's/[`"\\]/ /g' | tr -s ' ' | head -c 250)
if [ -z "$QUERY" ]; then
    log "no query material; leaving working-set untouched"
    exit 0
fi
log "query: $QUERY"

SHARED_HITS=""; LOCAL_HITS=""

# --- 2) shared recall (non-blocking) -----------------------------------------
if [ -n "${SECOND_BRAIN_MEMORY_ROUTER_URL:-}" ] && [ -n "${AGENT_BEARER:-}" ]; then
    PAYLOAD=$(QUERY_E="$QUERY" LIMIT_E="$LIMIT" python3 - <<'PY'
import json, os
print(json.dumps({"jsonrpc":"2.0","id":1,"method":"tools/call",
    "params":{"name":"recall","arguments":{
        "query":os.environ["QUERY_E"],"limit":int(os.environ["LIMIT_E"])}}}))
PY
)
    RESP=$(curl -sS -m "$TIMEOUT_S" -X POST "$SECOND_BRAIN_MEMORY_ROUTER_URL" \
        -H "Authorization: Bearer ${AGENT_BEARER}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json, text/event-stream" \
        --data "$PAYLOAD" 2>>"$LOG") || { log "shared recall timed out/failed (skip)"; RESP=""; }
    if [ -n "$RESP" ] && ! printf '%s' "$RESP" | grep -qE '"error"[[:space:]]*:[[:space:]]*\{'; then
        SHARED_HITS=$(RESPONSE_E="$RESP" python3 - <<'PY'
import json, os, re
raw = os.environ["RESPONSE_E"]
lines = [m.group(1) for m in re.finditer(r'^data:\s*(\{.*\})\s*$', raw, re.M)]
try:
    obj = json.loads(lines[-1] if lines else raw)
except Exception:
    raise SystemExit(0)
res = obj.get("result") or {}
out = []
if isinstance(res.get("content"), list):
    out = [c.get("text","").strip() for c in res["content"] if isinstance(c, dict) and c.get("text")]
elif isinstance(res.get("items"), list):
    for it in res["items"]:
        if isinstance(it, dict):
            t = it.get("text") or it.get("body") or it.get("title")
            if t: out.append(str(t).strip())
for t in out:
    print("- " + t.replace("\n", " ")[:200])
PY
)
    fi
else
    log "shared layer off (no SECOND_BRAIN_MEMORY_ROUTER_URL/AGENT_BEARER) -> local only"
fi

# --- 3) local passive recall (lexical keyword overlap) -----------------------
if [ -d "$PASSIVE_DIR" ]; then
    LOCAL_HITS=$(QUERY_E="$QUERY" DIR_E="$PASSIVE_DIR" LIMIT_E="$LIMIT" MINO_E="$MIN_OVERLAP" python3 - <<'PY'
import os, re, glob
q = os.environ["QUERY_E"].lower()
qtokens = set(re.findall(r'[a-zA-Zа-яА-Я0-9]{3,}', q))
limit = int(os.environ["LIMIT_E"]); mino = int(os.environ["MINO_E"])
scored = []
for path in sorted(glob.glob(os.path.join(os.environ["DIR_E"], "*.md"))):
    fname = os.path.basename(path)
    try:
        text = open(path, encoding="utf-8").read()
    except Exception:
        continue
    # split into notes by frontmatter fences or ### headers; fall back to paragraphs
    chunks = re.split(r'\n---\n|\n(?=### )|\n\n', text)
    for ch in chunks:
        body = re.sub(r'^---.*?---', '', ch, flags=re.S).strip()
        if not body:
            continue
        toks = set(re.findall(r'[a-zA-Zа-яА-Я0-9]{3,}', body.lower()))
        overlap = len(qtokens & toks)
        if overlap >= mino:
            snippet = re.sub(r'\s+', ' ', body)[:200]
            scored.append((overlap, fname, snippet))
scored.sort(key=lambda x: -x[0])
for _, fname, snippet in scored[:limit]:
    print(f"- {snippet}  (passive/{fname})")
PY
)
fi

# --- 4) log recall events (reinforcement signal) -----------------------------
append_events() { # <source> <text-block>
    local src="$1" block="$2" ts; ts="$(ISO)"
    [ -z "$block" ] && return 0
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        SRC_E="$src" TS_E="$ts" LINE_E="$line" QUERY_E="$QUERY" python3 - >>"$EVENTS" <<'PY'
import json, os
print(json.dumps({"ts":os.environ["TS_E"],"source":os.environ["SRC_E"],
    "ref":os.environ["LINE_E"][:180],"query":os.environ["QUERY_E"][:120]}, ensure_ascii=False))
PY
    done <<< "$block"
}
append_events "second_brain" "$SHARED_HITS"
append_events "passive" "$LOCAL_HITS"

# --- 5) materialise working-set.md (overwrite: it's a view) ------------------
if [ -z "$SHARED_HITS" ] && [ -z "$LOCAL_HITS" ]; then
    log "no hits; working-set left as-is"
    exit 0
fi
TS=$(date -u +%Y-%m-%d\ %H:%M)
{
    echo "# Working set -- materialised recall @ ${TS} UTC"
    echo ""
    echo "_Regenerated each session by working-set-build.sh from the query above._"
    echo ""
    if [ -n "$SHARED_HITS" ]; then
        echo "## Recalled from second_brain (shared)"
        echo ""
        echo "$SHARED_HITS"
        echo ""
    fi
    if [ -n "$LOCAL_HITS" ]; then
        echo "## Recalled from passive (local)"
        echo ""
        echo "$LOCAL_HITS"
        echo ""
    fi
} > "$WORKING_SET"
log "working-set materialised (shared=$( [ -n "$SHARED_HITS" ] && echo yes || echo no ), local=$( [ -n "$LOCAL_HITS" ] && echo yes || echo no ))"
exit 0
