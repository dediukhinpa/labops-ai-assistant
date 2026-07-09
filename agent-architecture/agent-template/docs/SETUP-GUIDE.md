# Setup Guide -- agent-template

Step-by-step setup for an agent workspace wired to a shared second_brain MCP server.

This is the "client-side" of the public-second_brain-agentos distro. The "server-side"
(memory MCP, memory_router MCP, agent_router MCP, Postgres + pgvector) is
documented in [../docs/SERVER-SETUP.md](../docs/SERVER-SETUP.md) and installed
via [../scripts/install-vps.sh](../scripts/install-vps.sh). You **must** have a
running second_brain server (or know its `MCP_HOST` host/IP and have a Bearer token for
your agent) before running `install.sh` here.

## Architecture in one paragraph

`agent-template/install.sh` creates `~/.claude-lab/<agent-id>/.claude/`. Inside,
a four-layer memory pyramid (IDENTITY -> WARM -> HOT -> COLD) lives as Markdown
files. A `.mcp.json` points Claude Code at three remote MCP servers --
**memory** (write decisions / knowledge / external notes, default port 5001),
**memory_router** (read shared semantic memory, default port 5002),
**agent_router** (notify other agents, default port 5000) -- each on its own
port, all Bearer-authenticated. Three local hooks
(`session-start`, `stop`, `precompact`) keep the local memory fresh; an
optional `second_brain-memory_router-on-start.sh` pulls top-N relevant items from the
shared brain on each session start.

## Prerequisites

- macOS or Linux with bash, `jq`, `python3`, `curl`, `git`
- Claude Code CLI: `curl -fsSL https://claude.ai/install.sh | bash` (native installer, no Node.js needed)
- second_brain server already deployed and reachable. You need:
  - `MCP_HOST` — host/IP only, no protocol or port (e.g. `127.0.0.1` or `mcp.example.com`). The three per-service endpoint URLs (`SECOND_BRAIN_MEMORY_URL` on port 5001, `SECOND_BRAIN_MEMORY_ROUTER_URL` on port 5002, `SECOND_BRAIN_AGENT_ROUTER_URL` on port 5000) are derived automatically, or override them directly if you front the server with your own reverse proxy.
  - Agent bearer token issued by
    [`../scripts/issue-agent-token.py`](../scripts/issue-agent-token.py) on the
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
|-- settings.json              # Claude Code hooks (SessionStart/Stop/PreCompact)
|-- agent.env                  # source this to export MCP_HOST/SECOND_BRAIN_*_URL/AGENT_BEARER
|-- core/
|   |-- USER.md                # operator profile
|   |-- rules.md               # operational rules (RED zone, security)
|   |-- AGENTS.md              # team / models / pipelines
|   |-- MEMORY.md              # COLD archive (>14d, on-demand Read)
|   |-- LEARNINGS.md           # structured log of corrections
|   |-- warm/decisions.md      # last 14d decisions (auto-rotated)
|   `-- hot/
|       |-- recent.md          # 24h rolling journal (Stop hook appends)
|       |-- handoff.md         # last-N entries used by SessionStart
|       |-- archive/           # old recent.md slices
|       `-- pre-compact/       # PreCompact snapshots (rotated)
|-- tools/TOOLS.md             # infra map
|-- scripts/                   # memory-rotate, trim-hot, rotate-warm,
|                              # compress-warm, second_brain-memory_router-on-start
|-- hooks/                     # session-start, stop, precompact
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

On session start, the `SessionStart` hook reads `core/hot/handoff.md`, and if
`SECOND_BRAIN_MEMORY_ROUTER_URL` / `AGENT_BEARER` are set, runs
`scripts/second_brain-memory_router-on-start.sh` which posts a JSON-RPC
`tools/call recall` to `${SECOND_BRAIN_MEMORY_ROUTER_URL}` and prepends a
`### YYYY-MM-DD HH:MM [second_brain-memory_router]` block to `core/hot/recent.md`.

On each turn end, `Stop` hook appends a 200-char snippet to `recent.md` and a
full JSON envelope to `logs/verbose-YYYY-MM-DD.jsonl`.

Before Claude Code auto-compacts context, `PreCompact` hook snapshots
`recent.md` to `core/hot/pre-compact/recent-<ts>.md`.

## Memory rotation cron (optional)

```cron
30 4 * * * AGENT_WORKSPACE=$HOME/.claude-lab/<agent-id>/.claude bash $HOME/.claude-lab/<agent-id>/.claude/scripts/rotate-warm.sh
 0 5 * * * AGENT_WORKSPACE=$HOME/.claude-lab/<agent-id>/.claude bash $HOME/.claude-lab/<agent-id>/.claude/scripts/trim-hot.sh
 0 6 * * * AGENT_WORKSPACE=$HOME/.claude-lab/<agent-id>/.claude bash $HOME/.claude-lab/<agent-id>/.claude/scripts/compress-warm.sh
 0 21 * * * AGENT_WORKSPACE=$HOME/.claude-lab/<agent-id>/.claude bash $HOME/.claude-lab/<agent-id>/.claude/scripts/memory-rotate.sh
```

`trim-hot.sh` and `compress-warm.sh` shell out to `claude --model sonnet --print`
for smart summarization; if Sonnet is unreachable they fall back to a bash
extraction so memory still gets pruned.

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
   absent files (handoff, recent.md) and won't break the harness.

Either way the wire protocol to second_brain is identical: HTTP MCP transport, Bearer
in `Authorization` header, JSON-RPC 2.0 in the body.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `second_brain-memory_router-on-start.sh` logs "SECOND_BRAIN_MEMORY_ROUTER_URL or AGENT_BEARER unset" | shell didn't `source agent.env` | `source ~/.claude-lab/<agent-id>/.claude/agent.env` before `claude` |
| recall returns `403` | token has no `inbox` (or relevant) scope, or wrong agent | re-issue with `issue-agent-token.py --scopes ...` |
| recall returns empty results | second_brain DB has no notes yet | use `create_decision_note` first, or backfill from existing decisions.md |
| `Stop` hook never fires | `settings.json` not picked up | confirm `claude --project` points at the workspace dir that contains `settings.json` |
| `trim-hot.sh` skips silently | HOT < 10KB | by design; only compresses once the file grows |

## Where to look next

- [ARCHITECTURE.md](ARCHITECTURE.md) -- end-to-end picture (memory + second_brain + hooks)
- [HOOKS.md](HOOKS.md) -- hook contracts and patterns
- [MEMORY.md](MEMORY.md) -- 4-layer memory rotation rules
- [MULTI-AGENT.md](MULTI-AGENT.md) -- multiple agents over one shared brain
- [FIRST-AGENT.md](FIRST-AGENT.md) -- worked example of first agent setup
