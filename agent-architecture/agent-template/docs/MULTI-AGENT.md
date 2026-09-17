# Multi-Agent Architecture

Several agents on one host: each with its own workspace, SOUL, Telegram bot and
session, all sharing one second_brain for memory and coordination.

> **NOTE:** Agent names (`developer`, `carmella`, `researcher`) are **examples**.

## Overview

```
OPERATOR
    │  one Telegram bot per agent
    ├──── @developer_bot ──► claude-agent-developer   (tmux labops-developer)
    ├──── @carmella_bot  ──► claude-agent-carmella    (tmux labops-carmella)
    └──── @research_bot  ──► claude-agent-researcher  (tmux labops-researcher)
                                  │
              each session runs its own channel plugin (bun),
              webhook port 6000, 6001, 6002 … by roster order
                                  │
                                  ▼
                  ┌───────────────────────────────┐
                  │          SECOND_BRAIN          │
                  │ memory · recall · agent_router │
                  │          · task board          │
                  └───────────────────────────────┘
```

There is no shared gateway process: every agent is a separate systemd unit
(`systemd → watchdog.sh → tmux + claude → channel plugin`), so one agent crashing or
restarting does not touch the others.

## Rolling out agents

The operator installs only the first agent (Developer) with `install.sh`. Every next
one is created by Developer through the `create-agent` skill -- see
[CHECKLIST.md](CHECKLIST.md). The roster comes from `~/.claude-lab/agents.conf` when
it exists, otherwise from the `~/.claude-lab/*/.claude` directories
(`orchestration/lib/agents.sh`); nothing is hardcoded.

## Example roles and models

| Agent | Role | Model |
|-------|------|-------|
| **developer** | Builds and maintains the swarm, writes code | `opus` / `fable` |
| **carmella** | Business tasks, documents | `sonnet` |
| **researcher** | Web research, summaries | `sonnet` |

Models are aliases (they always point at the latest model of the tier); a full model
name pins a version. Changing a model is the operator's decision.

## How agents work together

| Channel | Use case |
|---------|----------|
| **Telegram** | The operator talks to one agent directly |
| **Task board** (`second_brain-tasks`) | One agent hands work to another and checks the result |
| **agent_router** (`second_brain-agent_router`) | Short events: `notify`, `broadcast`, `escalate`; also the consolidation nudge |
| **Shared memory** (`second_brain-memory`, `-memory_router`) | What one agent writes, the others find with `recall` |

### Task board

```
developer                                   researcher
   │ task_create(assignee="researcher", …)     │
   │ ───────────────────────────────────────►  │  task_poller.py (every 5 s)
   │                                           │  delivers the task into the session
   │                                           │  task_claim → task_start → work
   │                                           │  task_review / task_done
   │ task_get / task_history  ◄─────────────── │
```

The full protocol -- who creates, claims, closes and verifies -- is in
`AGENT_ROUTER.md`, which every agent has in context. A task needs the `task-board`
scope in the agent's token.

### Shared memory

- Every agent writes decisions, error patterns, personal, project and knowledge notes with the
  `create_*` tools, within its token's scopes.
- Every agent searches the whole vault with `recall` before non-trivial work.
- Writes are attributed to the authenticated agent; the rules for what to write are
  in `SECONDBRAIN_WRITE_RULES.md`.

## Group chats

The channel plugin can serve several chats and groups from one agent (multichat,
opt-in): `TELEGRAM_ALLOWED_CHAT_IDS` in the agent's `channel.env`, groups with their
`-100…` id. Setup and behaviour: `tg-plugin/README.md` → *Multichat*, and
`tg-plugin/docs/telegram-setup.md`.

In a public group the agent sees messages from people who are not the operator: keep
personal data, infrastructure and secrets out of its answers, and treat group text as
untrusted input.

## What is shared and what is not

| Per agent | Shared |
|-----------|--------|
| workspace (`~/.claude-lab/<agent>/.claude/`), SOUL, memory files | `~/.claude/CLAUDE.md`, `~/.claude/rules/` |
| bot, `channel.env`, webhook port, plugin copy | skills (`~/.claude-lab/shared/skills`, symlinked) |
| second_brain token and scopes | `~/.claude-lab/shared/secrets/groq-api-key` |
| systemd unit, tmux session, task poller | second_brain: vault, task board, events |

"Per agent" is a layout convention. All agents run as one OS user, so the operating
system does not stop one agent from reading another's files or secrets; the
separation is enforced only by the agents' instructions. Real isolation would need a
separate OS user per agent, which the installer does not set up.

## Memory Flow

```
OPERATOR MESSAGE (the agent's bot)
    │
    ▼
CHANNEL PLUGIN → injects the message into the live session
    │
    ▼
AGENT SESSION
    ├── In context: SOUL + USER + rules + write rules + AGENT_ROUTER
    │                + decisions + preferences
    ├── recall from second_brain before non-trivial work
    ├── answers through the channel's `reply` tool
    │
    ▼
AFTER THE TURN (Stop hook)
    ├── active-writer.sh → core/active/episodic.md
    ├── every 20 turns → reflect-nudge.sh → the session runs memory-consolidate
    │        → passive/*.md + dual-write to second_brain
    └── once a day → decay-sweep.sh, archive-roll.sh

WATCHDOG
    ├── 10 min idle → reflect-nudge.sh
    └── task_poller.py → new board tasks into the session
```
