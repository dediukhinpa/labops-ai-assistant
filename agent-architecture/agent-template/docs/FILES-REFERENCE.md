# Files Reference -- Complete Map

Every file in the agent workspace, its role, who fills it, when it loads, and access rules.

## Legend

- **Loads:** `always` = every session start, `on-demand` = Read tool / Skill tool, `never` = not loaded
- **Writer:** who creates/updates the file
- **Access:** who can read/modify

---

## Layer 1: Global (`~/.claude/`)

Shared across ALL agents on this machine. Loaded every session.

| File | Role | Loads | Writer | Access |
|------|------|-------|--------|--------|
| **CLAUDE.md** | Global rules, code conventions, git policy, project paths | always | operator (manual) | all agents read, only operator edits |
| **rules/bash.md** | Bash coding standards: `set -euo pipefail`, quoting | always | operator (manual) | all agents read, only operator edits |
| **rules/python.md** | Python standards: type hints, pathlib, Google docstrings | always | operator (manual) | all agents read, only operator edits |
| **rules/typescript.md** | TS standards: strict, no any, Zod, interfaces | always | operator (manual) | all agents read, only operator edits |

**Who can touch:** Only the operator. Agents NEVER modify global files.

---

## Layer 2: Identity (`{workspace}/.claude/`)

Per-agent identity. Loaded every session via `@include` directives in CLAUDE.md.

| File | Role | Loads | Writer | Access |
|------|------|-------|--------|--------|
| **CLAUDE.md** | SOUL -- agent character, personality, principles, priorities, workflow rules. Contains `@include` directives that pull in other files | always | operator (manual) | agent reads, only operator edits |
| **core/AGENTS.md** | Operating rules: models, message bus paths, subagent config, cross-review rules, pipelines, analytics | on-demand (Read tool) | operator (manual) | agent reads, only operator edits |
| **core/USER.md** | Operator profile: name, timezone, channels, products, communication style | always (@include) | operator + agent (YELLOW) | agent updates with justification as operator evolves |
| **core/rules.md** | Boundaries: what agent can/cannot do, red zones, security, git policy, Telegram rules | always (@include) | operator (manual) | agent reads, only operator edits |
| **tools/TOOLS.md** | Infrastructure map: servers, SSH, Docker, systemd, ports, GitHub, secrets paths | on-demand (Read tool) | operator (manual) or agent with permission | agent reads, agent can suggest edits |

**Note:** AGENTS.md and TOOLS.md are NOT included at startup to save tokens (~18KB). Agents load them on-demand via Read tool when needed.

**Who can touch:** Operator only. These are the agent's constitution -- agent cannot self-modify identity.

---

## Layer 3: Memory -- PASSIVE (`core/passive/`)

Consolidated **semantic insights** (role, not age). Written by the live session
during reflection, never by a background model. Loaded every session.

| File | Role | Loads | Writer | Access |
|------|------|-------|--------|--------|
| **passive/insights.md** | Synthesised insights from reflection, each with YAML frontmatter (`id`, `created`, `last_recalled`, `recall_count`, `half_life_days`, `salience`, `provenance`) | always (@include) | **live session** (memory-consolidate skill) | agent reads/writes, decay-sweep prunes, operator can edit |
| **passive/decisions.md** | Architectural/operational decisions | always (@include) | **live session** (during reflection / when a decision is made), dual-written to second_brain | agent reads/writes, operator can edit |
| **passive/errors.md** | Error patterns and their fixes | always (@include) | **live session** (reflection) | agent reads/writes, operator can edit |
| **passive/preferences.md** | Operator preferences distilled from episodic | always (@include) | **live session** (reflection) | agent reads/writes, operator can edit |

**Lifecycle (event-driven, no model cron):**
1. `active-writer.sh` (Stop hook) appends raw turns to `active/episodic.md` -- never compressed.
2. Reflection is nudged in-session by `reflect-nudge.sh`: checkpoint every 20 turns (Stop counter) and watchdog idle 10 min. The **live session** reads `episodic.md` and writes insights to `passive/*.md` (via the `memory-consolidate` skill), dual-writing important knowledge to second_brain.
3. `decay-sweep.sh` (nightly, pure bash) reinforces recalled insights (`recall_count++`, `half_life_days *= 1.5`) and moves never-recalled decayed ones (`score < 0.25`) to `archived/superseded/`.

**Who can touch:** Live session (writes insights), decay-sweep (usage-driven pruning, no model), operator (full access).

---

## Layer 4: Memory -- ACTIVE (`core/active/`)

Current-task working memory (role, not age): the raw episodic diary plus the
materialised recall for the task. Loaded every session (except `episodic.md`).

| File | Role | Loads | Writer | Access |
|------|------|-------|--------|--------|
| **active/handoff.md** | Compact extract from episodic.md: last 10 conversation entries. Injected at session start for continuity without loading the full journal | always (@include) | **hook** (extracts last 10 from episodic.md at session start) | agent reads, hook writes |
| **active/working-set.md** | Materialised recall for the current task: shared second_brain recall (RRF) fused with local `passive/` lexical recall, with provenance/date tags | always (@include) | **working-set-build.sh** (SessionStart + UserPromptSubmit) | agent reads, hook writes |
| **active/episodic.md** | Raw, append-only diary of turns: timestamp, source tag, snippets, salience tag. **Never model-compressed** -- only size-rolled to `archived/episodic/` | on-demand (Read tool) | **active-writer.sh** (Stop hook, salience-tagged), gateway append | agent reads, hook/gateway append, archive-roll relocates |
| **recall-events.jsonl** | Log of every recall hit -- the reinforcement signal decay-sweep replays | never | **working-set-build.sh** (append) | decay-sweep reads |

**Entry format:**
```
### YYYY-MM-DD HH:MM [source_tag] [salience]
**Оператор:** user message snippet (200 chars max)
**Agent:** agent response snippet (200 chars max)
```

**Source tags:** `own_text`, `own_voice`, `forwarded`, `external_media`
**Salience classes:** `ephemeral` | `error` | `decision` | `preference` | `fact`

**Who can touch:** Stop hook / gateway (append episodic), working-set-build (writes working-set), archive-roll (relocates old episodic, no model), agent (read). Operator can edit.

---

## Layer 5: Memory -- ARCHIVE (`core/`)

Archive. NOT loaded into session context. Accessed via Read tool when needed.

| File | Role | Loads | Writer | Access |
|------|------|-------|--------|--------|
| **MEMORY.md** | Curated permanent archive. May contain months of history | on-demand (Read tool) | agent/operator (curated) | agent reads on-demand, operator edits |
| **LEARNINGS.md** | Lessons from mistakes: context, what went wrong, correct approach, rule | on-demand (Read tool) | agent (during session when learning occurs) | agent reads/writes, operator reads |
| **archived/episodic/YYYY-MM.md** | Size-rolled old episodic slices. Episodic text is relocated here, never summarised | never (manual Read) | **archive-roll.sh** (nightly bash, size-roll) | read-only archive |
| **archived/superseded/*.md** | Decayed/never-recalled insights evicted from `passive/` | never (manual Read) | **decay-sweep.sh** (nightly bash, usage-driven) | read-only archive |

**Who can touch:** Nightly pure-bash housekeeping (archive-roll relocates episodic, decay-sweep evicts decayed insights -- no model), agent (append learnings / curate MEMORY.md), operator (full access).

---

## Layer 6: Semantic Memory -- second_brain (L4)

External semantic database. NOT a file. Accessed via HTTP API.

| Resource | Role | Loads | Writer | Access |
|----------|------|-------|--------|--------|
| **second_brain://user/{agent}/memories/*** | Extracted semantic facts from conversations. LLM-powered extraction of preferences, decisions, entities (via second_brain memory MCP) | on-demand (curl) | **gateway.py** (`push_to_second_brain()` in background thread) | agent searches via curl, gateway writes |

**Anti-pollution guards:**
- `forwarded` messages -> "Do NOT extract as operator's own preferences"
- `external_media` -> "Not operator's own words"
- `own_text`/`own_voice` -> no guard (operator's direct words)

**Who can touch:** Gateway (write via API), agent (search via curl), second_brain service (manages storage).

---

## Layer 7: Skills (`skills/`)

Callable skills. NOT loaded at session start. Loaded on-demand when Skill tool invoked.

| Path | Role | Loads | Writer | Access |
|------|------|-------|--------|--------|
| **skills/{name}/SKILL.md** | Skill definition: frontmatter (description, triggers), instructions, `$ARGUMENTS` | on-demand (Skill tool) | developer (manual) | agent reads when skill called |
| **skills/{name}/*.sh** | Shell scripts used by skill | on-demand (skill execution) | developer (manual) | agent executes |
| **skills/{name}/*.py** | Python scripts used by skill | on-demand (skill execution) | developer (manual) | agent executes |

**Example skills:** groq-voice, superpowers, gws, youtube-transcript, twitter, quick-reminders, markdown-new, excalidraw, datawrapper, perplexity-research

**Who can touch:** Developer/operator creates skills. Agent can use but not modify.

---

## Layer 8: Subagent Definitions (`agents/`)

MD files defining subagent behavior. NOT loaded at session start. Used when Agent tool spawns subagent.

| Path | Role | Loads | Writer | Access |
|------|------|-------|--------|--------|
| **agents/{name}.md** | Subagent definition: frontmatter (`model:`, `description:`), instructions | on-demand (Agent tool) | developer (manual) | parent agent reads when spawning |

**Who can touch:** Developer/operator creates. Agent reads when spawning subagents.

---

## Layer 9: Scripts (`scripts/`)

Memory-engine helpers. NOT loaded into context. Fired by hooks/watchdog or an
optional nightly cron. All are pure bash (+ `curl`/`python3` arithmetic); none
calls a model -- `claude -p` is forbidden repo-wide.

| File | Role | Runs | Writer |
|------|------|------|--------|
| **active-writer.sh** | Append salience-tagged entry to `active/episodic.md` | Stop hook (each turn) | developer |
| **working-set-build.sh** | Rebuild `active/working-set.md` = second_brain recall (RRF, hard-timeout) + local `passive/` lexical recall; log to `recall-events.jsonl` | SessionStart + UserPromptSubmit | developer |
| **reflect-nudge.sh** | Nudge the **live session** to consolidate (via `agent_router.notify`); the session does the model work | checkpoint every 20 turns + watchdog idle 10 min | developer |
| **decay-sweep.sh** | Reinforce recalled insights; evict never-recalled decayed ones to `archived/superseded/` | optional nightly cron 03:00 | developer |
| **archive-roll.sh** | Size-roll `episodic.md` (>40 KB) into `archived/episodic/YYYY-MM.md` | optional nightly cron 03:05 | developer |

**Who can touch:** Developer/operator creates and maintains. Hooks/watchdog/cron execute. Agent can read but should not modify without permission.

---

## Layer 10: Secrets (`secrets/`)

Credentials. NEVER loaded into context. NEVER committed to git. NEVER logged.

All secrets in ONE shared folder: `~/.claude-lab/shared/secrets/`

| Path | Role | Access |
|------|------|--------|
| **shared/secrets/second_brain.key** | second_brain API key | scripts read, agent NEVER outputs |
| **shared/secrets/telegram/bot-token-{agent}** | Telegram bot token (per bot) | gateway reads, agent NEVER outputs |
| **shared/secrets/db-service-account.json** | Database service account | message bus reads, agent NEVER outputs |
| **shared/secrets/groq-api-key** | Groq Whisper API key | transcription reads, agent NEVER outputs |

**Who can touch:** Operator only. Agent NEVER reads content, NEVER copies between servers, NEVER commits, NEVER outputs to stdout/stderr.

---

## Layer 11: Gateway (`shared/gateway/`)

Telegram router. Shared across agents. NOT loaded into agent context.

| File | Role | Writer | Access |
|------|------|--------|--------|
| **gateway.py** | Main router: Telegram polling -> Claude subprocess -> response -> memory | developer | developer edits, systemd runs |
| **config.json** | Agent configs: bot token path, workspace, model, timeout, env vars | developer/operator | developer edits |
| **state/sid-{agent}-{chat}.txt** | Session ID persistence | gateway (auto) | gateway reads/writes |
| **media-inbound/*.ogg** | Downloaded voice/media files | gateway (auto) | agent reads via path, auto-cleanup |

**Who can touch:** Developer maintains code. Gateway auto-manages state and media. Agent reads media paths but doesn't modify gateway.

---

## Summary: Context Budget

### Always loaded (every session start)

| File | Size | Tokens (~) |
|------|------|------------|
| ~/.claude/CLAUDE.md | 7 KB | 3,200 |
| ~/.claude/rules/*.md | 1 KB | 430 |
| CLAUDE.md (SOUL) | 8 KB | 3,500 |
| core/USER.md | 2 KB | 765 |
| core/rules.md | 4 KB | 1,935 |
| core/passive/*.md | 3 KB | 1,400 |
| core/active/handoff.md | 1-4 KB | 450-1,800 |
| core/active/working-set.md | 1-4 KB | 450-1,800 |
| **TOTAL** | **27-33 KB** | **12,130-14,830** |

### On-demand (not in startup context)

| Resource | Size | When |
|----------|------|------|
| core/AGENTS.md | 5 KB | Agent needs models, subagents, pipelines (on-demand Read) |
| tools/TOOLS.md | 6 KB | Agent needs servers, infrastructure (on-demand Read) |
| core/active/episodic.md | 8-30 KB | Full journal, loaded by gateway (on-demand Read) |
| MEMORY.md (ARCHIVE) | 5+ KB | Agent needs old decisions |
| LEARNINGS.md | varies | Agent needs past mistakes |
| Skills (15) | ~50 KB total | Skill tool invocation |
| Scripts (30) | ~70 KB total | Never in context |
| second_brain | unlimited | curl search |
| Secrets | <1 KB each | Never in context |

---

## Access Matrix

| File | Operator | Agent | Gateway | Hooks/Bash | Other Agents |
|------|----------|-------|---------|------------|--------------|
| Global CLAUDE.md | RW | R | - | - | R |
| SOUL CLAUDE.md | RW | R | - | - | **NO** |
| AGENTS.md | RW | R | - | - | **NO** |
| USER.md | RW | R | - | - | **NO** |
| rules.md | RW | R | - | - | **NO** |
| TOOLS.md | RW | R (suggest) | - | - | **NO** |
| passive/*.md | RW | RW (reflection) | - | decay-sweep prunes | **NO** |
| active/working-set.md | RW | R | - | working-set-build writes | **NO** |
| active/episodic.md | RW | R | W (append) | active-writer appends, archive-roll relocates | **NO** |
| MEMORY.md | RW | R+append | - | - | **NO** |
| LEARNINGS.md | RW | RW | - | - | **NO** |
| Skills | RW | R+execute | - | - | shared |
| Secrets | RW | **NEVER** | R | R | **NEVER** |
| gateway.py | RW | R | execute | - | - |
| config.json | RW | R | R | - | - |

**Key rule:** Each agent's workspace is **private**. Other agents CANNOT read another agent's core/, active/, passive/, MEMORY.md, LEARNINGS.md without explicit operator permission.
