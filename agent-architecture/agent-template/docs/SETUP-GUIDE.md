# Setup Guide -- agent-template

Step-by-step setup for an agent workspace wired to a shared second_brain MCP server.

This is the "client-side" of the public-second_brain-agentos distro. The "server-side"
(memory MCP, memory_router MCP, agent_router MCP, task MCP, Postgres + pgvector)
lives in the separate `labops-second-brain` repo: it is documented in its
`docs/setup.md` and installed via its `scripts/install-vps.sh` (the paths below are
relative to that repo's root, not this one). You **must** have a
running second_brain server (or know its `MCP_HOST` host/IP and have a Bearer token for
your agent) before running `install.sh` here.

## Architecture in one paragraph

`agent-template/install.sh` creates `~/.claude-lab/<agent-id>/.claude/`. Inside,
a four-layer memory pyramid (IDENTITY -> PASSIVE -> ACTIVE -> ARCHIVE) lives as Markdown
files. A `.mcp.json` points Claude Code at three remote MCP servers --
**memory** (write decisions / knowledge / external notes, default port 5001),
**memory_router** (read shared semantic memory, default port 5002),
**agent_router** (notify other agents, default port 5000) -- each on its own
port, all Bearer-authenticated. Four local hooks
(`session-start`, `user-prompt-submit`, `stop`, `precompact`) keep the local
memory fresh; `working-set-build.sh` rebuilds `core/active/working-set.md` by
fusing shared-brain recall with local `passive/` recall on each session start and
on substantive prompts.

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

```bash
cd ~/path/to/public-second_brain-agentos/agent-template
bash install.sh
```

The script asks for:

1. Agent identity (name, role, character, language, primary model, max subagents)
2. Operator profile (name, address, timezone, budget cap)
3. **second_brain connection** (MCP host — host/IP only, Bearer token, comma-separated scopes)

Default scopes: `decisions,external,knowledge,inbox`. Issue the token
on the server with matching scopes:

```bash
# on the second_brain VPS
python3 /opt/second_brain/scripts/issue-agent-token.py \
    --agent <agent-id> \
    --scopes decisions,external,knowledge,inbox
```

Copy the printed token into the installer prompt.

## What gets created

```
~/.claude-lab/<agent-id>/.claude/
|-- CLAUDE.md                  # SOUL: who the agent is
|-- .mcp.json                  # second_brain memory/memory_router/agent_router endpoints (chmod 600)
|-- settings.json              # Claude Code hooks (SessionStart/UserPromptSubmit/Stop/PreCompact)
|-- agent.env                  # source this to export MCP_HOST/SECOND_BRAIN_*_URL/AGENT_BEARER
|-- core/
|   |-- USER.md                # operator profile
|   |-- rules.md               # operational rules (RED zone, security)
|   |-- AGENTS.md              # team / models / pipelines
|   |-- MEMORY.md              # ARCHIVE archive (>14d, on-demand Read)
|   |-- LEARNINGS.md           # structured log of corrections
|   |-- passive/                # semantic insights (insights/decisions/errors/preferences.md)
|   |-- active/
|   |   |-- episodic.md          # raw append-only diary (Stop hook appends, salience-tagged)
|   |   |-- working-set.md       # materialised recall for current task (rebuilt)
|   |   |-- handoff.md         # last-N entries used by SessionStart
|   |   `-- pre-compact/       # PreCompact snapshots (rotated)
|   `-- archived/
|       |-- episodic/          # size-rolled old episodic slices (YYYY-MM.md)
|       `-- superseded/        # decayed passive insights
|-- tools/TOOLS.md             # infra map
|-- scripts/                   # active-writer, working-set-build, reflect-nudge,
|                              # decay-sweep, archive-roll
|-- hooks/                     # session-start, user-prompt-submit, stop, precompact
|-- logs/                      # hooks.log, verbose-YYYY-MM-DD.jsonl
`-- skills/                    # symlink to ../skills/ (shared bundle)
```

`~/.claude/CLAUDE.md` and `~/.claude/rules/{bash,python,typescript}.md` are
created globally on first run.

## Verifying second_brain connectivity

```bash
source ~/.claude-lab/<agent-id>/.claude/agent.env

curl -sS -H "Authorization: Bearer ${AGENT_BEARER}" \
     -H "Accept: application/json, text/event-stream" \
     -H "Content-Type: application/json" \
     -X POST "${SECOND_BRAIN_MEMORY_ROUTER_URL}" \
     --data '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
```

Expected: JSON-RPC response listing `recall`, `get`, `related`, `recent`,
`stats` (the memory_router MCP tools).

## Launching the agent

```bash
source ~/.claude-lab/<agent-id>/.claude/agent.env
claude --project ~/.claude-lab/<agent-id>/.claude
```

On session start, the `SessionStart` hook reads `core/active/handoff.md` and runs
`scripts/working-set-build.sh`: it fuses shared second_brain recall (a JSON-RPC
`tools/call recall` to `${SECOND_BRAIN_MEMORY_ROUTER_URL}`, hard-timeout so it
never blocks) with local `core/passive/*.md` lexical recall and writes the result
to `core/active/working-set.md`, logging hits to `core/recall-events.jsonl`. It
never edits `episodic.md`. `UserPromptSubmit` runs the same builder behind a
worthiness gate (skips acknowledgements like "ok").

On each turn end, `Stop` hook appends a salience-tagged entry to `episodic.md`
(via `active-writer.sh`) and a full JSON envelope to
`logs/verbose-YYYY-MM-DD.jsonl`, and every `MEMORY_CHECKPOINT_EVERY_N_TURNS`
(default 20) fires `reflect-nudge.sh` so the **live session** consolidates
`episodic` -> `passive/` insights (via the `memory-consolidate` skill; no
background model -- `claude -p` is forbidden).

Before Claude Code auto-compacts context, `PreCompact` hook snapshots
`episodic.md` to `core/active/pre-compact/recent-<ts>.md`.

## Housekeeping cron (optional)

Consolidation is **event-driven** (checkpoint every 20 turns + watchdog idle 10
min), so there are no model crons. The only cron is optional nightly **pure-bash**
housekeeping:

```cron
0 3 * * * AGENT_WORKSPACE=$HOME/.claude-lab/<agent-id>/.claude bash $HOME/.claude-lab/<agent-id>/.claude/scripts/decay-sweep.sh
5 3 * * * AGENT_WORKSPACE=$HOME/.claude-lab/<agent-id>/.claude bash $HOME/.claude-lab/<agent-id>/.claude/scripts/archive-roll.sh
```

`decay-sweep.sh` replays `recall-events.jsonl` to reinforce recalled insights and
moves never-recalled decayed ones to `archived/superseded/`; `archive-roll.sh`
size-rolls `episodic.md` into `archived/episodic/YYYY-MM.md`. Both are pure bash +
Python arithmetic -- no model call, so episodic text is never summarised, only
relocated.

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
   absent files (handoff, episodic.md) and won't break the harness.

Either way the wire protocol to second_brain is identical: HTTP MCP transport, Bearer
in `Authorization` header, JSON-RPC 2.0 in the body.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `working-set-build.sh` logs "SECOND_BRAIN_MEMORY_ROUTER_URL or AGENT_BEARER unset" | shell didn't `source agent.env` | `source ~/.claude-lab/<agent-id>/.claude/agent.env` before `claude` (recall still runs file-only against `passive/`) |
| recall returns `403` | token has no `inbox` (or relevant) scope, or wrong agent | re-issue with `issue-agent-token.py --scopes ...` |
| recall returns empty results | second_brain DB has no notes yet | use `create_decision_note` first, or backfill from existing decisions.md |
| `Stop` hook never fires | `settings.json` not picked up | confirm `claude --project` points at the workspace dir that contains `settings.json` |
| `archive-roll.sh` skips silently | `episodic.md` < `EPISODIC_ROLL_KB` (40 KB) | by design; only rolls once the diary grows |

## Where to look next

- [ARCHITECTURE.md](ARCHITECTURE.md) -- end-to-end picture (memory + second_brain + hooks)
- [HOOKS.md](HOOKS.md) -- hook contracts and patterns
- [MEMORY.md](MEMORY.md) -- role-based memory (active/passive/archive) + event-driven consolidation
- [MULTI-AGENT.md](MULTI-AGENT.md) -- multiple agents over one shared brain
- [FIRST-AGENT.md](FIRST-AGENT.md) -- worked example of first agent setup
