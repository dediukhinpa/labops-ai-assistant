#!/usr/bin/env bash
set -euo pipefail

# active-writer.sh -- episodic memory writer.
#
# Appends one entry to core/active/episodic.md (the raw, append-only "diary" of
# turns) tagged with a salience class computed by a pure-bash heuristic. No model
# call (`claude -p` is forbidden repo-wide) -- the final, richer judgement of
# importance is made later by the live session during reflection.
#
# Salience classes: ephemeral | error | decision | preference | fact
#
# Usage:
#   printf '%s' "<text>" | active-writer.sh --source stop-hook
#   active-writer.sh --source channel --text "some turn text"
#   classify_salience "<text>"            # (when sourced) -> prints the class
#
# Env:
#   AGENT_WORKSPACE  absolute path to the .claude workspace (default: derive)
#   MEMORY_SNIPPET_MAX  snippet length cap (default 200)
#
# Fail-open: never blocks a hook -- any error exits 0.

readonly SNIPPET_MAX="${MEMORY_SNIPPET_MAX:-200}"

# classify_salience TEXT -> echoes one class. Order matters (most specific first).
classify_salience() {
    local text="${1:-}"
    # Normalise: lowercase, collapse whitespace, strip surrounding punctuation.
    local lc trimmed
    lc="$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]' | tr '\n' ' ')"
    trimmed="$(printf '%s' "$lc" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"

    # ephemeral: short acknowledgements with no substance
    if [ "${#trimmed}" -lt 15 ] && printf '%s' "$trimmed" \
        | grep -qE '^(ok(ay)?|ок|thanks|thank you|спасибо|спс|yes|no|да|нет|got it|понял|принято|sure|ага|угу|👍|👌|✅|\+)\.?!?$'; then
        echo "ephemeral"; return 0
    fi
    # error: something broke
    if printf '%s' "$trimmed" \
        | grep -qE 'error|fail(ed|ure)?|exception|traceback|crash|broke|broken|\bbug\b|ошибк|сбой|упал|не работает|не сработал'; then
        echo "error"; return 0
    fi
    # decision: a choice was made / agreed
    if printf '%s' "$trimmed" \
        | grep -qE 'decid|decision|resolved|решено|решили|договорились|выбрал|выбрали|остановились на|принял(и)? решение|let'\''?s use|we'\''?ll use|will use|go with|берём|возьмём'; then
        echo "decision"; return 0
    fi
    # preference: a durable liking / rule about how to work
    if printf '%s' "$trimmed" \
        | grep -qE 'prefer|предпочит|не люблю|люблю когда|always|never|всегда|никогда|по умолчанию|default to|правило:|rule:'; then
        echo "preference"; return 0
    fi
    echo "fact"
}

# extract_snippet -- read a payload (JSON or raw) on stdin, emit a <=SNIPPET_MAX
# single-line snippet. Mirrors the extraction stop-hook.sh used inline.
extract_snippet() {
    local payload; payload="$(cat || true)"
    PAYLOAD_E="$payload" MAXLEN="$SNIPPET_MAX" python3 - <<'PY' 2>/dev/null
import json, os
raw = os.environ["PAYLOAD_E"]
maxlen = int(os.environ["MAXLEN"])
text = ""
try:
    obj = json.loads(raw)
    for key in ("assistant_response", "summary", "last_message", "transcript", "text"):
        v = obj.get(key)
        if isinstance(v, str) and v.strip():
            text = v.strip(); break
    if not text and isinstance(obj.get("messages"), list):
        for m in reversed(obj["messages"]):
            if isinstance(m, dict) and isinstance(m.get("content"), str):
                text = m["content"].strip(); break
except Exception:
    text = raw.strip()
print(text.replace("\n", " ")[:maxlen])
PY
}

main() {
    local source="agent" text=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --source) source="${2:-agent}"; shift 2 ;;
            --text)   text="${2:-}"; shift 2 ;;
            *) shift ;;
        esac
    done

    local ws script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    ws="${AGENT_WORKSPACE:-$(cd "$script_dir/.." && pwd)}"
    local episodic="$ws/core/active/episodic.md"
    mkdir -p "$(dirname "$episodic")"
    touch "$episodic"

    # Text may come via --text or be extracted from a stdin payload.
    if [ -z "$text" ]; then
        text="$(extract_snippet)"
    else
        text="$(printf '%s' "$text" | tr '\n' ' ')"
        text="${text:0:$SNIPPET_MAX}"
    fi
    [ -z "$text" ] && text="(turn ended; no text)"

    local salience ts
    salience="$(classify_salience "$text")"
    ts="$(date -u +%Y-%m-%d\ %H:%M)"

    {
        echo ""
        echo "### ${ts} [${source}] {${salience}}"
        echo ""
        echo "${text}"
    } >> "$episodic"
    return 0
}

# Only run main when executed directly (so tests can source classify_salience).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@" || exit 0
fi
