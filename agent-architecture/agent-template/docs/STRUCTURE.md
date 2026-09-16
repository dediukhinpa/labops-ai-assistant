# File Structure

> **NOTE:** Agent ids (`developer`, `carmella`) are examples. Replace with your own.
> What each file holds and who writes it: [FILES-REFERENCE.md](FILES-REFERENCE.md).

## Directory Layout

```
~/
├── .claude/                           GLOBAL (every agent of this OS user reads it)
│   ├── CLAUDE.md                      rules shared by all agents
│   └── rules/
│       ├── bash.md                    set -euo pipefail...
│       ├── python.md                  type hints, pathlib...
│       └── typescript.md              strict, no any...
│
├── labops-ai-assistant/agent-architecture/
│   └── skills/                        the shared skills (every workspace links here)
│
└── .claude-lab/
    ├── shared/                        SHARED RESOURCES
    │   ├── secrets/
    │   │   └── groq-api-key           Groq Whisper key (one for all agents)
    │   └── state/<agent>/telegram/    per-agent channel state
    │       ├── channel.env            bot token, allowed users, webhook port + token
    │       ├── config.json            webhook.enabled, status.suppress_typing_bubble
    │       └── webhook-token          webhook token as a flat file
    │
    ├── developer/                     AGENT 1 (example id)
    │   ├── logs/watchdog.log          systemd unit output
    │   └── .claude/                   workspace
    │       ├── CLAUDE.md              SOUL + @imports:
    │       │   @core/USER.md
    │       │   @core/rules.md
    │       │   @SECONDBRAIN_WRITE_RULES.md
    │       │   @AGENT_ROUTER.md
    │       │   @core/passive/decisions.md
    │       │   @core/passive/preferences.md
    │       ├── SECONDBRAIN_WRITE_RULES.md
    │       ├── AGENT_ROUTER.md
    │       ├── settings.json          model, permissions, hooks
    │       ├── .mcp.json              4 second_brain servers + Bearer (chmod 600)
    │       ├── agent.env              service URLs, Bearer, scopes (chmod 600)
    │       ├── core/
    │       │   ├── USER.md            who the operator is
    │       │   ├── rules.md           orders to self, earned from mistakes
    │       │   ├── AGENTS.md          models, pipelines, team
    │       │   ├── passive/           distilled by memory-consolidate
    │       │   │   ├── decisions.md   what we chose and why (in context)
    │       │   │   ├── preferences.md how the operator wants work done (in context, never decays)
    │       │   │   ├── errors.md      what broke and how to avoid it
    │       │   │   └── insights.md    other durable facts
    │       │   ├── active/
    │       │   │   ├── episodic.md    raw diary, one entry per turn
    │       │   │   └── pre-compact/   diary snapshots before compaction
    │       │   └── archived/
    │       │       ├── episodic/YYYY-MM.md  diary entries rolled out by size
    │       │       └── superseded/    decayed passive entries
    │       ├── tools/TOOLS.md         infrastructure map
    │       ├── hooks/                 heartbeat, session-start, stop, precompact
    │       ├── scripts/               active-writer, reflect-nudge, decay-sweep, archive-roll,
    │       │                          brain-flush, mcp-call, task-poller.sh, task_poller.py
    │       ├── skills → ~/labops-ai-assistant/agent-architecture/skills (symlink)
    │       ├── agents/                subagent .md definitions
    │       ├── labops-tg-plugin/plugin/  private copy of the Telegram channel
    │       ├── state/                 heartbeat, last-housekeeping, brain-flush.sha
    │       └── logs/                  hooks.log, verbose-YYYY-MM-DD.jsonl
    │
    └── carmella/                      AGENT 2 (example id) -- same layout

/etc/systemd/system/claude-agent-<agent>.service   autostart: systemd → watchdog → tmux + claude
```

## What's Isolated vs Shared

| Per agent | Shared |
|-----------|--------|
| CLAUDE.md (SOUL), core/, tools/TOOLS.md | ~/.claude/CLAUDE.md, ~/.claude/rules/*.md |
| hooks/, scripts/ (copies) | skills (one directory, symlinked) |
| settings.json, .mcp.json, agent.env | shared/secrets/groq-api-key |
| channel.env, bot, webhook port | second_brain (vault and task board) |
| plugin copy, systemd unit, tmux session | the OS user the agents run as |

"Per agent" is a layout convention, not an access boundary: all agents run as one OS
user and can read each other's files.
