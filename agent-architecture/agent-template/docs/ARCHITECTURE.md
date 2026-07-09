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
    ├── @core/passive/decisions.md   rolling 14 days
    └── @core/active/handoff.md      compact extract (last 10 entries)

~10-25K tokens depending on ACTIVE size
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
    | A. ACTIVE: append to core/active/recent.md (ALWAYS, all source tags)
    |    - fcntl.LOCK_EX for concurrent safety
    |    - Format: ### YYYY-MM-DD HH:MM [source_tag]
    |    - Snippet: 200 chars user + 200 chars agent
    |    - Emergency trim: if >20KB, keep last 600 lines
    |
    | B. second_brain: synced via Stop hook + daily cron (NOT per-message)
    |    - Stop hook: runs second_brain-memory_router-on-start.sh on session end (background)
    |    - Cron: 06:30 UTC daily (after memory rotation scripts)
    |    - Uploads ACTIVE (last 10 entries) + PASSIVE (full) as markdown
    |    - Method: temp_upload -> add_resource to second_brain://notes/
    |    - Idempotent: same date = same URI = overwrites previous
    |
    v
REPLY to operator in Telegram (markdown -> HTML, chunked at 4000 chars)
```

This is the critical path. Every message follows this exact sequence. Memory writes never block the response -- they happen in parallel after Claude Code returns.

## Why Memory Compression Matters

Without compression, ACTIVE memory grows to 80KB+ per day (before cron runs). After daily cron rotation, ACTIVE is typically 8-20KB. At 150+ messages per day with ~500 bytes each, this is expected. The problem: 80KB of raw conversation logs equals ~36,000 tokens -- roughly 70% of the total startup context at Opus level.

Quality degrades when context is bloated with raw logs. The agent spends most of its attention on unstructured conversation history instead of identity, rules, and tools. This is measurable -- an agent with 80KB of raw ACTIVE performs noticeably worse at following instructions than one with 20KB of structured facts.

Sonnet compression solves this: 110 raw entries compress into 15-20 key facts (80% reduction). The 4 cron scripts (rotate-passive, trim-active, compress-passive, memory-rotate) run daily and keep memory clean.

| Metric | Without compression | With compression |
|--------|--------------------|--------------------|
| ACTIVE size (end of day) | 80 KB+ | 10-20 KB |
| Tokens consumed by ACTIVE | ~36,000 | ~4,500-9,000 |
| Startup context used | ~70% | ~10-15% |
| Sonnet cost | n/a | $0 (Max subscription) |
| Agent instruction-following | Degraded | Optimal |

The compression system exists not to save money but to keep context CLEAN. An agent with 80KB of raw conversation logs performs worse than one with 20KB of structured facts -- even though both fit within the 1M token window.

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
    │ 7. Write to ACTIVE (core/active/recent.md — fcntl lock, 200 char snippets)
    │ 8. Write to ACTIVE completes (second_brain synced separately via Stop hook + cron)
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
├── Write: batch sync (NOT per-message)
│   Trigger 1: Stop hook (runs second_brain-memory_router-on-start.sh on session end)
│   Trigger 2: Cron 06:30 UTC daily (after memory rotation)
│   Method:
│     POST ${SECOND_BRAIN_MEMORY_URL} (create_external_note via JSON-RPC) → upload markdown
│     POST ${SECOND_BRAIN_MEMORY_URL}                 → add_resource (indexes + embeds)
│   Target: second_brain://notes/{agent}-sessions/{YYYY-MM-DD}
│   Content: last 10 ACTIVE entries + full PASSIVE decisions
│
└── Search: when old context needed (>24h)
    POST ${SECOND_BRAIN_MEMORY_ROUTER_URL} (JSON-RPC tools/call recall)
    {"query": "topic", "limit": 10}
```

Install: `pip install second_brain --upgrade`

## Memory Rotation and Cron

Complete data flow with Sonnet-based compression:

```
Gateway (every message) -> ACTIVE (recent.md)
  |
  +-- Emergency trim (auto, >20KB, bash)
  |     Keeps last 600 lines, trims from top
  |
  +-- trim-active.sh (cron 05:00 UTC, Sonnet)
  |     Entries >24h -> Sonnet summary -> PASSIVE
  |     >40 entries remaining -> oldest also compressed
  |     Fallback: bash (first 120 chars if Sonnet unavailable)
  |     Runs from /tmp to avoid loading CLAUDE.md (~35K tokens saved)
  |     flock for safe concurrent access with gateway
  |
  +-- compress-passive.sh (cron 06:00 UTC, Sonnet)
  |     PASSIVE >10KB -> Sonnet re-compression by topic
  |     110 raw entries -> 15-20 key facts
  |     Skip if <10KB or <50 lines or Sonnet unavailable
  |     Garbage protection: skip if Sonnet returns <3 lines
  |
  +-- rotate-passive.sh (cron 04:30 UTC, bash)
  |     PASSIVE >14d -> ARCHIVE (pure bash, no model)
  |
  +-- memory-rotate.sh (cron 21:00 UTC, bash)
  |     ARCHIVE >5KB -> archived/YYYY-MM.md (pure bash)
  |
  +-- /compact command (manual, Sonnet)
  |     Extract key facts from last 24h ACTIVE -> PASSIVE, trim ACTIVE to 24h
  |
  +-- /reset command (manual, Sonnet)
        Save important context to ARCHIVE, start new session

L4     -> second_brain, batch sync via Stop hook + daily cron (06:30 UTC)
         Method: temp_upload + add_resource to second_brain://notes/
```

### Recommended crontab

```crontab
# 1. Rotate PASSIVE: move >14d entries to ARCHIVE (bash, no model)
30 4 * * * /path/to/rotate-passive.sh

# 2. Trim ACTIVE: entries >24h -> Sonnet summary -> PASSIVE
0 5 * * * /path/to/trim-active.sh

# 3. Compress PASSIVE: Sonnet re-compression by topic (>10KB only)
0 6 * * * /path/to/compress-passive.sh

# 4. Sync to second_brain: ACTIVE+PASSIVE -> semantic search (bash + curl)
30 6 * * * /path/to/second_brain-memory_router-on-start.sh

# 5. Archive ARCHIVE: MEMORY.md >5KB -> archived/YYYY-MM.md (bash)
0 21 * * * /path/to/memory-rotate.sh
```

Order: rotate-passive (clear old) -> trim-active (add new to PASSIVE) -> compress-passive (re-compress) -> second_brain-memory_router-on-start (upload to L4).

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
