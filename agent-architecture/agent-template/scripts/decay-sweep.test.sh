#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWEEP="$SCRIPT_DIR/decay-sweep.sh"
pass=0; fail=0
ok() { if [ "$1" = "0" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "  FAIL: $2"; fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
WS="$TMP/.claude"; mkdir -p "$WS/core/passive"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# note A: old + short half-life + never reinforced          -> should be archived
# note B: fresh + never reinforced                           -> should survive
# note C: old + short half-life BUT reinforced by consolidation -> survives
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
recall_count: 2
half_life_days: 1
salience: fact
---
Staging database is rebuilt from the nightly dump every Monday.
EOF

# Предпочтение владельца, старое и ни разу не подкреплённое. Будь это insights.md,
# оно ушло бы в архив; в preferences.md обязано остаться.
cat > "$WS/core/passive/preferences.md" <<EOF
# PREFERENCES

---
id: ddd44444
created: 2020-01-01T00:00:00Z
last_recalled: 2020-01-01T00:00:00Z
recall_count: 0
half_life_days: 1
salience: preference
---
Operator wants documents for people as .docx, without meta sections.
EOF
cp "$WS/core/passive/preferences.md" "$TMP/preferences.before"

echo "== run decay-sweep =="
AGENT_WORKSPACE="$WS" bash "$SWEEP"; ok $? "exit 0"

echo "== note A (old, never reinforced) archived =="
grep -q 'aaa11111' "$WS/core/passive/insights.md" && ok 1 "A removed from passive" || ok 0 "A removed from passive"
test -f "$WS/core/archived/superseded/insights.md" && grep -q 'aaa11111' "$WS/core/archived/superseded/insights.md"; ok $? "A moved to superseded"

echo "== note B (fresh) survives =="
grep -q 'bbb22222' "$WS/core/passive/insights.md"; ok $? "B kept"

echo "== note C (reinforced by consolidation) survives =="
grep -q 'ccc33333' "$WS/core/passive/insights.md"; ok $? "C kept"

echo "== preferences.md is never swept =="
cmp -s "$TMP/preferences.before" "$WS/core/passive/preferences.md"; ok $? "preferences.md unchanged"
[ ! -e "$WS/core/archived/superseded/preferences.md" ]; ok $? "nothing from preferences archived"

echo "== no recall-events journal is created =="
[ ! -e "$WS/core/recall-events.jsonl" ]; ok $? "recall-events.jsonl absent"

echo ""
echo "decay-sweep.test.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
