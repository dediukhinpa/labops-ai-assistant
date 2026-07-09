# agent-template

Complete Claude Code agent workspace template, wired to a shared **second_brain** MCP
server (memory + memory_router + agent_router). Ported from
`public-architecture-claude-code` and adapted: the upstream semantic-memory
backend is replaced with second_brain MCP memory_router (HTTP + Bearer + JSON-RPC).

## Two ways to use this

### 1. Standalone (recommended)

Create a fresh per-agent workspace at `~/.claude-lab/<agent-id>/.claude/`:

```bash
cd public-second_brain-agentos/agent-template
bash install.sh
```

The installer asks for agent identity, operator profile, and **second_brain
connection** (`MCP_HOST` host/IP, `AGENT_BEARER`, `AGENT_SCOPES`). It renders
templates, copies scripts and hooks, writes `.mcp.json`, and optionally
symlinks the shared skills bundle from `../skills/`.

Then:

```bash
source ~/.claude-lab/<agent-id>/.claude/agent.env
claude --project ~/.claude-lab/<agent-id>/.claude
```

See [docs/SETUP-GUIDE.md](docs/SETUP-GUIDE.md) for the full walkthrough.

### 2. Overlay onto an existing project

Copy just the files you want into an existing `.claude/` directory:

```
templates/mcp.json.template    -> .claude/.mcp.json
templates/settings.json.template -> .claude/settings.json
hooks/*.sh                     -> .claude/hooks/
scripts/*.sh                   -> .claude/scripts/   (optional)
```

Render `${SECOND_BRAIN_MEMORY_URL}`, `${SECOND_BRAIN_MEMORY_ROUTER_URL}`,
`${SECOND_BRAIN_AGENT_ROUTER_URL}`, `${AGENT_BEARER}`, `{{AGENT_ID}}`
placeholders manually (or with `envsubst`). The hooks tolerate missing files
and never block the harness on failure.

## Workspace layout (what install.sh creates)

```
~/.claude-lab/<agent-id>/.claude/
|-- CLAUDE.md                  # SOUL / identity
|-- .mcp.json                  # second_brain memory/memory_router/agent_router endpoints (chmod 600)
|-- settings.json              # Claude Code hooks (SessionStart/Stop/PreCompact)
|-- agent.env                  # source this to export MCP_HOST/SECOND_BRAIN_*_URL/AGENT_BEARER
|-- core/
|   |-- USER.md
|   |-- rules.md
|   |-- AGENTS.md
|   |-- MEMORY.md              # ARCHIVE archive
|   |-- LEARNINGS.md
|   |-- passive/                  # semantic insights (insights/decisions/errors/preferences)
|   |-- active/
|   |   |-- episodic.md          # raw append-only diary
|   |   |-- working-set.md       # materialised recall (rebuilt)
|   |   `-- handoff.md
|   `-- archived/               # episodic/ (size-rolled) + superseded/ (decayed insights)
|-- tools/TOOLS.md
|-- scripts/                   # memory engine: active-writer, working-set-build, reflect-nudge, decay-sweep, archive-roll
|-- hooks/                     # session-start, user-prompt-submit, stop, precompact
|-- logs/
`-- skills/                    # symlink to ../skills/ shared bundle
```

## Directory layout (this template)

```
agent-template/
|-- README.md                          (this file)
|-- install.sh                         interactive installer
|-- templates/
|   |-- CLAUDE.md.template             SOUL skeleton
|   |-- global-CLAUDE.md.template      ~/.claude/CLAUDE.md
|   |-- rules.md.template
|   |-- tools.md.template
|   |-- agents.md.template
|   |-- USER.md.template
|   |-- decisions.md.template
|   |-- episodic.md.template
|   |-- MEMORY.md.template
|   |-- LEARNINGS.md.template
|   |-- mcp.json.template              .mcp.json with 3 second_brain servers
|   `-- settings.json.template         hooks wiring
|-- scripts/
|   |-- active-writer.sh              episodic writer (Stop hook), salience-tagged, no model
|   |-- working-set-build.sh          rebuild working-set.md: second_brain recall + local passive/ (non-blocking)
|   |-- reflect-nudge.sh              nudge the LIVE session to consolidate (agent_router.notify; no `claude -p`)
|   |-- decay-sweep.sh                nightly bash housekeeping: reinforce + decay passive/ -> archived/superseded/
|   `-- archive-roll.sh               nightly bash housekeeping: size-roll episodic.md -> archived/episodic/YYYY-MM.md
|-- hooks/
|   |-- session-start-hook.sh
|   |-- user-prompt-submit-hook.sh
|   |-- stop-hook.sh
|   |-- precompact-hook.sh
|   `-- README.md
`-- docs/
    |-- ARCHITECTURE.md
    |-- MEMORY.md
    |-- HOOKS.md
    |-- MULTI-AGENT.md
    |-- TOKEN-OPTIMIZATION.md
    |-- SETUP-GUIDE.md                 (this is the path you usually want)
    |-- SUBAGENTS.md
    |-- SKILLS.md
    |-- AGENT-LAWS.md
    |-- COMMANDS-QUICKREF.md
    |-- STRUCTURE.md
    |-- FILES-REFERENCE.md
    |-- FIRST-AGENT.md
    |-- MAPPING.md
    |-- LEARNINGS.md
    `-- CHECKLIST.md
```

## Differences from upstream `public-architecture-claude-code`

| Upstream | Here |
|---|---|
| Upstream semantic-memory backend (HTTP REST `/api/v1/...`) | second_brain MCPs (HTTP MCP transport, JSON-RPC 2.0, Bearer auth) |
| Bearer/API key under `~/.claude-lab/shared/secrets/` (file on disk) | Bearer in `.mcp.json` `Authorization: Bearer ${AGENT_BEARER}` (chmod 600) |
| Upstream session-sync script (uploads ACTIVE+PASSIVE to the memory server) | `scripts/working-set-build.sh` (fuses second_brain recall + local `passive/` into `active/working-set.md`, non-blocking) |
| Standalone install | Lives inside the public-second_brain-agentos distro alongside the server, inbox-agent, and skills bundle |
| Hooks described in docs only | Concrete `hooks/*.sh` shipped, wired via `templates/settings.json.template` |

## License

Apache 2.0 -- inherited from public-second_brain-agentos. See [../LICENSE](../LICENSE).
