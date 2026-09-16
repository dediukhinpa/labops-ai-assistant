# Files Reference -- Complete Map

Every file an agent gets at install, its role, who writes it, whether it is loaded
into context, and how it ages. Paths are relative to the agent workspace
`~/.claude-lab/<agent>/.claude/` unless shown in full.

## Legend

- **Loads:** `always` = pulled into every session (`@import` in `CLAUDE.md`, or read
  by Claude Code itself); `on-demand` = the agent reads it with the Read tool when needed;
  `never` = not meant for the model.
- **Writer:** who creates or updates the file after install.
- **Ages:** whether an automatic job moves old content out.

---

## Layer 1: Global (`~/.claude/`)

Shared by every agent of this OS user. Written once by `install.sh` when missing.

| File | Role | Loads | Writer |
|------|------|-------|--------|
| **CLAUDE.md** | Rules for every agent: hierarchy, red zone, language, git, security, model changes, principles | always | operator |
| **rules/bash.md**, **rules/python.md**, **rules/typescript.md** | Code style per language | always | operator |

If `~/.claude/CLAUDE.md` already holds someone else's rules, the installer writes
ours next to it as `CLAUDE.md.labops-new` and asks the operator to merge it.

---

## Layer 2: Identity and rules

| File | Role | Loads | Writer |
|------|------|-------|--------|
| **CLAUDE.md** | SOUL: role, character, green/red zones, way of working, channel rule (answer only through `reply`), shared-brain duties. Ends with the `@import` list below | always | operator |
| **core/USER.md** | **Who the operator is**: name, form of address, timezone, language, profile, channels. Facts that rarely change | always | operator, or the agent when asked |
| **core/rules.md** | **Orders to the agent itself** ("always… / never…") earned from its own mistakes. Empty at install. A rule is added only when the operator says "write yourself a rule", or when a correction repeats and the operator agrees to the proposed rule | always | operator, or the agent after consent (RED) |
| **SECONDBRAIN_WRITE_RULES.md** | What to write to the shared brain, with which tool, and when | always | operator (RED) |
| **AGENT_ROUTER.md** | How agents hand work to each other through the task board | always | operator |
| **core/AGENTS.md** | Models, pipelines, second_brain endpoints, team table | on-demand | operator; agent on a trigger |
| **tools/TOOLS.md** | Infrastructure map: workspace paths, access zones, skills, secret *paths*, servers, services | on-demand | operator; agent on a trigger |

`@import` list in `CLAUDE.md`: `core/USER.md`, `core/rules.md`,
`SECONDBRAIN_WRITE_RULES.md`, `AGENT_ROUTER.md`, `core/passive/decisions.md`,
`core/passive/preferences.md`.

---

## Layer 3: Memory -- PASSIVE (`core/passive/`)

Distilled knowledge. Written by the **live session** through the `memory-consolidate`
skill (every ~20 turns, after ~10 min idle, or on request) -- never by a background
model. Each entry carries YAML frontmatter (`id`, `created`, `last_recalled`,
`recall_count`, `half_life_days`, `salience`, `provenance`).

| File | Holds | Example | Loads | Ages |
|------|-------|---------|-------|------|
| **decisions.md** | **What we chose** about the project/system, with date and reason. A fact about the world, not an order | "2026-09-02: recall moved to int8 embeddings -- the full model hit MemoryMax" | always | yes |
| **errors.md** | **What broke**: symptom, cause, how not to repeat it | "Stop hook wrote empty turns: the payload key is `last_assistant_message`" | on-demand | yes |
| **preferences.md** | **How the operator wants work done**, distilled from their corrections | "Documents for people: .docx, no meta sections" | always | **never** |
| **insights.md** | Any other durable fact that is none of the above | "An empty episodic.md alone does not mean the hook is broken" | on-demand | yes |

How the three look-alike pairs differ:
- `USER.md` vs `preferences.md` -- who the operator *is* vs how they *want things done*.
- `rules.md` vs `decisions.md` -- an order to the agent ("I must…") vs a recorded
  choice ("we chose…").
- `errors.md` vs `rules.md` -- the lesson from a failure vs the rule that follows once
  the same correction comes back and the operator agrees.

Only `preferences.md` and `decisions.md` cost context on every turn; keep them terse.
Created on first consolidation: `errors.md`, `insights.md`, `.consolidated-at`
(watermark: episodic entries older than this are already processed).

---

## Layer 4: Memory -- ACTIVE (`core/active/`)

| File | Role | Loads | Writer | Ages |
|------|------|-------|--------|------|
| **episodic.md** | Raw append-only diary: one entry per turn, never model-compressed | on-demand | `active-writer.sh` from the Stop hook | size-rolled past 40 KB |
| **consolidate.request** | Marker asking the session to consolidate (fallback when notify is down) | never | `reflect-nudge.sh`; deleted by `memory-consolidate` | -- |
| **pre-compact/** | Copies of `episodic.md` taken before each context compaction, newest 10 kept | never | `precompact-hook.sh` | rotated |

Entry format in `episodic.md`:
```
### YYYY-MM-DD HH:MM [source] {salience}
<turn text, snippet capped at MEMORY_SNIPPET_MAX = 200 chars>
```
`source` is the writer (`stop-hook` in practice). `salience` is a pure-bash guess:
`ephemeral | error | decision | preference | fact`; the session makes the real call
during consolidation.

The channel plugin has its own episodic writer (`TELEGRAM_MEMORY_ENABLED`), but it
fires from the Claude Code hooks posted to `/hooks/agent`, which the agent flow does
not install -- see `tg-plugin/plugin/docs/progress-reporter-setup.md`.

---

## Layer 5: Memory -- ARCHIVE (`core/archived/`)

Not loaded. Read by hand when history matters.

| Path | Role | Writer |
|------|------|--------|
| **archived/episodic/YYYY-MM.md** | Older diary entries moved out of `episodic.md`; text is relocated, never summarised | `archive-roll.sh` |
| **archived/superseded/*.md** | Passive entries that decayed without ever being recalled | `decay-sweep.sh` |

Both jobs are pure bash (no model) and run at most once a day from the Stop hook
(marker `state/last-housekeeping`).

---

## Layer 6: Shared brain -- second_brain (L4)

Not a file. Four MCP servers over HTTP, listed in `.mcp.json`, each authenticated with
the agent's Bearer token:

| Server | Port | Used for |
|--------|------|----------|
| `second_brain-memory` | 5001 | writes: `create_decision_note`, `supersede_decision`, `create_error_pattern_note`, `create_handoff`, ... |
| `second_brain-memory_router` | 5002 | `recall` -- hybrid search over the whole vault |
| `second_brain-agent_router` | 5000 | events between agents (`notify`, `list_my_pending`, `ack`) |
| `second_brain-tasks` | 5003 | the task board (`task_*`) |

A write succeeds only inside the scopes granted to the token (`AGENT_SCOPES` in
`agent.env` mirrors them). Default: `decisions, external, knowledge, inbox,
error-patterns, task-board`.

---

## Layer 7: Configuration and access

| File | Role | Loads | Writer |
|------|------|-------|--------|
| **settings.json** | Claude Code settings: `model`, auto-compact window, allow/deny lists, hooks | read by Claude Code | operator |
| **.mcp.json** | The four second_brain servers with URL and Bearer token (chmod 600) | read by Claude Code | installer; `connect-agents.sh` in second_brain |
| **agent.env** | `AGENT_ID`, workspace, service URLs, `AGENT_BEARER`, `AGENT_SCOPES`, `SUMMARY_LANGUAGE` (chmod 600) | never (sourced by the launcher) | installer; `connect-agents.sh` |

---

## Layer 8: Hooks (`hooks/`) and scripts (`scripts/`)

Copied per agent (each agent owns its copy). Pure bash/python; none calls a model --
`claude -p` is forbidden repo-wide.

| File | Fired by | Does |
|------|----------|------|
| **hooks/heartbeat-hook.sh** | SessionStart, UserPromptSubmit, Pre/PostToolUse, Notification, Stop | touches `state/heartbeat` -- the watchdog's proof of life |
| **hooks/session-start-hook.sh** | SessionStart | logs the start |
| **hooks/stop-hook.sh** | Stop (each turn) | diary entry via `active-writer.sh`; line in `logs/verbose-*.jsonl`; consolidation nudge every 20 turns; daily housekeeping |
| **hooks/precompact-hook.sh** | PreCompact | snapshot to `core/active/pre-compact/`, then `brain-flush.sh` |
| **scripts/active-writer.sh** | stop-hook | appends one salience-tagged diary entry |
| **scripts/reflect-nudge.sh** | stop-hook, watchdog idle | asks the live session to run `memory-consolidate` |
| **scripts/decay-sweep.sh** | stop-hook, daily | moves decayed, never-recalled passive entries to `archived/superseded/`; skips `preferences.md` |
| **scripts/archive-roll.sh** | stop-hook, daily | moves old diary entries to `archived/episodic/` when `episodic.md` > 40 KB |
| **scripts/brain-flush.sh** | PreCompact, SessionEnd | sends the diary tail to the shared brain (`inbox/`) as a safety net |
| **scripts/task-poller.sh** + **task_poller.py** | watchdog | polls the task board every 5 s and delivers new tasks into the session |
| **scripts/mcp-call.sh** | the scripts above | calls an MCP tool with the required session handshake |

Runtime files: `state/heartbeat`, `state/last-housekeeping`, `state/brain-flush.sha`;
logs in `logs/` (`hooks.log`, `verbose-YYYY-MM-DD.jsonl`, per-script logs).

---

## Layer 9: Skills, subagents, channel plugin

| Path | Role | Loads |
|------|------|-------|
| **skills** | Symlink to `agent-architecture/skills`, shared by every agent: agent-browser, create-agent, groq-voice, memory-consolidate, second_brain-doctor. An edit in the repo reaches all agents at once | on-demand (Skill tool) |
| **agents/** | Subagent definitions (`<name>.md`); empty at install | on-demand (Agent tool) |
| **labops-tg-plugin/plugin/** | Private copy of the Telegram channel plugin; `node_modules` links to the shared checkout. Refreshed only when the agent is created | never (runs as the channel MCP server) |

---

## Layer 10: Secrets

Never loaded into context, never committed, never printed.

| Path | What |
|------|------|
| `~/.claude-lab/shared/state/<agent>/telegram/channel.env` | Telegram bot token, allowed users, webhook port and token |
| `~/.claude-lab/shared/state/<agent>/telegram/webhook-token` | the webhook token again, as a flat file for the webhook listener |
| `~/.claude-lab/shared/secrets/groq-api-key` | Groq key for voice transcription, one for all agents |
| `.claude/agent.env`, `.claude/.mcp.json` | the agent's second_brain Bearer token |

Channel settings that are not secret live next to `channel.env` in `config.json`
(`webhook.enabled`, `status.suppress_typing_bubble`).

---

## Access -- what is enforced and what is not

The layers above describe **who is supposed to** change what. The operating system
does not enforce it: all agents on a host run as one OS user, so any agent can
technically read and write every file on this page, including other agents'
workspaces and secrets. Treat the zones as instructions to the model, not as a
security boundary.
