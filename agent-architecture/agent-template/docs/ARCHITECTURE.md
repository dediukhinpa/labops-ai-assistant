# Agent Architecture — Local Files + second_brain

No external databases. Only local files and semantic search.

## Entry Points

```
Operator
├── Terminal (SSH/local) → Claude Code (interactive)
└── Telegram (@bot)      → JARVIS Gateway (autonomous)
```

## Agents

| Agent | Mode | Permissions | Session | Gateway |
|-------|------|-------------|---------|---------|
| Claude Code | Interactive | Manual approve | Long (hours) | No (standard CLI) |
| JARVIS | Autonomous | Bypass | Short (request-response) | Yes (systemd) |

## Context Loading (at session start)

```
Claude Code launch
│
├── ~/.claude/CLAUDE.md           global rules
├── ~/.claude/rules/*.md          language rules
│
└── {agent}/.claude/CLAUDE.md     agent SOUL
    ├── @core/USER.md             operator profile
    ├── @core/rules.md            boundaries
    ├── @core/passive/*.md          semantic insights (decisions/errors/preferences)
    ├── @core/active/handoff.md      compact extract (last 10 entries)
    └── @core/active/working-set.md  materialised recall for the current task

~10-25K tokens (episodic.md is NOT loaded -- on-demand Read only)
```

## Session Management

```
Session lifecycle:
  1. First message   → new session ID (UUID), saved in state/sid-{agent}-{chat}.txt
  2. Subsequent msgs → claude --resume <session_id> (preserves context)
  3. /reset          → save to ARCHIVE, delete session file, next msg = new session
  4. /reset force    → delete session file immediately, no save
  5. Post-reset      → first message injects latest MEMORY.md section as context bridge
```

Key commands:
- `claude --continue` — resume last conversation
- `claude --resume` — pick from session list
- `claude -n "name"` — name a session
- `/rewind` or `Esc+Esc` — restore from checkpoint (conversation, code, or both)

Checkpoints are created on every Claude action and persist across sessions.

## On-Demand (NOT in context)

```
ARCHIVE memory    → Read tool (MEMORY.md, LEARNINGS.md)
Skills         → Skill tool (shared/skills/)
second_brain L4  → curl ${SECOND_BRAIN_MEMORY_ROUTER_URL} (or set MCP_HOST to Tailscale IP for multi-VPS)
Web search     → Perplexity / DuckDuckGo
```

## Complete Data Flow

End-to-end path from operator message to memory persistence:

```
OPERATOR sends message (Telegram)
    |
    v
GATEWAY (systemd service, always running)
    | 1. Receive message (long-polling thread)
    | 2. Classify source:
    |    - own_text: operator typed directly
    |    - own_voice: operator sent voice message
    |    - forwarded: operator forwarded from another chat
    |    - external_media: photo/video/document (not voice)
    | 3. Download media if present (20MB limit)
    | 4. Transcribe voice via Groq Whisper (whisper-large-v3-turbo)
    |    - If transcription fails: message still processed, marked as failed
    | 5. Launch Claude Code: claude -p --resume <session_id>
    |    - Session ID stored in state/sid-{agent}-{chat}.txt
    |    - If no session file: new session (claude -p --session-id <uuid>)
    |    - Context loaded via @include from CLAUDE.md
    | 6. Stream progress to Telegram (real-time status updates)
    | 7. Get response from Claude Code
    |
    v
MEMORY WRITE (parallel, after every message)
    | A. ACTIVE: append to core/active/episodic.md (ALWAYS, all source tags)
    |    - fcntl.LOCK_EX for concurrent safety
    |    - Format: ### YYYY-MM-DD HH:MM [source_tag]
    |    - Snippet: 200 chars user + 200 chars agent
    |    - Emergency trim: if >20KB, keep last 600 lines
    |
    | B. PASSIVE: insights consolidated by the LIVE SESSION during reflection
    |    - Nudged by reflect-nudge.sh (checkpoint every 20 turns + watchdog idle 10 min)
    |    - Session reads episodic.md -> writes passive/*.md (memory-consolidate skill)
    |    - Important knowledge dual-written to second_brain (create_decision_note, ...)
    |    - No background model: `claude -p` is forbidden repo-wide
    |
    | C. RECALL: working-set-build.sh (SessionStart + worthy prompts)
    |    - second_brain recall (RRF, hard-timeout, non-blocking) + local passive/ lexical
    |    - Writes active/working-set.md; logs hits to recall-events.jsonl
    |
    v
REPLY to operator in Telegram (markdown -> HTML, chunked at 4000 chars)
```

This is the critical path. Every message follows this exact sequence. Memory writes never block the response -- they happen in parallel after Claude Code returns.

## Why Keeping Episodic Out of Context Matters

The episodic diary (`episodic.md`) grows to 80KB+ per day. The redesign never loads
it into context: what loads is the compact `handoff.md` + `working-set.md` +
consolidated `passive/` insights. The raw diary stays on-demand (Read tool) and is
size-rolled to `archived/episodic/` by `archive-roll.sh`. The problem it avoids:
80KB of raw conversation logs equals ~36,000 tokens -- roughly 70% of the startup
context at Opus level.

Quality degrades when context is bloated with raw logs. The agent spends most of its
attention on unstructured conversation history instead of identity, rules, and tools.
This is measurable -- an agent carrying 80KB of raw episodic performs noticeably
worse at following instructions than one with 20KB of structured facts.

Consolidation solves this WITHOUT a background model: the **live session** reflects
(nudged by `reflect-nudge.sh`) and distils many raw turns into a handful of semantic
insights in `passive/`. Episodic text is never model-compressed -- only role-promoted
(into insights) and size/usage-rolled (into `archived/`) by pure bash.

| Metric | Loading raw episodic | Consolidated (recall + insights) |
|--------|--------------------|--------------------|
| Episodic in context | 80 KB+ | 0 (on-demand only) |
| Loaded memory (handoff + working-set + passive) | n/a | 5-11 KB |
| Tokens consumed by memory | ~36,000 | ~2,500-5,000 |
| Startup context used | ~70% | ~10-15% |
| Background model cost | n/a | $0 (reflection runs in the live session) |
| Agent instruction-following | Degraded | Optimal |

The system exists not to save money but to keep context CLEAN. An agent carrying 80KB
of raw conversation logs performs worse than one with a few KB of structured facts --
even though both fit within the 1M token window.

## Gateway Flow (Telegram → Claude Code)

```
Operator (Telegram)
    │ voice / text / photo
    ▼
Gateway (systemd service)
    │ 1. Receive message (polling thread)
    │ 2. Classify source (own_text / own_voice / forwarded / external_media)
    │ 3. Download media (photo, video, document — 20MB limit)
    │ 4. Transcribe voice ([Groq](https://groq.com) Whisper — whisper-large-v3-turbo)
    │ 5. Launch Claude Code (claude -p --resume <session_id>)
    │ 6. Stream progress (real-time status in Telegram: plan, tools, subagents)
    │ 7. Write to ACTIVE (core/active/episodic.md — fcntl lock, 200 char snippets)
    │ 8. Insights consolidated in-session during reflection (dual-write to second_brain)
    │ 9. Reply in Telegram (markdown → HTML, chunked at 4000 chars)
    ▼
Claude Code (model)
    │ context loaded via @include
    ▼
Response to operator
```

## Inter-Agent Communication

Agents communicate via local inbox files or shared message bus:

```
Agent A → shared/messages/inbox/{agent-b}
Agent B → shared/messages/inbox/{agent-a}
```

## second_brain (Local Semantic Search)

[second_brain](https://github.com/volcengine/second_brain) -- open-source context database for AI agents. Manages memories, resources, and skills through a filesystem paradigm with tiered context loading.

```
${SECOND_BRAIN_MEMORY_URL}        (write, default http://${MCP_HOST}:5001/mcp)
${SECOND_BRAIN_MEMORY_ROUTER_URL} (recall, default http://${MCP_HOST}:5002/mcp)
${SECOND_BRAIN_AGENT_ROUTER_URL}  (swarm, default http://${MCP_HOST}:5000/mcp)
MCP_HOST = host/IP only (set to Tailscale IP for multi-VPS — check ss -tlnp)
│
├── Account: {org}
│   ├── User: claude-code    (own embeddings)
│   └── User: jarvis         (own embeddings)
│
├── Write: dual-write of insights by the LIVE SESSION during reflection
│   Trigger: reflect-nudge.sh (checkpoint every 20 turns + watchdog idle 10 min)
│   Method: create_decision_note / create_error_pattern_note / ... (recall-before-write)
│   No background model, no batch upload: `claude -p` is forbidden repo-wide
│
└── Recall: working-set-build.sh (SessionStart + worthy prompts)
    POST ${SECOND_BRAIN_MEMORY_ROUTER_URL} (JSON-RPC tools/call recall)
    {"query": "topic", "limit": 5}   # RRF, hard-timeout, non-blocking; fused with local passive/
```

Install: `pip install second_brain --upgrade`

## Memory Consolidation (event-driven) and Housekeeping

Consolidation is **event-driven**, not cron. Reflection is done by the **live
session** (no background model -- `claude -p` is forbidden); scripts only nudge it.

```
Stop hook (every turn) -> active-writer.sh -> ACTIVE (episodic.md, salience-tagged)
  |     raw, append-only diary -- NEVER model-compressed
  |
  +-- reflect-nudge.sh (checkpoint every 20 turns + watchdog idle 10 min)
  |     -> agent_router.notify -> LIVE SESSION runs memory-consolidate skill
  |     -> reads episodic.md, writes passive/*.md insights (YAML frontmatter),
  |        dual-writes important knowledge to second_brain
  |
  +-- working-set-build.sh (SessionStart + worthy prompts)
  |     recall = second_brain (RRF, hard-timeout) + local passive/ lexical
  |     -> active/working-set.md; logs hits to recall-events.jsonl (reinforcement)
  |
  +-- decay-sweep.sh (nightly bash, no model)
  |     reinforce recalled insights; evict never-recalled decayed ones (score<0.25)
  |     -> archived/superseded/
  |
  +-- archive-roll.sh (nightly bash, no model)
  |     episodic.md >40KB -> archived/episodic/YYYY-MM.md (relocated, not summarised)
  |
  +-- /compact, /reset (manual gateway commands)
        Extract/save key context, start fresh session

L4     -> second_brain, dual-write of insights during in-session reflection
         Method: create_decision_note / create_error_pattern_note (recall-before-write)
```

Was **4 model crons** -> now **0 model crons + 1 optional bash housekeeping cron**.

### Recommended crontab (optional, pure bash, no model)

```crontab
# Nightly housekeeping only. Consolidation is event-driven (hooks + watchdog).
# 1. Decay sweep: reinforce recalled insights, evict decayed ones -> archived/superseded/
0 3 * * * /path/to/decay-sweep.sh

# 2. Archive roll: size-roll episodic.md -> archived/episodic/YYYY-MM.md
5 3 * * * /path/to/archive-roll.sh
```

Consolidation (episodic -> passive insights) needs no cron: it fires in-session on
the checkpoint counter (every 20 turns) and on watchdog idle (10 min).

### Gateway commands for memory

| Command | What it does |
|---------|-------------|
| `/compact` | Extract key facts from last 24h ACTIVE → PASSIVE, trim ACTIVE to 24h |
| `/reset` | Save important context to ARCHIVE (MEMORY.md), start new session |
| `/reset force` | Delete session immediately, no save |
| `/status` | Show session age, memory file sizes (rules, passive, active, archive) |
| `/new` | Save handoff + start new session |
| `/stop` | Stop current Claude response |
| `/help` | Show available commands |
