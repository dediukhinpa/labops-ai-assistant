# Memory System — active / passive / archive (role, not age)

`active` / `passive` / `archive` name a **role**, not an age. Consolidation is
**event-driven**, done by the live session (no background model -- `claude -p` is
forbidden repo-wide). The only cron is optional nightly pure-bash housekeeping.

## Overview

```
┌──────────────────────────────────────────┐
│  IDENTITY (manual only)                   │
│  CLAUDE.md + AGENTS + USER + rules        │
│  Always in context                        │
├──────────────────────────────────────────┤
│  ACTIVE (current-task working memory)        │
│  active/episodic.md  raw diary (on-demand)   │
│  active/handoff.md   last 10 (in context)    │
├──────────────────────────────────────────┤
│  PASSIVE (semantic insights)                 │
│  passive/insights|decisions|errors|prefs.md  │
│  decisions+prefs in context; rest on demand  │
├──────────────────────────────────────────┤
│  ARCHIVE (cold storage, grows)              │
│  archived/episodic, archived/superseded   │
│  NOT in context, Read tool on demand      │
├──────────────────────────────────────────┤
│  L4 SEMANTIC (second_brain)                │
│  ${SECOND_BRAIN_MEMORY_ROUTER_URL}     │
│  NOT in context, curl on demand           │
└──────────────────────────────────────────┘
```

## Layer Details

### IDENTITY (always loaded)

| File | Purpose | Mutability |
|------|---------|-----------|
| CLAUDE.md | SOUL, character, workflow | Manual only |
| AGENTS.md | Models, subagents, pipelines | Manual only |
| USER.md | Operator profile | Agent on trigger (YELLOW) |
| rules.md | Rules learned from mistakes | Operator, or the agent when asked |
| TOOLS.md | Servers, Docker, services | Manual only |

### ACTIVE (current-task working memory)

- Files: `core/active/episodic.md`, `core/active/handoff.md`
- **episodic.md** — raw, append-only diary of turns, salience-tagged. Written by `active-writer.sh` (Stop hook). **Never model-compressed**; only size-rolled to `archived/episodic/`. On-demand Read (NOT loaded at startup).
- **handoff.md** — compact extract (last 10 entries) for continuity. Loaded via @include.
- WARNING: episodic.md grows to 80KB+ but is never in context; `archive-roll.sh` size-rolls it.

### ACTIVE episodic Format

```markdown
### 2026-04-08 15:03 [own_voice] [preference]
**Operator:** (transcription of voice message)
**Agent:** (response summary)

### 2026-04-08 15:10 [own_text] [decision]
**Operator:** text message here
**Agent:** response summary here
```

Salience classes: `ephemeral` | `error` | `decision` | `preference` | `fact`.

### PASSIVE (semantic insights)

- Files: `core/passive/insights.md`, `decisions.md`, `errors.md`, `preferences.md`
- Contains: consolidated SEMANTIC insights ("what I understood"), not raw events
- Written by: the **live session** during reflection (via the `memory-consolidate` skill), never a background model
- Each insight carries YAML frontmatter: `id`, `created`, `last_recalled`, `recall_count`, `half_life_days`, `salience`, `provenance`
- Decay: `decay-sweep.sh` (daily, from the Stop hook) evicts never-reinforced decayed insights to `archived/superseded/`; `preferences.md` never decays
- `decisions.md` and `preferences.md` are always in context via @include; `errors.md` / `insights.md` are read on demand

### ARCHIVE (cold storage)

- Files: `archived/episodic/`, `archived/superseded/`
- NOT loaded at startup
- Accessed via Read tool when needed
- Grows indefinitely; `archived/episodic/` = size-rolled diary, `archived/superseded/` = decayed insights

### L4 Semantic ([second_brain](https://github.com/volcengine/second_brain))

- Endpoints: `${SECOND_BRAIN_MEMORY_URL}` (write, default port 5001), `${SECOND_BRAIN_MEMORY_ROUTER_URL}` (recall, default port 5002), `${SECOND_BRAIN_AGENT_ROUTER_URL}` (swarm, default port 5000)
- NOT loaded at startup
- Accessed via curl (recall) when older context is needed
- Each agent has own namespace (User header)
- Search: `POST ${SECOND_BRAIN_MEMORY_ROUTER_URL}` (JSON-RPC tools/call recall)
- Stores embeddings of past conversations
- Install: `pip install second_brain --upgrade`

## Memory Operations (Flush, Compaction, Rotation)

### ACTIVE episodic write (every turn)

`active-writer.sh` (Stop hook) appends one salience-tagged entry after **every**
turn; the gateway may also append for gateway-driven turns:

```
User sends message -> Claude responds -> Stop hook -> append to core/active/episodic.md
```

- Format: `### YYYY-MM-DD HH:MM [source_tag] [salience]` + user snippet (200 chars) + agent snippet (200 chars)
- Salience via pure-bash heuristic (no model): `ephemeral | error | decision | preference | fact`
- File locking prevents interleaved writes from concurrent handlers
- Source tags: `own_text`, `own_voice`, `forwarded`, `external_media`
- **Append-only:** episodic is never model-compressed; it is the source of truth

### Size-roll (archive-roll.sh, not a trim)

Episodic is not truncated in place — it is **relocated**, so nothing is lost. When
`episodic.md` exceeds `EPISODIC_ROLL_KB` (default **40 KB**), `archive-roll.sh`
(nightly bash) moves the OLDER entries to `archived/episodic/YYYY-MM.md` and keeps
the recent tail, preserving entry boundaries (first `### ` header).

### /compact command (manual)

Operator sends `/compact` in Telegram:

```
1. Read core/active/episodic.md
2. Extract key facts from last 24h (decisions, preferences, pending actions)
3. ADD extracted facts to beginning of core/passive/decisions.md as:
   ## YYYY-MM-DD
   - fact 1
   - fact 2
4. Trim active/episodic.md: keep last 24h only
```

- Model: Sonnet (cheaper, fast enough for extraction)
- Timeout: 180 seconds
- Runs in background thread (non-blocking)

### /reset command (session reset)

Operator sends `/reset` in Telegram:

```
1. The next message starts a fresh session
2. The old session's history stays on disk (nothing is deleted or summarised)
```

- Nothing is saved to a separate archive file: decisions and preferences already
  live in `passive/` (loaded every session) and in second_brain.
- `/reset force` is accepted and behaves the same.

### Reflection: ACTIVE episodic -> PASSIVE insights (event-driven, no cron)

Consolidation is NOT a cron job and uses NO background model (`claude -p` is
forbidden repo-wide). Instead `reflect-nudge.sh` asks the **live session** to
reflect; the session runs the `memory-consolidate` skill, reads `episodic.md`, and
writes synthesised insights to `passive/*.md` (dual-writing important knowledge to
second_brain).

Triggers:
1. **Checkpoint** — every `MEMORY_CHECKPOINT_EVERY_N_TURNS` (default **20**) turns; the Stop hook counts turns and fires `reflect-nudge.sh --reason checkpoint`.
2. **Idle** — `watchdog.sh` detects **10 min** of silence (`MEMORY_IDLE_CONSOLIDATE_MIN`) and fires `reflect-nudge.sh --reason idle`.

Reflection is **synthesis of new knowledge**, not text compression. `episodic.md`
itself is never rewritten by a model — it is the append-only source of truth.

### Recall

There is no recall hook. Before a non-trivial task the agent queries the shared
brain itself (`memory_router` recall, as `CLAUDE.md` instructs), keyed on the real
task; `decisions.md` and `preferences.md` are already in context.

### Decay (decay-sweep.sh, daily bash)

Each insight in `passive/` has YAML frontmatter. `decay-sweep.sh` (pure bash +
Python arithmetic, no model) scores it `2^(-age_days / half_life_days)`; an insight
scoring below `DECAY_ARCHIVE_THRESHOLD` (default **0.25**) that was **never**
reinforced (`recall_count == 0`) moves to `archived/superseded/`. Reinforcement is
done by `memory-consolidate`: when an insight comes back, it bumps `recall_count`
and `half_life_days` on the existing note instead of writing a duplicate.
`preferences.md` is never swept -- a preference the agent follows never resurfaces
in the diary, so age alone would drop it about a month later.

Base `half_life_days` default **14** (`DECAY_HALF_LIFE_DAYS`).

### Episodic size-roll (archive-roll.sh, nightly bash)

When `episodic.md` exceeds `EPISODIC_ROLL_KB` (default **40** KB), `archive-roll.sh`
moves the OLDER entries to `archived/episodic/YYYY-MM.md` and keeps the recent tail
in place. Episodic text is **relocated, never summarised or lost** — pure bash, no
model.

### Recommended cron schedule (optional, pure bash, no model)

Consolidation needs no cron (it is event-driven). The only cron is optional nightly
housekeeping:

```crontab
# 1. Decay sweep: evict decayed insights -> archived/superseded/
0 3 * * * /path/to/decay-sweep.sh

# 2. Archive roll: size-roll episodic.md -> archived/episodic/YYYY-MM.md
5 3 * * * /path/to/archive-roll.sh
```

Was **4 model crons** (the old age-based hot→warm→cold compression/rotation jobs)
→ now **0 model crons + 1 optional bash housekeeping cron**; all model work happens
in the live session, on event.

## second_brain: Triggers and Data Flow

second_brain is written on the **write** path (dual-write of insights) and read on
demand by the agent itself (`memory_router` recall before a task). No batch upload script, no model cron.

### Method 1: Dual-write insights during in-session reflection (recommended)

When the live session reflects (nudged by `reflect-nudge.sh` at checkpoint/idle),
it writes each durable insight to both `passive/*.md` locally AND second_brain,
using the fixed write tools with recall-before-write:

| Trigger | When | How |
|---------|------|-----|
| **Checkpoint** | Every 20 turns (Stop counter) | `reflect-nudge.sh --reason checkpoint` → session consolidates |
| **Idle** | 10 min of silence (watchdog) | `reflect-nudge.sh --reason idle` → session consolidates |

**What the session does:**

```
1. Recall-before-write (avoid duplicating an existing note)
2. POST ${SECOND_BRAIN_MEMORY_URL} create_decision_note / create_error_pattern_note / ...
3. second_brain indexes content, creates embeddings automatically
4. The same insight is written locally to passive/*.md (with YAML frontmatter)
```

Dual-write rules are fixed in `SECONDBRAIN_WRITE_RULES.md` (RED zone): recall before
write; write immediately (compaction/session-end do NOT auto-flush); write only
within your `can_write_scopes`.

### Recall path

The agent calls `memory_router` recall itself before a non-trivial task; nothing
is materialised into a local file.

### Method 2: Real-time push from gateway (optional)

Gateway can push to second_brain after **every message** where:

| Source tag | Pushed to OV? | Reason |
|------------|---------------|--------|
| `own_text` | Yes | Operator's own words — extract preferences, decisions |
| `own_voice` | Yes | Same as text (after Groq transcription) |
| `forwarded` | Yes (with guard) | Third-party content — extract events, NOT user preferences |
| `external_media` | No | Media only goes to ACTIVE, not OV (avoids pollution) |
| transcription failed | No | Broken audio — skip to avoid garbage |

**Anti-pollution guards** for forwarded content:

- **Forwarded:** `[extraction hint: this content was FORWARDED ... Do NOT extract as user's own preferences]`
- **External media:** `[extraction hint: this is external media ... Do NOT extract as user's preferences]`

**Threading model:**
- Push runs in a **bounded ThreadPoolExecutor** (max 2 workers)
- Fire-and-forget: does not block message response

### Searching second_brain

Both methods produce embeddings searchable via the same API:

```bash
curl -X POST "${SECOND_BRAIN_MEMORY_ROUTER_URL}" \
  -H "X-API-Key: $KEY" \
  -H "X-second_brain-Account: $ACCOUNT" \
  -H "X-second_brain-User: $AGENT" \
  -d '{"query": "topic", "limit": 10}'
```

**Note:** `${SECOND_BRAIN_MEMORY_ROUTER_URL}` defaults to `http://${MCP_HOST}:5002/mcp`. For multi-VPS setups, set `MCP_HOST` to the Tailscale IP of the server running second_brain, or override `SECOND_BRAIN_MEMORY_ROUTER_URL` directly.

## Data Priority

1. Real system checks (exec) — ground truth
2. ACTIVE/PASSIVE (in context) — navigation
3. ARCHIVE (Read tool) — archive
4. second_brain L4 (curl) — semantic search
5. Web search (Perplexity) — internet

## Token Budget

### Token counting rules

BPE tokenizers split Cyrillic characters into more tokens than Latin. If your agent operates in a non-Latin language, token counts will be significantly higher than byte counts suggest.

| Content type | Tokens per byte | Why |
|-------------|----------------|-----|
| Russian text (Cyrillic) | ~0.45 | Each Cyrillic char = 2 bytes UTF-8, often 1 token per char |
| English text (Latin) | ~0.25-0.30 | ASCII chars pack efficiently into BPE tokens |
| Mixed markdown/code | ~0.25 | Code keywords and markdown syntax tokenize well |

This means a 10 KB file in Russian consumes ~4,500 tokens, while the same 10 KB in English consumes ~2,500-3,000 tokens. Plan accordingly.

### Per-file budget (detailed)

| Component | Typical Size | Tokens (Russian) | Tokens (English) |
|-----------|-------------|-------------------|-------------------|
| Global CLAUDE.md | ~8 KB | ~3,600 | ~2,400 |
| Project CLAUDE.md | ~8 KB | ~3,600 | ~2,400 |
| AGENTS.md | ~6 KB | ~2,700 | ~1,800 |
| USER.md | ~2 KB | ~900 | ~600 |
| rules.md | ~5 KB | ~2,250 | ~1,500 |
| TOOLS.md | ~6 KB | ~2,700 | ~1,800 |
| Language rules (rules/*.md) | ~3 KB | ~1,350 | ~900 |
| **IDENTITY subtotal** | **~38 KB** | **~17,100** | **~11,400** |
| PASSIVE insights + decisions/errors/prefs | 3-15 KB | 1,350-6,750 | 900-4,500 |
| ACTIVE handoff.md (loaded) | 1-4 KB | 450-1,800 | 300-1,200 |
| ACTIVE episodic.md (NOT loaded, on-demand) | 5-80 KB | — | — |

IDENTITY is fixed cost -- it loads every session regardless. PASSIVE and the loaded
ACTIVE file (handoff) are variable; `episodic.md` is never loaded
into context (on-demand Read only), so its size does not enter the startup budget.

### Three load scenarios

**Scenario 1: Consolidated state (optimal)**

Reflection has run recently. Insights consolidated in PASSIVE (~3 KB), handoff
(~2 KB), episodic on-demand only.

```
IDENTITY: 17,100 + PASSIVE: 1,350 + ACTIVE loaded (handoff): 1,800 = 20,250 tokens (~5% of 400K working context)
```

This is the target operating state. The agent starts each session with clean, focused context.

**Scenario 2: Long busy session (loaded)**

Active day with 150+ messages. `episodic.md` grew to ~80 KB but is NOT loaded;
PASSIVE accumulated insights from several reflections.

```
IDENTITY: 17,100 + PASSIVE: 6,750 + ACTIVE loaded: 3,600 = 27,450 tokens (~7% of 400K working context)
```

Still clean, because the raw episodic diary never enters context. Checkpoint
reflection (every 20 turns) keeps insights fresh.

**Scenario 3: No reflection + episodic accidentally loaded (worst case)**

If an operator Reads the full `episodic.md` (~200 KB) into context and never lets
reflection run:

```
IDENTITY: 17,100 + PASSIVE: 6,750 + episodic in context: 90,000 = 113,850 tokens (~29% of 400K working context)
```

Agent noticeably ignores instructions buried in IDENTITY. Fix: keep `episodic.md`
on-demand (it is not @include'd), let reflection consolidate, and let
`archive-roll.sh` size-roll the diary.

### Key insight

The base context window is 1M tokens, but we set `CLAUDE_CODE_AUTO_COMPACT_WINDOW=400000` because model quality degrades well before 1M. The **working context is 400K**. The memory system exists not to save money but to keep context CLEAN -- an agent carrying 80 KB of raw conversation logs performs worse than one with a few KB of structured insights, because attention is finite even when context is not. That is why the raw episodic diary is never loaded and reflection distils it into compact insights.

### Reference limits

- Opus 4.6 / Sonnet 4.6 base context window: 1,000,000 tokens
- Working context (via CLAUDE_CODE_AUTO_COMPACT_WINDOW): 400,000 tokens
- CLAUDE.md recommended size: under 200 lines (beyond that Claude starts ignoring instructions)
- @import max recursion depth: 5 hops
- In-session reflection (memory-consolidate skill) keeps PASSIVE compact by synthesising insights; episodic.md is never model-compressed, only size-rolled by archive-roll.sh
