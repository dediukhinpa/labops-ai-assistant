# File Structure

> **NOTE:** Agent names (`claude-code`, `jarvis`) are examples. Replace with your own.

## Directory Layout

```
~/
├── .claude/                           GLOBAL (all agents read this)
│   ├── CLAUDE.md                      global rules, conventions
│   └── rules/
│       ├── bash.md                    set -euo pipefail...
│       ├── python.md                  type hints, pathlib...
│       └── typescript.md              strict, no any...
│
└── .claude-lab/
    ├── shared/                        SHARED RESOURCES
    │   ├── secrets/                   ONE folder for all secrets
    │   │   ├── .env                   shared env vars
    │   │   ├── groq-api-key           Groq Whisper API key
    │   │   ├── second_brain.key         second_brain API key
    │   │   ├── db-service-account.json  database service account
    │   │   └── telegram/
    │   │       ├── bot-token-agent1   per-bot tokens
    │   │       └── bot-token-agent2
    │   ├── skills/                    shared skills (symlinked)
    │   │   ├── groq-voice/            voice transcription
    │   │   ├── superpowers/           TDD, debugging, planning, review
    │   │   └── ...                    (10 base skills total)
    │   └── gateway/                   Telegram gateway
    │       ├── gateway.py
    │       ├── config.json
    │       ├── state/                 session files per agent
    │       └── media-inbound/         downloaded media
    │
    ├── claude-code/                   WORKSPACE: Agent 1 (example name)
    │   └── .claude/
    │       ├── CLAUDE.md              SOUL (identity, character)
    │       │   @core/USER.md
    │       │   @core/rules.md
    │       │   @core/passive/decisions.md
    │       │   @core/active/handoff.md
    │       │
    │       ├── core/
    │       │   ├── AGENTS.md          models, subagents config
    │       │   ├── USER.md            operator profile
    │       │   ├── rules.md           boundaries, permissions
    │       │   ├── passive/
    │       │   │   └── decisions.md   rolling 14 days
    │       │   ├── active/
    │       │   │   ├── recent.md      rolling 24 hours (full journal)
    │       │   │   └── handoff.md    compact extract (last 10 entries, @include)
    │       │   ├── MEMORY.md          ARCHIVE archive
    │       │   └── LEARNINGS.md       lessons from mistakes
    │       │
    │       ├── tools/
    │       │   └── TOOLS.md           servers, Docker, services
    │       │
    │       ├── skills/ → ../../shared/skills (symlink)
    │       ├── agents/                subagent .md definitions
    │       └── scripts/
    │           ├── trim-active.sh        cron: compress ACTIVE >24h
    │           ├── compress-passive.sh   cron: compress PASSIVE >10KB
    │           ├── rotate-passive.sh     cron: move PASSIVE >14d to ARCHIVE
    │           └── memory-rotate.sh   cron: archive ARCHIVE >5KB
    │
    └── jarvis/                        WORKSPACE: Agent 2 (example name)
        └── .claude/
            ├── CLAUDE.md              SOUL (different character)
            │   (same @include structure)
            ├── core/
            │   (same structure as agent 1)
            ├── tools/TOOLS.md
            ├── skills/ → ../../shared/skills (symlink)
            ├── agents/
            └── scripts/
```

## What's Isolated vs Shared

| Isolated (per agent) | Shared |
|---------------------|--------|
| CLAUDE.md (SOUL) | ~/.claude/CLAUDE.md (global) |
| rules.md (boundaries) | ~/.claude/rules/*.md |
| TOOLS.md (servers) | shared/skills/ |
| ACTIVE recent.md (journal) | shared/gateway/ |
| PASSIVE decisions.md | shared/secrets/ |
| ARCHIVE MEMORY.md | second_brain (namespaced) |
| Subagents | |
| Scripts (per-agent cron) | |
