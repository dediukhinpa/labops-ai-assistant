# Setup Guide -- agent-template

Step-by-step setup for an agent workspace wired to a shared second_brain MCP server.

This is the "client-side" of the `labops-ai-assistant` monorepo. The "server-side"
(memory MCP, memory_router MCP, agent_router MCP, task MCP, Postgres + pgvector)
lives in the separate `labops-second-brain` repo: it is documented in its
`docs/setup.md` and installed via its `scripts/install-vps.sh` (the paths below are
relative to that repo's root, not this one). You **must** have a
running second_brain server (or know its `MCP_HOST` host/IP and have a Bearer token for
your agent) before running `install.sh` here.

## Architecture in one paragraph

`agent-template/install.sh` creates `~/.claude-lab/<agent-id>/.claude/`. Inside,
a four-layer memory pyramid (IDENTITY -> PASSIVE -> ACTIVE -> ARCHIVE) lives as Markdown
files. A `.mcp.json` points Claude Code at four remote MCP servers --
**memory** (write decisions / error patterns / personal and project notes, default port 5001),
**memory_router** (read shared semantic memory, default port 5002),
**agent_router** (notify other agents, default port 5000),
**tasks** (the task board, default port 5003) -- each on its own
port, all Bearer-authenticated. Local hooks
(`heartbeat`, `session-start`, `stop`, `precompact`) keep the local memory fresh; recall
under a task is the agent's own job -- `CLAUDE.md` tells it to query the shared
brain before non-trivial work.

## Prerequisites

- macOS or Linux with bash, `jq`, `python3`, `curl`, `git`
- Claude Code CLI: `curl -fsSL https://claude.ai/install.sh | bash` (native installer, no Node.js needed)
- second_brain server already deployed and reachable. You need:
  - `MCP_HOST` — host/IP only, no protocol or port (e.g. `127.0.0.1` or `mcp.example.com`). The four per-service endpoint URLs (`SECOND_BRAIN_MEMORY_URL` on port 5001, `SECOND_BRAIN_MEMORY_ROUTER_URL` on port 5002, `SECOND_BRAIN_AGENT_ROUTER_URL` on port 5000, `SECOND_BRAIN_TASKS_URL` on port 5003) are derived automatically, or override them directly if you front the server with your own reverse proxy.
  - Agent bearer token issued by
    `scripts/issue-agent-token.py` in the `labops-second-brain` repo, run on the
    second_brain VPS
- (Optional) `gh` CLI authorized if you plan to use GitHub workflows

## One-command install

The usual path is `agent-architecture/install.sh` for the first agent and the
`create-agent` skill for the next ones -- they call this installer
non-interactively and add Telegram, voice and autostart. To run it by hand:

```bash
cd ~/labops-ai-assistant/agent-architecture/agent-template
bash install.sh
```

The script asks for:

1. Agent identity (name, role, character, language, primary model, max subagents)
2. Operator profile (name, address, timezone, language)
3. **second_brain connection** (MCP host — host/IP only, Bearer token, comma-separated scopes)

Default scopes of this bare installer: `decisions,knowledge,inbox`.
`create-agent` uses the full set `decisions,knowledge,inbox,error-patterns,task-board,personal,projects,daily`
-- without `task-board` the agent cannot take tasks, without `error-patterns` it
cannot share error patterns, and without `personal`, `projects`, `daily`
the `create_personal_note`, `create_project_note`, `append_daily_log` calls are refused. Issue the token on the server with matching scopes
(the second_brain installer does it for existing agents via `connect-agents.sh`):

```bash
# on the second_brain VPS
python3 /opt/second_brain/scripts/issue-agent-token.py \
    --agent <agent-id> \
    --scopes decisions,knowledge,inbox,error-patterns,task-board,personal,projects,daily
```

Copy the printed token into the installer prompt.

## What gets created

```
~/.claude-lab/<agent-id>/.claude/
|-- CLAUDE.md                  # SOUL: who the agent is
|-- .mcp.json                  # second_brain memory/memory_router/agent_router/tasks endpoints (chmod 600)
|-- settings.json              # model, permissions, hooks (heartbeat, SessionStart, Stop, PreCompact, SessionEnd)
|-- agent.env                  # MCP_HOST, SECOND_BRAIN_*_URL, AGENT_BEARER, AGENT_SCOPES (chmod 600)
|-- core/
|   |-- USER.md                # operator profile
|   |-- rules.md               # orders to self, earned from mistakes (empty at install)
|   |-- AGENTS.md              # team / models / pipelines
|   |-- passive/                # decisions + preferences (in context), errors, insights
|   |-- active/
|   |   |-- episodic.md          # raw append-only diary (Stop hook appends, salience-tagged)
|   |   `-- pre-compact/       # PreCompact snapshots (rotated)
|   `-- archived/
|       |-- episodic/          # size-rolled old episodic slices (YYYY-MM.md)
|       `-- superseded/        # decayed passive insights
|-- tools/TOOLS.md             # infra map
|-- scripts/                   # active-writer, reflect-nudge, decay-sweep, archive-roll,
|                              # brain-flush, mcp-call, task-poller.sh, task_poller.py
|-- hooks/                     # session-start, stop, precompact, heartbeat
|-- logs/                      # hooks.log, verbose-YYYY-MM-DD.jsonl
`-- skills/                    # symlink to ~/.claude-lab/shared/skills (shared by every agent)
```

`~/.claude/CLAUDE.md` and `~/.claude/rules/{bash,python,typescript}.md` are
created globally on first run.

## Verifying second_brain connectivity

```bash
python3 ~/labops-ai-assistant/agent-architecture/skills/second_brain-doctor/scripts/second_brain_doctor.py --agent <agent-id>
```

The doctor performs the MCP handshake, checks the token, runs a `recall` and looks
at the hooks. A bare `curl` with `tools/list` is not a valid check: the MCP
transport is session-based, so without `initialize` every server answers
`400 Missing session ID` whatever the token.

## Launching the agent

```bash
source ~/.claude-lab/<agent-id>/.claude/agent.env
claude --project ~/.claude-lab/<agent-id>/.claude
```

On session start, the `SessionStart` hook logs the start. There is no
recall hook: before a
non-trivial task the agent queries the shared brain itself (`CLAUDE.md` says so),
keyed on the real task.

On each turn end, `Stop` hook appends a salience-tagged entry to `episodic.md`
(via `active-writer.sh`) and a full JSON envelope to
`logs/verbose-YYYY-MM-DD.jsonl`, and every `MEMORY_CHECKPOINT_EVERY_N_TURNS`
(default 20) fires `reflect-nudge.sh` so the **live session** consolidates
`episodic` -> `passive/` insights (via the `memory-consolidate` skill; no
background model -- `claude -p` is forbidden).

Before Claude Code auto-compacts context, `PreCompact` hook snapshots
`episodic.md` to `core/active/pre-compact/recent-<ts>.md` and runs
`brain-flush.sh`, which sends the diary tail to the shared brain; `SessionEnd`
does the same flush when the session closes.

## Housekeeping (no cron needed)

Consolidation is **event-driven** (checkpoint every 20 turns + watchdog idle 10
min), so there are no model crons. Housekeeping is pure bash and runs from the
`Stop` hook at most once a day (`MEMORY_HOUSEKEEPING_INTERVAL_SEC`, default 86400):

- `decay-sweep.sh` moves never-reinforced decayed insights to
  `archived/superseded/` (`preferences.md` never decays);
- `archive-roll.sh` size-rolls `episodic.md` into `archived/episodic/YYYY-MM.md`
  once it passes 40 KB.

Both are pure bash + Python arithmetic -- no model call, so episodic text is never
summarised, only relocated. An agent that never finishes a turn never runs them;
you can still call either script by hand with `AGENT_WORKSPACE` set.

## Adding more agents to the same shared brain

Re-run `install.sh` with a different agent name. Each agent gets its own
`~/.claude-lab/<agent-id>/.claude/` workspace and its own Bearer token, but they
**share** the second_brain server -- so writes by one agent (`create_decision_note`,
`create_error_pattern_note`, ...) become recall hits for the others. See
[MULTI-AGENT.md](MULTI-AGENT.md).

## Overlaying onto an existing Claude Code project

`agent-template/` is an **overlay**: you can either

1. **Standalone:** run `install.sh` to create a fresh
   `~/.claude-lab/<agent-id>/.claude/` workspace and point Claude Code at it
   via `claude --project ...`.
2. **Inside an existing repo:** copy `templates/mcp.json.template`,
   `templates/settings.json.template`, `scripts/`, `hooks/` into the repo's
   `.claude/` directory and render placeholders manually. The hooks tolerate
   absent files (episodic.md, passive/) and won't break the harness.

Either way the wire protocol to second_brain is identical: HTTP MCP transport, Bearer
in `Authorization` header, JSON-RPC 2.0 in the body.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| recall or a write fails with a permission error | token lacks the scope (e.g. `task-board`, `error-patterns`), or wrong agent | run `sudo bash /opt/second_brain/scripts/connect-agents.sh` on the brain host, or re-issue with `issue-agent-token.py --scopes ...` |
| recall returns empty results | second_brain DB has no notes yet | use `create_decision_note` first, or backfill from existing decisions.md |
| `Stop` hook never fires | `settings.json` not picked up | confirm `claude --project` points at the workspace dir that contains `settings.json` |
| `archive-roll.sh` skips silently | `episodic.md` < `EPISODIC_ROLL_KB` (40 KB) | by design; only rolls once the diary grows |

## Where to look next

- [ARCHITECTURE.md](ARCHITECTURE.md) -- end-to-end picture (memory + second_brain + hooks)
- [HOOKS.md](HOOKS.md) -- hook contracts and patterns
- [MEMORY.md](MEMORY.md) -- role-based memory (active/passive/archive) + event-driven consolidation
- [MULTI-AGENT.md](MULTI-AGENT.md) -- multiple agents over one shared brain
- [FIRST-AGENT.md](FIRST-AGENT.md) -- worked example of first agent setup
