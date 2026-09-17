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
   Telegram before they start"). Route each one by the first question it answers "yes":

   | Question | File | Example |
   |---|---|---|
   | Did we **choose** something about the project/system, with a reason? | `core/passive/decisions.md` | "2026-09-02: switched recall to int8 embeddings — the full model hit MemoryMax" |
   | Did something **break**, and do we now know the cause and how to avoid it? | `core/passive/errors.md` | "Stop hook wrote empty turns: the payload key is `last_assistant_message`" |
   | Is it **how the operator wants work done** — style, format, process? | `core/passive/preferences.md` | "Documents for people: .docx, no meta sections, explain terms in place" |
   | Anything else durable and useful later? | `core/passive/insights.md` | "An empty episodic.md alone does not mean the hook is broken" |

   Not yours to write here:
   - **Who the operator is** (name, address, timezone, language, channels) is
     `core/USER.md` — edited by the operator, or by you when they ask.
   - **An imperative rule for your own behaviour** ("always… / never…") is
     `core/rules.md` (RED). Consolidation never writes it: when the same correction
     shows up a second time, *propose* the rule in your reply and add it only after
     the operator agrees. A preference says what the operator likes; a rule says what
     you must do.
   - A decision is a fact about the world with a date; a rule is an order to
     yourself. "We chose X" → decisions; "I must X" → proposed rule.

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
   second_brain using the fixed tools per `SECONDBRAIN_WRITE_RULES.md`. Each tool
   writes to one scope, and the call fails unless that scope is in your token
   (`AGENT_SCOPES` in `agent.env` mirrors it) and the tool is in your tool list:

   | Local file | Tool | Scope | Works on a standard install |
   |---|---|---|---|
   | decisions.md | `create_decision_note` (`supersede_decision` to replace one) | `decisions` | yes |
   | errors.md | `create_error_pattern_note` | `error-patterns` | yes |
   | preferences.md | `create_personal_note` | `personal` | yes |
   | insights.md, from an external source | `create_external_note` (`source`, `url`) | `external` | no — the memory server runs the `core` tool set, keep it local |
   | insights.md, about the project/business | `create_project_note` | `projects` | yes |

   Scope or tool missing → keep the insight local and say so in your reply; never
   retry under another tool just to get it written. Idempotent by sha256 — safe to re-run.

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
- Keep insights terse and de-duplicated: `decisions.md` and `preferences.md` are
  loaded into every session, so noise there costs context on every turn;
  `errors.md` and `insights.md` are read on demand.
- `preferences.md` never ages out (decay-sweep.sh skips it) -- retire an entry only
  when the operator changes their mind, and say so in your reply.
