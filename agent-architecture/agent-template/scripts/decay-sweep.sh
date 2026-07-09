#!/usr/bin/env bash
set -euo pipefail

# decay-sweep.sh -- usage-driven forgetting for passive/ insights. Pure bash+python,
# NO model call. Nightly housekeeping (the one safety-net cron).
#
# Two steps over core/passive/*.md notes (frontmatter-tagged by memory-consolidate):
#   1) Reinforcement -- replay core/recall-events.jsonl: a note whose text was
#      recalled gets recall_count += hits, half_life_days *= 1.5 (capped), and
#      last_recalled bumped to now.
#   2) Decay -- score = 2^(-age_days / half_life_days) using last_recalled. A note
#      scoring < DECAY_ARCHIVE_THRESHOLD that was NEVER recalled (recall_count==0)
#      is moved to core/archived/superseded/<file>.
#
# Notes without frontmatter are left untouched. Fail-open.
#
# Env: AGENT_WORKSPACE, DECAY_ARCHIVE_THRESHOLD(0.25), DECAY_HALF_LIFE_MAX_DAYS(120)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="${AGENT_WORKSPACE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
PASSIVE_DIR="$WS/core/passive"
EVENTS="$WS/core/recall-events.jsonl"
SUPERSEDED="$WS/core/archived/superseded"
LOGDIR="$WS/logs"; mkdir -p "$LOGDIR" "$SUPERSEDED"
LOG="$LOGDIR/decay-sweep.log"
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [decay-sweep] $1" >> "$LOG"; }

[ -d "$PASSIVE_DIR" ] || { log "no passive/ dir; nothing to do"; exit 0; }

RESULT=$(PASSIVE_E="$PASSIVE_DIR" EVENTS_E="$EVENTS" SUPERSEDED_E="$SUPERSEDED" \
    NOW_E="$NOW_ISO" THR_E="${DECAY_ARCHIVE_THRESHOLD:-0.25}" \
    HLMAX_E="${DECAY_HALF_LIFE_MAX_DAYS:-120}" python3 - <<'PY'
import os, re, glob, json, math
from datetime import datetime, timezone

passive_dir = os.environ["PASSIVE_E"]
events_path = os.environ["EVENTS_E"]
superseded  = os.environ["SUPERSEDED_E"]
now = datetime.strptime(os.environ["NOW_E"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
threshold = float(os.environ["THR_E"])
hl_max = float(os.environ["HLMAX_E"])

def parse_iso(s, default=None):
    try:
        return datetime.strptime(s.strip(), "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except Exception:
        return default

# recalled passive refs (only source=passive events reinforce local notes)
refs = []
try:
    for line in open(events_path, encoding="utf-8"):
        line = line.strip()
        if not line:
            continue
        try:
            e = json.loads(line)
        except Exception:
            continue
        if e.get("source") == "passive" and e.get("ref"):
            refs.append(e["ref"].strip())
except FileNotFoundError:
    pass

NOTE_RE = re.compile(r'(?m)^---\n(.*?)\n---\n(.*?)(?=^---\n|\Z)', re.S)

def parse_fm(fm):
    d, order = {}, []
    for ln in fm.splitlines():
        m = re.match(r'^([A-Za-z_]+):\s?(.*)$', ln)
        if m:
            d[m.group(1)] = m.group(2); order.append(m.group(1))
    return d, order

def emit(fm_dict, order, body):
    lines = [f"{k}: {fm_dict[k]}" for k in order]
    return "---\n" + "\n".join(lines) + "\n---\n" + body

reinforced = archived = kept = 0
for path in sorted(glob.glob(os.path.join(passive_dir, "*.md"))):
    text = open(path, encoding="utf-8").read()
    matches = list(NOTE_RE.finditer(text))
    if not matches:
        continue
    survivors, moved = [], []
    # preserve any preamble before the first note (e.g. a title line)
    preamble = text[:matches[0].start()]
    for m in matches:
        fm, body = m.group(1), m.group(2)
        d, order = parse_fm(fm)
        if "recall_count" not in d or "half_life_days" not in d:
            survivors.append(emit(d, order, body) if order else m.group(0)); kept += 1; continue
        try:
            rc = int(float(d.get("recall_count", "0")))
            hl = float(d.get("half_life_days", "14"))
        except Exception:
            survivors.append(m.group(0)); kept += 1; continue
        body_l = body.lower()
        hits = sum(1 for r in refs if r and (r.lower()[:60] in body_l or body_l[:60] in r.lower()))
        if hits:
            rc += hits
            hl = min(hl * 1.5, hl_max)
            d["recall_count"] = str(rc)
            d["half_life_days"] = ("%g" % hl)
            d["last_recalled"] = now.strftime("%Y-%m-%dT%H:%M:%SZ")
            reinforced += 1
        # decay score off last_recalled (fallback created, fallback now)
        ref_t = parse_iso(d.get("last_recalled", ""), parse_iso(d.get("created", ""), now))
        age_days = max(0.0, (now - ref_t).total_seconds() / 86400.0)
        score = 2 ** (-age_days / hl) if hl > 0 else 0.0
        if score < threshold and rc == 0:
            moved.append(emit(d, order, body)); archived += 1
        else:
            survivors.append(emit(d, order, body)); kept += 1

    if moved:
        dest = os.path.join(superseded, os.path.basename(path))
        with open(dest, "a", encoding="utf-8") as fh:
            for note in moved:
                fh.write("\n" + note.rstrip() + "\n")
    new_text = preamble + "\n".join(s.rstrip() + "\n" for s in survivors)
    open(path, "w", encoding="utf-8").write(new_text)

# events consumed -> truncate the log so reinforcement is applied once
try:
    open(events_path, "w").close()
except Exception:
    pass

print(json.dumps({"reinforced": reinforced, "archived": archived, "kept": kept}))
PY
) || { log "python sweep failed (fail-open)"; exit 0; }

log "sweep: $RESULT"
exit 0
