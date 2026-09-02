#!/usr/bin/env bash
set -euo pipefail

# Tests for working-set-build.sh -- local passive recall path (file-only, no
# second_brain), event logging, and the overlap threshold.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$SCRIPT_DIR/working-set-build.sh"

pass=0; fail=0
ok() { if [ "$1" = "0" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "  FAIL: $2"; fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
WS="$TMP/.claude"; mkdir -p "$WS/core/active" "$WS/core/passive"

cat > "$WS/core/passive/insights.md" <<'EOF'
---
id: aa11bb22
salience: decision
---
Recall uses pgvector cosine fused with Postgres FTS via RRF in the memory router.

---
id: cc33dd44
salience: fact
---
The Telegram channel sends a voice note to Groq whisper for transcription.
EOF

# query material seeded via handoff
printf 'working on pgvector recall router ranking\n' > "$WS/core/active/handoff.md"

echo "== builds working-set from local passive (no second_brain) =="
env -u SECOND_BRAIN_MEMORY_ROUTER_URL -u AGENT_BEARER \
    AGENT_WORKSPACE="$WS" AGENT_ID=nova bash "$BUILD"
ok $? "exit 0"
test -f "$WS/core/active/working-set.md"; ok $? "working-set.md created"
grep -q 'Recalled from passive' "$WS/core/active/working-set.md"; ok $? "has local section"
grep -qi 'pgvector' "$WS/core/active/working-set.md"; ok $? "matched note present"

echo "== handoff with only a heading is not query material =="
# На живом хосте свежий handoff.md состоял из одного заголовка. Проверка -s
# считала файл непустым, запросом становилась строка "# Active context ...",
# и откат на episodic не срабатывал: recall 45 дней искал по заголовку.
HWS="$TMP/heading"; mkdir -p "$HWS/core/active" "$HWS/core/passive"
cp "$WS/core/passive/insights.md" "$HWS/core/passive/insights.md"
printf '# Active context -- last 10 entries\n' > "$HWS/core/active/handoff.md"
printf '### 2026-09-02\n\nRouter ranking work on pgvector recall.\n' > "$HWS/core/active/episodic.md"
env -u SECOND_BRAIN_MEMORY_ROUTER_URL -u AGENT_BEARER \
    AGENT_WORKSPACE="$HWS" AGENT_ID=nova bash "$BUILD"
ok $? "exit 0 on heading-only handoff"
grep -q 'query: .*pgvector' "$HWS/logs/working-set.log"; ok $? "query falls back to episodic"
grep -qv 'Active context' "$HWS/logs/working-set.log"; ok $? "heading is not used as the query"

echo "== both sources empty of content leaves working-set untouched =="
EWS="$TMP/empty"; mkdir -p "$EWS/core/active" "$EWS/core/passive"
printf '# Active context -- last 10 entries\n' > "$EWS/core/active/handoff.md"
printf '### heading only\n' > "$EWS/core/active/episodic.md"
env -u SECOND_BRAIN_MEMORY_ROUTER_URL -u AGENT_BEARER \
    AGENT_WORKSPACE="$EWS" AGENT_ID=nova bash "$BUILD"
ok $? "exit 0 with no query material"
grep -q 'no query material' "$EWS/logs/working-set.log"; ok $? "says so in the log"

echo "== shared recall goes through the MCP handshake =="
# Одиночный tools/call FastMCP отвергает ("Missing session ID"); раньше отказ
# гасился молча и общий слой просто отсутствовал в рабочем наборе.
grep -q 'mcp_tools_call' "$BUILD"; ok $? "uses mcp_tools_call, not a bare curl"
grep -q 'mcp-call.sh' "$BUILD"; ok $? "sources the shared MCP client"
grep -q 'shared recall rejected' "$BUILD"; ok $? "logs a rejection instead of swallowing it"

echo "== non-matching note excluded (overlap threshold) =="
if grep -qi 'whisper' "$WS/core/active/working-set.md"; then ok 1 "unrelated note excluded"; else ok 0 "unrelated note excluded"; fi

echo "== episodic.md is never touched by recall =="
test ! -e "$WS/core/active/episodic.md" || [ ! -s "$WS/core/active/episodic.md" ]; ok $? "episodic untouched"

echo "== recall events logged =="
test -f "$WS/core/recall-events.jsonl"; ok $? "recall-events.jsonl exists"
tail -n1 "$WS/core/recall-events.jsonl" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); assert d["source"]=="passive"; assert d["ref"]'
ok $? "event line valid + source=passive"

echo ""
echo "working-set-build.test.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
