---
name: memory-consolidate
description: Consolidate raw episodic memory into durable insights. Use when you receive a "Memory consolidation" reflection nudge (checkpoint every ~20 turns or after ~10 min idle), when core/active/consolidate.request exists, or when the operator asks you to "consolidate/reflect on memory". Reads new core/active/episodic.md entries and distils decisions, errors, preferences, and facts into core/passive/*, with provenance and decay metadata, dual-writing important knowledge to the shared second_brain.
allowed-tools: Read, Edit, Write, Bash(cat:*), Bash(date:*), Bash(sha256sum:*)
---

# Memory consolidation (episodic → passive)

Reflection is **synthesis, not summarisation**: you turn a raw diary of turns into
reusable *knowledge*. Do it yourself in-session — there is no background model.

## When this runs
- A `Memory consolidation` notification arrives (reason: `checkpoint` or `idle`), or
- `core/active/consolidate.request` is present (file-only fallback path), or
- The operator explicitly asks you to reflect.

## Procedure

1. **Find new material.** Read `core/passive/.consolidated-at` (an ISO timestamp; if
   missing, treat as epoch). Read `core/active/episodic.md` and take entries newer
   than that watermark. Each entry looks like:
   `### YYYY-MM-DD HH:MM [source] {salience}` followed by its text.

2. **Distil insights — don't copy.** Across the new entries, extract *conclusions*
   (e.g. not "operator asked about deploys" but "operator wants deploys announced in
   Telegram before they start"). Route by kind:
   - decision → `core/passive/decisions.md`
   - error / failure pattern → `core/passive/errors.md`
   - durable preference / working rule → `core/passive/preferences.md`
   - everything else worth keeping → `core/passive/insights.md`

3. **Add metadata.** Prepend each new insight with YAML frontmatter:
   ```yaml
   ---
   id: <first 8 of sha256 of the insight text>
   created: <ISO-8601 UTC>
   last_recalled: <same as created>
   recall_count: 0
   half_life_days: 14
   salience: decision|error|preference|fact
   provenance: [<episodic entry timestamps this was derived from>]
   ---
   ```
   Provenance keeps synthesis **reversible** — always point back to the raw entries.

4. **Recall before write (dedup).** Before adding an insight, check it does not
   already exist locally (grep passive/) and — if the shared brain is reachable —
   via `memory_router` recall. If it exists, reinforce instead of duplicate: bump
   `recall_count` and extend `half_life_days` on the existing note.

5. **Dual-write what matters.** For durable, shareable knowledge, also write to
   second_brain using the fixed tools per `SECONDBRAIN_WRITE_RULES.md`:
   `create_decision_note`, `create_error_pattern_note`, `create_preference` →
   `create_personal_note`, general → `create_project_note`. Write only within your
   `can_write_scopes`. Idempotent by sha256 — safe to re-run.

6. **Advance the watermark.** Write the current ISO-8601 UTC time to
   `core/passive/.consolidated-at`, and delete `core/active/consolidate.request`
   if it was present.

## Graceful degrade
If second_brain is unreachable (single-agent / file-only), do steps 1–4 and 6
locally and skip step 5 — note "shared layer off" in your reply. Never block.

## Boundaries
- `passive/*` is YELLOW (self-edit with justification); `episodic.md` is the source
  of truth for provenance — never rewrite or delete episodic entries here
  (archive-roll.sh handles rolling old slices out by size).
- Keep insights terse and de-duplicated: passive/ is loaded on demand, so churn is
  cheap but noise is expensive.
