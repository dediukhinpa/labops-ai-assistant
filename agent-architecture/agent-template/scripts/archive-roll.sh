#!/usr/bin/env bash
set -euo pipefail

# archive-roll.sh -- size-roll the episodic diary. Pure bash+python, NO model call.
#
# When core/active/episodic.md exceeds EPISODIC_ROLL_KB, the OLDER entries are moved
# to core/archived/episodic/YYYY-MM.md and the recent tail is kept in place. The
# file header (lines before the first "### ") is preserved. Episodic text is never
# summarised or lost -- only relocated. Fail-open.
#
# Env: AGENT_WORKSPACE, EPISODIC_ROLL_KB (default 40)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="${AGENT_WORKSPACE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
EPISODIC="$WS/core/active/episodic.md"
ARCHIVE_DIR="$WS/core/archived/episodic"
LOGDIR="$WS/logs"; mkdir -p "$LOGDIR" "$ARCHIVE_DIR"
LOG="$LOGDIR/archive-roll.log"
ROLL_KB="${EPISODIC_ROLL_KB:-40}"
MONTH="$(date -u +%Y-%m)"

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [archive-roll] $1" >> "$LOG"; }

[ -f "$EPISODIC" ] || { log "no episodic.md; skip"; exit 0; }
SIZE_KB=$(( $(wc -c < "$EPISODIC") / 1024 ))
if [ "$SIZE_KB" -lt "$ROLL_KB" ]; then
    log "episodic ${SIZE_KB}KB < ${ROLL_KB}KB; skip"
    exit 0
fi

MOVED=$(EPISODIC_E="$EPISODIC" ARCHIVE_E="$ARCHIVE_DIR/$MONTH.md" KEEP_E="$ROLL_KB" python3 - <<'PY'
import os
path = os.environ["EPISODIC_E"]
archive = os.environ["ARCHIVE_E"]
keep_bytes = int(os.environ["KEEP_E"]) * 1024 // 2   # keep ~half the threshold, recent

text = open(path, encoding="utf-8").read()
idx = text.find("\n### ")
if idx < 0:
    print(0); raise SystemExit(0)
header = text[:idx+1]
rest = text[idx+1:]

# split into entries at "### " boundaries, preserving order (oldest -> newest)
entries, cur = [], []
for line in rest.splitlines(keepends=True):
    if line.startswith("### ") and cur:
        entries.append("".join(cur)); cur = [line]
    else:
        cur.append(line)
if cur:
    entries.append("".join(cur))

# keep newest entries until we hit keep_bytes; older ones roll out
kept, total = [], 0
for e in reversed(entries):
    total += len(e.encode("utf-8"))
    if total <= keep_bytes or not kept:
        kept.append(e)
    else:
        kept.append(e); break_at = len(kept); break
else:
    print(0); raise SystemExit(0)  # everything fit; nothing to roll

kept_entries = list(reversed(kept))
n_keep = len(kept_entries)
moved = entries[:len(entries) - n_keep]
if not moved:
    print(0); raise SystemExit(0)

with open(archive, "a", encoding="utf-8") as fh:
    fh.write("".join(moved).rstrip() + "\n")
open(path, "w", encoding="utf-8").write(header + "".join(kept_entries))
print(len(moved))
PY
) || { log "python roll failed (fail-open)"; exit 0; }

log "rolled ${MOVED} entries -> archived/episodic/${MONTH}.md (was ${SIZE_KB}KB)"
exit 0
