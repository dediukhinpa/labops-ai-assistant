# Memory System — active / passive / archive (role, not age)

`active` / `passive` / `archive` name a **role**, not an age. Consolidation is
**event-driven** and done by the live session (no background model -- `claude -p` is
forbidden repo-wide). Housekeeping is pure bash, started by the Stop hook once a day;
no cron is needed.

File-by-file reference: [FILES-REFERENCE.md](FILES-REFERENCE.md).

## Overview

```
┌─────────────────────────────────────────────────────┐
│  IDENTITY & RULES (always in context)                │
│  CLAUDE.md, core/USER.md, core/rules.md,             │
│  SECONDBRAIN_WRITE_RULES.md, AGENT_ROUTER.md         │
│  (core/AGENTS.md, tools/TOOLS.md -- on demand)       │
├─────────────────────────────────────────────────────┤
│  ACTIVE (current-task working memory)                │
│  active/episodic.md   raw diary        (on demand)   │
├─────────────────────────────────────────────────────┤
│  PASSIVE (distilled knowledge)                       │
│  decisions.md, preferences.md          (in context)  │
│  errors.md, insights.md                (on demand)   │
├─────────────────────────────────────────────────────┤
│  ARCHIVE                                             │
│  archived/episodic, archived/superseded (on demand)  │
├─────────────────────────────────────────────────────┤
│  L4 SHARED (second_brain)                            │
│  recall over MCP, shared by every agent              │
└─────────────────────────────────────────────────────┘
```

## Which file for what

The question that decides where something goes:

| Question | File | Written by |
|----------|------|-----------|
| Who is the operator? (name, address, timezone, language, channels) | `core/USER.md` | operator, or the agent when asked |
| What must I always / never do? (an order to myself) | `core/rules.md` | only with the operator's consent |
| What did we choose, when and why? | `core/passive/decisions.md` | memory-consolidate |
| What broke, why, and how not to repeat it? | `core/passive/errors.md` | memory-consolidate |
| How does the operator want work done? | `core/passive/preferences.md` | memory-consolidate |
| Any other durable fact? | `core/passive/insights.md` | memory-consolidate |
| What happened this turn? | `core/active/episodic.md` | Stop hook |

The pairs that look alike:

- **USER.md vs preferences.md.** "Address me as Alex, I write in Russian" is who the
  operator *is* -> `USER.md`. "Documents for people go in .docx without meta
  sections" is how they *want work done* -> `preferences.md`.
- **rules.md vs decisions.md.** "We moved recall to int8 embeddings on 2026-09-02
  because the full model hit MemoryMax" is a recorded *choice* -> `decisions.md`; it
  ages out. "Never restart a unit without a backup" is an *order* to the agent ->
  `rules.md`; it stays until the operator removes it.
- **errors.md vs rules.md.** The first time something breaks, the lesson goes to
  `errors.md`. When the same correction comes back, the agent *proposes* a rule and
  writes it to `rules.md` only after the operator agrees.

There is no `LEARNINGS.md` or `core/MEMORY.md`: both were removed, their roles are
covered by `errors.md` + `rules.md` and by `core/archived/`.

## Layer Details

### IDENTITY & RULES

| File | Purpose | Loads | Mutability |
|------|---------|-------|-----------|
| CLAUDE.md | SOUL, character, zones, channel and shared-brain duties | always | operator |
| core/USER.md | Who the operator is | always | operator; agent when asked |
| core/rules.md | Orders to self, earned from mistakes (empty at install) | always | operator; agent after consent |
| SECONDBRAIN_WRITE_RULES.md | What to write to the shared brain | always | operator (RED) |
| AGENT_ROUTER.md | Handing work to other agents | always | operator |
| core/AGENTS.md | Models, pipelines, team | on demand | operator; agent on a trigger |
| tools/TOOLS.md | Infrastructure map | on demand | operator; agent on a trigger |

### ACTIVE

- **episodic.md** — raw, append-only diary of turns, salience-tagged. Written by
  `active-writer.sh` from the Stop hook. **Never model-compressed**; only size-rolled
  to `archived/episodic/`. Read on demand, never loaded at startup.
- **pre-compact/** — copies of `episodic.md` taken before each compaction (newest 10).

Entry format:

```markdown
### 2026-09-15 17:19 [stop-hook] {fact}
<turn text, capped at MEMORY_SNIPPET_MAX = 200 chars>
```

`source` is the writer; salience is a pure-bash guess (`ephemeral | error | decision |
preference | fact`), the session makes the real call during consolidation.

### PASSIVE

- Files: `decisions.md`, `preferences.md` (always in context), `errors.md`,
  `insights.md` (on demand).
- Contains distilled knowledge ("what I understood"), not raw events.
- Written by the **live session** through the `memory-consolidate` skill.
- Each entry carries YAML frontmatter: `id`, `created`, `last_recalled`,
  `recall_count`, `half_life_days`, `salience`, `provenance`.
- `core/passive/.consolidated-at` is the watermark: diary entries older than it are
  already processed.

### ARCHIVE

- `archived/episodic/YYYY-MM.md` — diary entries rolled out by size.
- `archived/superseded/` — passive entries that decayed without being recalled.
- Not loaded; read by hand when history matters.

### L4 SHARED (second_brain)

- Four MCP servers: memory `:5001` (writes), memory_router `:5002` (recall),
  agent_router `:5000` (events), tasks `:5003` (task board).
- Per-agent Bearer token; writes succeed only inside the token's scopes.
- Recall is hybrid (vectors + full text, fused with RRF), weighted by note type and
  freshness. Everything one agent writes, the others can find.

## Memory Operations

### Diary write (every turn)

```
User message -> Claude answers -> Stop hook -> active-writer.sh -> episodic.md
```

The same Stop hook writes one JSON line to `logs/verbose-YYYY-MM-DD.jsonl` and counts
turns for the checkpoint below.

### Consolidation: ACTIVE -> PASSIVE (event-driven)

`reflect-nudge.sh` asks the **live session** to reflect -- through
`agent_router.notify`, or a `core/active/consolidate.request` marker when notify is
down. The session runs `memory-consolidate`: reads diary entries newer than the
watermark, distils them into `passive/*.md`, dual-writes what matters to
second_brain, and advances the watermark.

Triggers:
1. **Checkpoint** — every `MEMORY_CHECKPOINT_EVERY_N_TURNS` (default **20**) turns,
   from the Stop hook.
2. **Idle** — `watchdog.sh` after **10 min** of silence
   (`MEMORY_IDLE_CONSOLIDATE_MIN`).
3. **On request** — the operator asks the agent to consolidate.

Reflection is **synthesis**, not compression: `episodic.md` itself is never
rewritten.

Dual-write mapping (a write needs the scope in the token; default scopes are
`decisions, knowledge, inbox, error-patterns, task-board, personal, projects, daily`):

| Local file | second_brain tool | Scope | Standard install |
|------------|-------------------|-------|------------------|
| decisions.md | `create_decision_note`, `supersede_decision` | `decisions` | yes |
| errors.md | `create_error_pattern_note` | `error-patterns` | yes |
| preferences.md | `create_personal_note` | `personal` | yes |
| insights.md (project/business) | `create_project_note` | `projects` | yes |

Adding scopes to a token is the operator's call.

### Decay (decay-sweep.sh, daily)

`decay-sweep.sh` (pure bash + Python arithmetic) scores each passive entry
`2^(-age_days / half_life_days)`. An entry below `DECAY_ARCHIVE_THRESHOLD` (default
**0.25**) that was **never** reinforced (`recall_count == 0`) moves to
`archived/superseded/`. Reinforcement is done by `memory-consolidate`: when an insight
comes back, it bumps `recall_count` and `half_life_days` on the existing entry instead
of writing a duplicate. `preferences.md` is never swept -- a preference the agent
follows never resurfaces in the diary, so age alone would drop it.

Base `half_life_days`: **14** -- written into each entry's frontmatter by
`memory-consolidate`; `decay-sweep.sh` falls back to 14 when it is missing.

### Size-roll (archive-roll.sh, daily)

When `episodic.md` exceeds `EPISODIC_ROLL_KB` (default **40 KB**), the OLDER entries
move to `archived/episodic/YYYY-MM.md` and the recent tail stays, split on entry
boundaries. Text is relocated, never summarised.

Both jobs run from the Stop hook at most once per
`MEMORY_HOUSEKEEPING_INTERVAL_SEC` (default 86400).

### Compaction and session end

- **PreCompact** — snapshot of `episodic.md` to `core/active/pre-compact/`, then
  `brain-flush.sh --reason precompact`.
- **SessionEnd** — `brain-flush.sh --reason session-end`.

`brain-flush.sh` sends the diary tail to second_brain `inbox/`
(`create_handoff`), skipping when nothing changed since the last flush. It is a safety
net, not a substitute for writing decisions as they happen.

### /reset force (Telegram)

```
1. The plugin files a reset request
2. The watchdog waits for the current turn to end and types /clear into the session
3. SessionEnd fires -> brain-flush.sh
4. The watchdog confirms via hooks.log and replies in Telegram
```

Memory files are not touched; only the context is cleared. There is no `/compact`
command in the channel.

### Recall

There is no recall hook. Before a non-trivial task the agent calls `recall` on
memory_router itself, keyed on the real task; `decisions.md` and `preferences.md` are
already in context. Calls go through the MCP servers in `.mcp.json`; scripts use
`scripts/mcp-call.sh`, which performs the required `initialize` handshake.

## Data Priority

1. Live checks (exec, grep) — ground truth
2. second_brain — shared memory
3. git history
4. Local memory (ACTIVE / PASSIVE / ARCHIVE) — navigation

Memory that contradicts a live check is wrong and gets fixed.

## Token Budget

### Token counting rules

BPE tokenizers split Cyrillic into more tokens than Latin.

| Content type | Tokens per byte |
|-------------|----------------|
| Russian text (Cyrillic) | ~0.45 |
| English text (Latin) | ~0.25-0.30 |
| Mixed markdown/code | ~0.25 |

### What loads every session

| Component | Size at install | Tokens (~) |
|-----------|-----------------|------------|
| ~/.claude/CLAUDE.md + rules/*.md | ~3 KB | ~800 |
| CLAUDE.md (SOUL) | ~5 KB | ~1,300 |
| core/USER.md + core/rules.md | ~1 KB | ~300 |
| SECONDBRAIN_WRITE_RULES.md (Russian) | ~6 KB | ~2,600 |
| AGENT_ROUTER.md (Russian) | ~10 KB | ~4,600 |
| **Fixed subtotal** | **~25 KB** | **~9,600** |
| passive/decisions.md + preferences.md | grows: ~17 KB after two months on a live agent | ~7,700 |

Not loaded, whatever their size: `episodic.md` (tens of KB a day), `errors.md`,
`insights.md`, `archived/`, `core/AGENTS.md`, `tools/TOOLS.md`.

`decisions.md` is the part that grows unattended: keep entries terse, and let
`decay-sweep.sh` retire the ones nobody recalls.

### Why the diary stays out of context

The base context window is 1M tokens, but agents run with
`CLAUDE_CODE_AUTO_COMPACT_WINDOW=400000` because quality degrades well before 1M.
The memory system exists not to save money but to keep context **clean**: an agent
carrying tens of KB of raw conversation follows its instructions worse than one with
a few KB of distilled knowledge.

### Reference limits

- Working context (`CLAUDE_CODE_AUTO_COMPACT_WINDOW`): 400,000 tokens
- CLAUDE.md: keep under ~200 lines -- beyond that instructions start being ignored
- `@import` max recursion depth: 5 hops
