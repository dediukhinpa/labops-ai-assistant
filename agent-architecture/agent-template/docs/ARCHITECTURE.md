# Agent Architecture — Local Files + second_brain

Each agent is one long-lived interactive Claude Code session. Memory lives in local
Markdown files plus the shared second_brain; no background model is ever called
(`claude -p` is forbidden in agent traffic).

## Entry Points

```
Operator
├── Telegram (one bot per agent) → channel plugin → the agent's live session
└── Terminal (SSH/local)          → tmux attach -t labops-<agent>  (the same session)
```

## Process Tree

```
systemd  claude-agent-<agent>.service
  └── orchestration/watchdog.sh <agent>        keeps the session alive, restarts a wedged turn
        ├── tmux session labops-<agent>
        │     └── claude --dangerously-skip-permissions (TUI, cwd = labops-tg-plugin/plugin)
        │           └── labops-channel MCP server (bun, the Telegram plugin)
        │                 ├── Telegram long-poller (getUpdates)
        │                 └── internal webhook 127.0.0.1:6000+N (/hooks/*)
        └── scripts/task-poller.sh → task_poller.py   delivers board tasks every 5 s
```

The session is not restarted per message: it keeps its context until compaction,
`/reset force` or a watchdog restart.

## Context Loading (at session start)

```
~/.claude/CLAUDE.md                 rules for every agent
~/.claude/rules/*.md                language rules
{agent}/.claude/CLAUDE.md           SOUL
  ├── @core/USER.md                 who the operator is
  ├── @core/rules.md                orders to self, earned from mistakes
  ├── @SECONDBRAIN_WRITE_RULES.md   what to write to the shared brain
  ├── @AGENT_ROUTER.md              handing work to other agents
  ├── @core/passive/decisions.md    what we chose and why
  └── @core/passive/preferences.md  how the operator wants work done
```

Not loaded (read on demand): `core/AGENTS.md`, `tools/TOOLS.md`,
`core/active/episodic.md`, `core/passive/errors.md`, `core/passive/insights.md`,
`core/archived/`, skills (Skill tool), second_brain (`recall`).

## Message Flow

```
OPERATOR writes to the agent's bot
    |
    v
CHANNEL PLUGIN (inside the session)
    | 1. getUpdates; drops senders not in TELEGRAM_ALLOWED_USER_IDS
    | 2. voice: transcribed with Groq Whisper when a key is configured
    |    (otherwise the agent runs the groq-voice skill itself)
    | 3. 👀 reaction, "typing…" status
    | 4. MCP notification -> the message is injected into the live session
    |
    v
CLAUDE CODE SESSION
    | recall from second_brain before non-trivial work (CLAUDE.md)
    | works with tools; hooks fire on every event (heartbeat, Stop, PreCompact)
    | answers ONLY through the channel's `reply` tool --
    | text written in the session is invisible to the operator
    |
    v
REPLY in Telegram (formatted, split to fit the 4096-char limit)

After the turn: Stop hook -> active-writer.sh -> core/active/episodic.md
```

## Memory Consolidation and Housekeeping

Event-driven, no cron, no background model.

```
Stop hook (every turn) -> active-writer.sh -> episodic.md (raw diary, salience-tagged)
  |
  +-- reflect-nudge.sh (every 20 turns; watchdog after 10 min idle)
  |     -> agent_router.notify (or core/active/consolidate.request)
  |     -> the LIVE session runs memory-consolidate:
  |        episodic -> passive/{decisions,errors,preferences,insights}.md
  |        + dual-write to second_brain within the token's scopes
  |
  +-- once a day (Stop hook, pure bash):
  |     decay-sweep.sh   passive entries that decayed unrecalled -> archived/superseded/
  |                      (preferences.md never decays)
  |     archive-roll.sh  episodic.md > 40 KB -> archived/episodic/YYYY-MM.md
  |
PreCompact -> snapshot to core/active/pre-compact/ + brain-flush.sh
SessionEnd -> brain-flush.sh  (diary tail -> second_brain inbox/)
```

Why the diary stays out of context: it grows by tens of KB a day. Loading it would
spend most of the startup context on raw logs and make the agent follow its
instructions worse. What loads instead is the short, distilled part: `decisions.md` and
`preferences.md`.

## Inter-Agent Communication

All coordination goes through second_brain, never through local files:

- **Task board** (`second_brain-tasks`, `task_*`): the sender creates a task for an
  assignee; `task_poller.py` delivers it into the assignee's session; the assignee
  claims, works and closes it. See `AGENT_ROUTER.md`.
- **Events** (`second_brain-agent_router`): `notify`, `broadcast`, `escalate`,
  `list_my_pending`, `ack` -- also used for the consolidation nudge.
- **Shared memory**: what one agent writes, the others find with `recall`.

## second_brain (shared memory, L4)

A separate repo (`labops-second-brain`): Postgres + pgvector, an Obsidian-style vault
as the source of truth, four MCP services.

```
${SECOND_BRAIN_MEMORY_URL}        writes      default http://${MCP_HOST}:5001/mcp
${SECOND_BRAIN_MEMORY_ROUTER_URL} recall      default http://${MCP_HOST}:5002/mcp
${SECOND_BRAIN_AGENT_ROUTER_URL}  events      default http://${MCP_HOST}:5000/mcp
${SECOND_BRAIN_TASKS_URL}         task board  default http://${MCP_HOST}:5003/mcp
```

- Auth: per-agent Bearer token; a write succeeds only inside the token's scopes.
- Recall: hybrid search (vectors + full text, fused with RRF), weighted by note type
  and freshness.
- Transport: MCP streamable HTTP -- `initialize` first, then calls with the returned
  `Mcp-Session-Id` (`scripts/mcp-call.sh` does it for the hooks).

## Telegram commands (tg-plugin)

| Command | What it does |
|---------|-------------|
| `/reset force` | Clear the session context: the watchdog waits for the current turn to finish, types `/clear` into the session pane, confirms via the SessionEnd/SessionStart hooks (SessionEnd flushes the diary to second_brain `inbox/`) and then replies. Memory files are untouched |
| `/status` | Snapshot of plugin state |
| `/doctor` | Check the agent and repair it if broken (served by the watchdog) |
| `/stop` | Ask Claude to stop the current task (best-effort) |
| `/help` | Show available commands |

`/new` was removed: in Claude Code "new session" and "reset" are the same `/clear`.

## Session commands (terminal)

- `claude --continue` — resume the last conversation (the watchdog uses it after a deep sleep)
- `/rewind` or `Esc+Esc` — restore from a checkpoint
