#!/usr/bin/env bash
# Stop hook: self-improvement loop. When the Boss corrected the agent this turn,
# nudge the agent to record ONE error-pattern note in second_brain (memory MCP). The
# agent makes the final judgment and the write; this hook only decides WHEN to
# ask, gated on cheap correction signals so it never taxes ordinary turns.
#
# Stop hook contract (Claude Code): stdin = JSON {stop_hook_active, transcript_path}.
# Output {"decision":"block","reason":...} makes Claude continue with `reason`.
# Fail-open everywhere: any parse/IO problem -> exit 0 silently, never wedge a turn.
set -uo pipefail

AGENT="${1:-unknown}"
INPUT="$(cat)"

# --- Loop guard: if THIS stop was itself triggered by a hook block, do not
# re-trigger, or the agent can never finish. ---
ACTIVE="$(printf '%s' "$INPUT" | python3 -c \
  'import sys,json; print(json.load(sys.stdin).get("stop_hook_active", False))' 2>/dev/null || echo True)"
[ "$ACTIVE" = "True" ] && exit 0

TRANSCRIPT="$(printf '%s' "$INPUT" | python3 -c \
  'import sys,json; print(json.load(sys.stdin).get("transcript_path",""))' 2>/dev/null || echo "")"
[ -z "$TRANSCRIPT" ] && exit 0
[ ! -f "$TRANSCRIPT" ] && exit 0

# --- Pull the most recent user-authored message text from the JSONL transcript. ---
LASTUSER="$(python3 - "$TRANSCRIPT" <<'PY' 2>/dev/null || true
import json, sys
last = ""
for line in open(sys.argv[1], encoding="utf-8", errors="ignore"):
    line = line.strip()
    if not line:
        continue
    try:
        ev = json.loads(line)
    except Exception:
        continue
    msg = ev.get("message") or {}
    if (ev.get("type") == "user") or (msg.get("role") == "user"):
        c = msg.get("content", "")
        if isinstance(c, list):
            c = " ".join(b.get("text", "") for b in c if isinstance(b, dict))
        last = c if isinstance(c, str) else str(c)
print(last)
PY
)"
[ -z "$LASTUSER" ] && exit 0

# --- Cheap correction-signal gate (RU + EN), case-insensitive. A miss is fine
# (night-learnings cron is the backstop); a false hit just costs one reflection
# turn where the agent decides "no correction" and stops. ---
SIGNALS='нет,|не так|неправильн|неверн|ошиб|исправ|почему ты|зачем ты|не надо|не нужно|не делай|перестань|зря|опять ты|ты опять|снова ты|ты не|ты забы|по-другому|это не то|слома|не работа|я же говорил|я уже говорил|сколько раз|actually,|wrong|incorrect|no,|should have|don.t do'
printf '%s' "$LASTUSER" | grep -qiE "$SIGNALS" || exit 0

# --- Nudge the agent to self-assess and record. The agent owns the decision. ---
cat <<'JSON'
{"decision":"block","reason":"Похоже, Оператор только что тебя поправил. Прежде чем закончить, оцени честно: была ли это коррекция твоего действия или подхода (а не уточнение, новая задача или благодарность)? Если ДА — вызови инструмент create_error_pattern_note (second_brain memory MCP) и запиши РОВНО ОДИН ёмкий урок: title (суть), category, severity, trigger_condition (когда ошибка повторится), prevention_rule (как не повторить), body (что произошло коротко), tags. Затем заверши. Если это НЕ коррекция — просто заверши, ничего не записывая. Не записывай больше одного урока и не дублируй уже существующие."}
JSON
