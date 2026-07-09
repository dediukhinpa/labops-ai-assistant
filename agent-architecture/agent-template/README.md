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
|   |-- MEMORY.md              # COLD archive
|   |-- LEARNINGS.md
|   |-- warm/decisions.md      # last 14d
|   `-- hot/
|       |-- recent.md          # 24h rolling
|       |-- handoff.md
|       |-- archive/
|       `-- pre-compact/
|-- tools/TOOLS.md
|-- scripts/                   # memory rotation + second_brain-memory_router-on-start
|-- hooks/                     # session-start, stop, precompact
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
|   |-- recent.md.template
|   |-- MEMORY.md.template
|   |-- LEARNINGS.md.template
|   |-- mcp.json.template              .mcp.json with 3 second_brain servers
|   `-- settings.json.template         hooks wiring
|-- scripts/
|   |-- memory-rotate.sh               archive COLD when >5KB
|   |-- trim-hot.sh                    compress HOT via Sonnet
|   |-- rotate-warm.sh                 move WARM >14d to COLD
|   |-- compress-warm.sh               Sonnet-compress WARM
|   `-- second_brain-memory_router-on-start.sh      pull top-N recalls at SessionStart
|-- hooks/
|   |-- session-start-hook.sh
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
| Upstream session-sync script (uploads HOT+WARM to the memory server) | `scripts/second_brain-memory_router-on-start.sh` (pulls top-N recalls into HOT) |
| Standalone install | Lives inside the public-second_brain-agentos distro alongside the server, inbox-agent, and skills bundle |
| Hooks described in docs only | Concrete `hooks/*.sh` shipped, wired via `templates/settings.json.template` |

## License

Apache 2.0 -- inherited from public-second_brain-agentos. See [../LICENSE](../LICENSE).
