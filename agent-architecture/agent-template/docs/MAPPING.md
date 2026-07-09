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
| Boundaries, permissions, red zones | _(inside AGENTS.md)_ | `.claude/rules/*.md` | `core/rules.md` (@include) | always |
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
  @core/USER.md              # operator profile
  @core/rules.md             # boundaries, security
  @core/passive/*.md            # semantic insights (decisions/errors/preferences)
  @core/active/handoff.md       # compact extract (last 10 entries)
  @core/active/working-set.md   # materialised recall for the current task
  # On-demand (Read tool, NOT @include -- saves ~18KB):
  # core/AGENTS.md            # models, subagents, pipelines
  # tools/TOOLS.md            # servers, services, paths
```

---

## Memory

| Concept | OpenClaw | Claude Code (official) | Our Architecture |
|---------|----------|----------------------|-----------------|
| Episodic journal (events) | `memory/YYYY-MM-DD.md` (daily) | _(auto memory)_ | `core/active/episodic.md` (raw append-only diary, salience-tagged) |
| Materialised recall | _(none)_ | _(auto memory)_ | `core/active/working-set.md` (rebuilt per task from recall) |
| Semantic insights (knowledge) | _(inside MEMORY.md)_ | _(auto memory)_ | `core/passive/*.md` (insights, decisions, errors, preferences -- YAML frontmatter) |
| Long-term archive | `MEMORY.md` (manual curated) | `~/.claude/projects/*/memory/MEMORY.md` | `core/MEMORY.md` + `core/archived/` (on-demand) |
| Lessons from mistakes | _(inside MEMORY.md)_ | _(auto memory)_ | `core/LEARNINGS.md` (on-demand) |
| Semantic search | _(none)_ | _(none)_ | second_brain L4 (HTTP API) |

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
       decay-sweep.sh (nightly bash, usage-driven)      archive-roll.sh (nightly bash, size)
       score < 0.25 & never recalled                    episodic.md > 40KB
                    |                                          |
                    v                                          v
        archived/superseded/                        archived/episodic/YYYY-MM.md

Recall (SessionStart + worthy prompts): working-set-build.sh fuses second_brain
recall + local passive/ into active/working-set.md (non-blocking, hard timeout).
```

OpenClaw uses daily files (`memory/YYYY-MM-DD.md`) and a silent pre-compaction flush.
Claude Code uses auto memory (Claude decides what to save).
We use **event-driven consolidation** (reflection done by the live session, never a
background model -- `claude -p` is forbidden) plus one optional nightly **pure-bash**
housekeeping cron -- automated, predictable, agent-independent.

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
| Shared skills | `~/.openclaw/skills/` (global) | `~/.claude/skills/` (global) | `shared/skills/` (symlinked) |
| Skill arguments | `{{input}}` | `$ARGUMENTS`, `$0`, `$1` | `$ARGUMENTS` |
| Skill isolation | process fork | `context: fork` frontmatter | `context: fork` frontmatter |
| Skill model override | _(none)_ | `model:` frontmatter | `model:` frontmatter |

---

## Multi-Agent

| Concept | OpenClaw | Claude Code (official) | Our Architecture |
|---------|----------|----------------------|-----------------|
| Agent isolation | `~/.openclaw/workspace-{id}/` | separate project dirs | `~/.claude-lab/{agent}/.claude/` |
| Shared resources | _(none built-in)_ | _(none built-in)_ | `~/.claude-lab/shared/` |
| Inter-agent messaging | _(none built-in)_ | _(none built-in)_ | message bus (inbox per agent) |
| Subagent definitions | _(none)_ | `.claude/agents/*.md` | `.claude/agents/*.md` |
| Gateway/router | _(none)_ | _(none)_ | `shared/gateway/` (Telegram) |
| Secrets sharing | per-agent `auth-profiles.json` | _(none built-in)_ | `shared/secrets/` (one folder) |

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
| `core/active/` | Raw episodic diary + working-set | Our convention (active = current-task working memory) |
| `core/archived/` | Aged-out episodic + decayed insights | Our convention (archive = cold storage) |
| `tools/` | Infrastructure descriptions | OpenClaw convention (TOOLS.md) |
| `skills/` | Callable commands | Claude Code official |
| `agents/` | Subagent definitions | Claude Code official |
| `scripts/` | Cron jobs, utilities | Our convention |

---

## Key Decisions

### What we took from OpenClaw
- Separate identity files (SOUL, AGENTS, USER, TOOLS) instead of one giant CLAUDE.md
- Explicit MEMORY.md as curated archive
- LEARNINGS.md for mistake tracking
- Per-agent workspace isolation

### What we took from Claude Code
- `@include` directive to compose CLAUDE.md from parts
- `.claude/rules/` for language-specific rules with path matching
- `.claude/skills/` with SKILL.md format and YAML frontmatter
- `.claude/agents/` for subagent definitions
- `settings.json` for hooks, permissions, config

### What we added
- **Role-based memory** (active episodic + working-set -> passive semantic insights -> archive -> L4 semantic) with event-driven consolidation
- **Shared resources** (`shared/secrets/`, `shared/skills/`, `shared/gateway/`)
- **Telegram gateway** routing multiple bots to multiple agents
- **In-session reflection + decay/reinforcement** for memory management (episodic never model-compressed, only role-promoted and size/usage-rolled by pure bash)
- **Message bus** for inter-agent communication
- **second_brain** for semantic memory search
