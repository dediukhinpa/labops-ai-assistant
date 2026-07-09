#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWEEP="$SCRIPT_DIR/decay-sweep.sh"
pass=0; fail=0
ok() { if [ "$1" = "0" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "  FAIL: $2"; fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
WS="$TMP/.claude"; mkdir -p "$WS/core/passive"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# note A: old + short half-life + never recalled  -> should be archived
# note B: fresh + never recalled                  -> should survive
# note C: old + short half-life BUT recalled       -> reinforced, survives
cat > "$WS/core/passive/insights.md" <<EOF
# Passive insights

---
id: aaa11111
created: 2020-01-01T00:00:00Z
last_recalled: 2020-01-01T00:00:00Z
recall_count: 0
half_life_days: 1
salience: fact
---
Old forgotten note about a one-off temporary thing nobody references again.

---
id: bbb22222
created: ${NOW}
last_recalled: ${NOW}
recall_count: 0
half_life_days: 14
salience: decision
---
Fresh decision to use pgvector RRF fusion for recall ranking.

---
id: ccc33333
created: 2020-01-01T00:00:00Z
last_recalled: 2020-01-01T00:00:00Z
recall_count: 0
half_life_days: 1
salience: preference
---
Operator prefers deploy announcements posted in Telegram before they begin.
EOF

# recall event that reinforces note C (ref matches its body prefix)
printf '%s\n' '{"ts":"'"$NOW"'","source":"passive","ref":"Operator prefers deploy announcements posted in Telegram before they begin.","query":"deploy telegram"}' \
  > "$WS/core/recall-events.jsonl"

echo "== run decay-sweep =="
AGENT_WORKSPACE="$WS" bash "$SWEEP"; ok $? "exit 0"

echo "== note A (old, unrecalled) archived =="
grep -q 'aaa11111' "$WS/core/passive/insights.md" && ok 1 "A removed from passive" || ok 0 "A removed from passive"
test -f "$WS/core/archived/superseded/insights.md" && grep -q 'aaa11111' "$WS/core/archived/superseded/insights.md"; ok $? "A moved to superseded"

echo "== note B (fresh) survives =="
grep -q 'bbb22222' "$WS/core/passive/insights.md"; ok $? "B kept"

echo "== note C (recalled) survives + reinforced =="
grep -q 'ccc33333' "$WS/core/passive/insights.md"; ok $? "C kept"
# recall_count bumped above 0 for note C
python3 - "$WS/core/passive/insights.md" <<'PY'
import re,sys
t=open(sys.argv[1]).read()
m=re.search(r'id: ccc33333.*?recall_count: (\d+)', t, re.S)
assert m and int(m.group(1))>=1, "C recall_count not reinforced"
PY
ok $? "C recall_count reinforced"

echo "== events consumed (truncated) =="
[ ! -s "$WS/core/recall-events.jsonl" ]; ok $? "recall-events.jsonl emptied"

echo ""
echo "decay-sweep.test.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
