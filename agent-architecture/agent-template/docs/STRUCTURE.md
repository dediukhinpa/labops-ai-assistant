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
    │   │   ├── memory-consolidate/    свёртка эпизодической памяти
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
    │       │   ├── rules.md           rules learned from mistakes
    │       │   ├── passive/          semantic insights (consolidated)
    │       │   │   ├── insights.md    reflection insights (YAML frontmatter)
    │       │   │   ├── decisions.md   architectural/operational decisions
    │       │   │   ├── errors.md      error patterns
    │       │   │   └── preferences.md operator preferences
    │       │   ├── active/
    │       │   │   ├── episodic.md      raw append-only diary of turns
    │       │   │   └── handoff.md    compact extract (last 10 entries, @include)
    │       │   └── archived/
    │       │       ├── episodic/YYYY-MM.md  size-rolled episodic slices
    │       │       └── superseded/    decayed insights
    │       │
    │       ├── tools/
    │       │   └── TOOLS.md           servers, Docker, services
    │       │
    │       ├── skills/ → ../../shared/skills (symlink)
    │       ├── agents/                subagent .md definitions
    │       └── scripts/
    │           ├── active-writer.sh      Stop hook: append salience-tagged episodic entry
    │           ├── reflect-nudge.sh      nudge live session to consolidate (no model in bg)
    │           ├── decay-sweep.sh        nightly bash: decay passive/ -> archived/superseded/
    │           └── archive-roll.sh       nightly bash: size-roll episodic -> archived/episodic/
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
| rules.md (learned rules) | ~/.claude/rules/*.md |
| TOOLS.md (servers) | shared/skills/ |
| ACTIVE episodic.md (journal) | shared/gateway/ |
| PASSIVE decisions.md | shared/secrets/ |
| ARCHIVE core/archived/ | second_brain (namespaced) |
| Subagents | |
| Scripts (per-agent cron) | |
