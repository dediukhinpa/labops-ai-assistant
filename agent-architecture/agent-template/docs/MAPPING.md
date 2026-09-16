# File Mapping -- OpenClaw vs Claude Code vs Our Architecture

How three systems name and use the same concepts. Use this to understand where each file comes from and why we chose our structure.

## Identity Files

| Concept | OpenClaw | Claude Code (official) | Our Architecture | Loads |
|---------|----------|----------------------|-----------------|-------|
| Agent personality, values, tone | `SOUL.md` | `CLAUDE.md` | `CLAUDE.md` (SOUL section) | always |
| Agent name, creature, avatar | `IDENTITY.md` | _(inside CLAUDE.md)_ | _(inside CLAUDE.md)_ | always |
| Operating rules, models, subagents | `AGENTS.md` | _(inside CLAUDE.md)_ | `core/AGENTS.md` (on-demand Read) | on-demand |
| Operator profile | `USER.md` | _(inside CLAUDE.md or rules/)_ | `core/USER.md` (@include) | always |
| Infrastructure, servers, services | `TOOLS.md` | _(inside CLAUDE.md)_ | `tools/TOOLS.md` (on-demand Read) | on-demand |
| Boundaries, permissions, red zones | _(inside AGENTS.md)_ | `.claude/rules/*.md` | `CLAUDE.md` (SOUL) | always |
| First-run setup ritual | `BOOTSTRAP.md` (deleted after) | _(none)_ | _(none -- install.sh replaces this)_ | once |
| Periodic heartbeat checklist | `HEARTBEAT.md` | _(none)_ | _(hooks + event-driven consolidation instead)_ | always |

### Why we split CLAUDE.md into multiple files

Claude Code officially uses one `CLAUDE.md` per scope. OpenClaw uses 7 separate files.

We use **1 CLAUDE.md + @include** -- best of both:
- Claude Code sees one entry point (CLAUDE.md)
- Content is split into focused files (like OpenClaw)
- `@include` directive loads them automatically
- Each file stays under 200 lines (Anthropic recommendation)

```
CLAUDE.md                    # SOUL: personality, principles (entry point)
  @core/USER.md              # who the operator is
  @core/rules.md             # orders to self, earned from mistakes
  @SECONDBRAIN_WRITE_RULES.md   # what to write to the shared brain
  @AGENT_ROUTER.md              # handing work to other agents (task board)
  @core/passive/decisions.md    # decisions (always in context)
  @core/passive/preferences.md  # how the operator wants things done
  @core/active/handoff.md       # where I left off (written by the agent itself)
  # On-demand (Read tool, NOT @include -- saves ~18KB):
  # core/AGENTS.md            # models, subagents, pipelines
  # tools/TOOLS.md            # servers, services, paths
```

---

## Memory

| Concept | OpenClaw | Claude Code (official) | Our Architecture |
|---------|----------|----------------------|-----------------|
| Episodic journal (events) | `memory/YYYY-MM-DD.md` (daily) | _(auto memory)_ | `core/active/episodic.md` (raw append-only diary, salience-tagged) |
| Semantic insights (knowledge) | _(inside MEMORY.md)_ | _(auto memory)_ | `core/passive/*.md` (insights, decisions, errors, preferences -- YAML frontmatter) |
| Long-term archive | `MEMORY.md` (manual curated) | `~/.claude/projects/*/memory/MEMORY.md` | `core/archived/` (on-demand) |
| Lessons from mistakes | _(inside MEMORY.md)_ | _(auto memory)_ | `core/passive/errors.md` (distilled by memory-consolidate); a repeated correction becomes a rule in `core/rules.md` once the operator agrees |
| Semantic search | _(none)_ | _(none)_ | second_brain L4 (`recall` over MCP) |

### How memory flows (role-based, event-driven)

`active` / `passive` / `archive` name a **role**, not an age.

```
Stop hook -> active/episodic.md (raw diary, salience-tagged, NEVER model-compressed)
                    |
     reflection (event-driven, not cron):
       - checkpoint every 20 turns (Stop counter)
       - watchdog idle 10 min
     reflect-nudge.sh -> LIVE session runs memory-consolidate skill
                    |
                    v
               passive/*.md (SEMANTIC insights, YAML frontmatter, dual-written to second_brain)
                    |
       decay-sweep.sh (daily bash, usage-driven)        archive-roll.sh (daily bash, size)
       score < 0.25 & never recalled                    episodic.md > 40KB
                    |                                          |
                    v                                          v
        archived/superseded/                        archived/episodic/YYYY-MM.md

Recall: the agent queries second_brain itself before a non-trivial task.
```

OpenClaw uses daily files (`memory/YYYY-MM-DD.md`) and a silent pre-compaction flush.
Claude Code uses auto memory (Claude decides what to save).
We use **event-driven consolidation** (reflection done by the live session, never a
background model -- `claude -p` is forbidden) plus daily **pure-bash** housekeeping
started by the Stop hook -- automated and predictable, no cron.

---

## Configuration

| Concept | OpenClaw | Claude Code (official) | Our Architecture |
|---------|----------|----------------------|-----------------|
| Global config | `~/.openclaw/config.json` | `~/.claude/settings.json` | `~/.claude/settings.json` |
| Project config | `openclaw.json` | `.claude/settings.json` | `.claude/settings.json` |
| Local overrides | _(env vars)_ | `.claude/settings.local.json` | `.claude/settings.local.json` |
| Language rules | _(inside AGENTS.md)_ | `~/.claude/rules/*.md` | `~/.claude/rules/*.md` |
| Path-specific rules | _(none)_ | `rules/*.md` with `paths:` frontmatter | `rules/*.md` with `paths:` frontmatter |

---

## Skills

| Concept | OpenClaw | Claude Code (official) | Our Architecture |
|---------|----------|----------------------|-----------------|
| Skill definition | `skills/*/config.json` + `handler.js` | `skills/*/SKILL.md` | `skills/*/SKILL.md` |
| Skill trigger | JSON config | YAML frontmatter in SKILL.md | YAML frontmatter in SKILL.md |
| Shared skills | `~/.openclaw/skills/` (global) | `~/.claude/skills/` (global) | `agent-architecture/skills` (symlinked into every workspace) |
| Skill arguments | `{{input}}` | `$ARGUMENTS`, `$0`, `$1` | `$ARGUMENTS` |
| Skill isolation | process fork | `context: fork` frontmatter | `context: fork` frontmatter |
| Skill model override | _(none)_ | `model:` frontmatter | `model:` frontmatter |

---

## Multi-Agent

| Concept | OpenClaw | Claude Code (official) | Our Architecture |
|---------|----------|----------------------|-----------------|
| Agent isolation | `~/.openclaw/workspace-{id}/` | separate project dirs | `~/.claude-lab/{agent}/.claude/` |
| Shared resources | _(none built-in)_ | _(none built-in)_ | `~/.claude-lab/shared/` |
| Inter-agent messaging | _(none built-in)_ | _(none built-in)_ | second_brain: task board (`task_*`) + agent_router events |
| Subagent definitions | _(none)_ | `.claude/agents/*.md` | `.claude/agents/*.md` |
| Chat channel | _(none)_ | _(none)_ | Telegram channel plugin, one bot per agent (`labops-tg-plugin/`) |
| Secrets | per-agent `auth-profiles.json` | _(none built-in)_ | per agent: `shared/state/<agent>/telegram/channel.env`, `agent.env`; shared: `shared/secrets/` |

---

## Folder Naming

| Our path | Why this name | Based on |
|----------|---------------|----------|
| `~/.claude/` | Official Claude Code global dir | Claude Code official |
| `~/.claude-lab/` | Multi-agent workspace root | Our convention (lab = workspace) |
| `~/.claude-lab/shared/` | Resources shared across agents | Our convention |
| `~/.claude-lab/{agent}/.claude/` | Per-agent project directory | Claude Code project scope |
| `core/` | Identity + memory files | Our convention (core = essential) |
| `core/passive/` | Semantic insights (consolidated) | Our convention (passive = knowledge, recalled on demand) |
| `core/active/` | Raw episodic diary + handoff | Our convention (active = current-task working memory) |
| `core/archived/` | Aged-out episodic + decayed insights | Our convention (archive = cold storage) |
| `tools/` | Infrastructure descriptions | OpenClaw convention (TOOLS.md) |
| `skills/` | Callable commands | Claude Code official |
| `agents/` | Subagent definitions | Claude Code official |
| `scripts/` | Memory helpers fired by hooks and the watchdog | Our convention |

---

## Key Decisions

### What we took from OpenClaw
- Separate identity files (SOUL, AGENTS, USER, TOOLS) instead of one giant CLAUDE.md
- Per-agent workspace isolation

### What we took from Claude Code
- `@include` directive to compose CLAUDE.md from parts
- `.claude/rules/` for language-specific rules with path matching
- `.claude/skills/` with SKILL.md format and YAML frontmatter
- `.claude/agents/` for subagent definitions
- `settings.json` for hooks, permissions, config

### What we added
- **Role-based memory** (active episodic -> passive semantic insights -> archive -> L4 semantic) with event-driven consolidation
- **Shared resources** (`shared/secrets/`, one skills directory for all agents)
- **Telegram channel plugin**: one bot per agent, messages injected into the live session
- **In-session reflection + decay/reinforcement** for memory management (episodic never model-compressed, only role-promoted and size/usage-rolled by pure bash)
- **Task board + agent_router** in second_brain for inter-agent work
- **second_brain** for semantic memory search
