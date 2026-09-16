# Your First Agent

A worked example: a **code reviewer** agent you talk to in Telegram. It gets its own
workspace, SOUL, bot and memory, and shares the second_brain with the rest of the
swarm.

> **Prerequisites:** the first agent (Developer) is installed by
> `agent-architecture/install.sh`, and second_brain is running. See
> [SETUP-GUIDE.md](SETUP-GUIDE.md).

## Step 1: Create the agent

Ask Developer in Telegram: *"Create a new agent: code reviewer"*. It runs the
`create-agent` skill and asks you one thing at a time. Or run the script yourself:

```bash
AGENT_NAME="Reviewer" \
AGENT_ROLE="Code reviewer" \
AGENT_ROLE_DESCRIPTION="Senior code reviewer: finds bugs, security issues and architectural problems." \
PRIMARY_MODEL="sonnet" \
TELEGRAM_BOT_TOKEN="<token from @BotFather>" \
TELEGRAM_ALLOWED_USER_IDS="<your Telegram id>" \
bash ~/labops-ai-assistant/agent-architecture/skills/create-agent/new-agent.sh
```

The script creates `~/.claude-lab/reviewer/.claude/`, issues a second_brain token,
connects the bot, and starts `claude-agent-reviewer.service`. Checklist of what it
does: [CHECKLIST.md](CHECKLIST.md).

## Step 2: Tune the SOUL (`CLAUDE.md`)

The template already has the parts every agent needs -- the channel rule (answer
only through `reply`), the shared-brain duties and the `@import` list. Edit only the
top of the file:

```markdown
# Reviewer -- Code reviewer

## SOUL

**Role:** Senior code reviewer. Finds bugs, security issues and architectural problems.

**Character:** Thorough, direct, constructive. Points out issues AND suggests fixes.

**Style:**
- Start with a summary: "3 issues found: 1 critical, 2 minor"
- Show the problem, then the fix
- Code examples over explanations

**Green zone (on my own):**
- Reading code, running tests and linters, writing review comments

**Red zone (ask the operator first)** -- on top of the shared red zone in `~/.claude/CLAUDE.md`:
- Changing code (review only)
- Commits and pushes
```

Keep the `## Talking to the operator`, `## Shared brain` and `## Memory Layers`
sections as they are.

## Step 3: Fill in `core/USER.md`

The installer leaves most of it as `TODO`. It describes **who you are**, not how the
work should be done:

```markdown
**Name:** Alex
**Address as:** Alex
**Timezone:** UTC+3
**Language:** Russian

## Profile
Backend developer, Python and Go.

## What operator needs from this agent
- Honest reviews, no sugar-coating
- Security first
```

## Step 4: Leave `core/rules.md` empty

It is for rules the agent earns from its own mistakes. Your review checklist and
format belong in `CLAUDE.md` (the SOUL). Your taste -- "severity labels in capitals",
"line numbers always" -- will land in `core/passive/preferences.md` by itself once you
correct the agent a couple of times.

## Step 5: Optional -- `core/AGENTS.md` and `tools/TOOLS.md`

Fill in the team table and the servers the reviewer may touch. Both are read on
demand, so they cost no context until needed.

## Step 6: Test it

1. Send the bot: "Review this code: [paste code]"
2. Expect 👀, "typing…", then the review
3. `core/active/episodic.md` has a new `[stop-hook]` entry
4. After ~20 turns the agent consolidates: new entries appear in `core/passive/`

## What You Built

```
~/.claude-lab/reviewer/.claude/
├── CLAUDE.md                 ← SOUL (+ @imports)
├── core/
│   ├── USER.md               ← who you are
│   ├── rules.md              ← empty until the agent earns rules
│   ├── AGENTS.md             ← models, team
│   ├── passive/              ← decisions, preferences, errors, insights (auto)
│   ├── active/               ← diary + handoff (auto)
│   └── archived/             ← old diary, decayed entries (auto)
├── tools/TOOLS.md            ← infrastructure map
├── hooks/, scripts/          ← memory engine (no cron, no background model)
├── skills → shared skills    ← symlink
├── labops-tg-plugin/plugin/  ← Telegram channel
└── settings.json, .mcp.json, agent.env
```

## What's Next

1. **Hand it work from other agents** -- task board, see `AGENT_ROUTER.md` and [MULTI-AGENT.md](MULTI-AGENT.md)
2. **Learn how memory flows** -- [MEMORY.md](MEMORY.md)
3. **Create custom skills** -- [SKILLS.md](SKILLS.md)

## Agent Ideas

| Agent | SOUL Focus | Model |
|-------|-----------|-------|
| **Code Reviewer** | Security, quality, architecture | sonnet |
| **Coder** | Write code, tests, deploy | opus |
| **Researcher** | Web search, summarize, organize | sonnet |
| **Writer** | Content, posts, documentation | sonnet |
| **DevOps** | Servers, deploy, monitoring | opus |

Each agent = its own workspace + its own SOUL + its own Telegram bot.
