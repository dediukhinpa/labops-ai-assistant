# New Agent Checklist

A new agent is created by `skills/create-agent/new-agent.sh` -- usually by asking the
Developer agent "create a new agent" (it runs the `create-agent` skill), or directly:

```bash
bash ~/labops-ai-assistant/agent-architecture/skills/create-agent/new-agent.sh
```

Do not build a workspace by hand: the script wires pieces that are easy to miss
(private plugin copy, webhook port, config.json, scopes, systemd unit).

## 1. Before you start

- [ ] second_brain is installed and its four services answer (memory 5001,
      memory_router 5002, agent_router 5000, tasks 5003)
- [ ] A Telegram bot from @BotFather: `/newbot`, copy the token
- [ ] Your Telegram user id (the bot answers only the ids you allow)
- [ ] Optional: a Groq API key for voice (console.groq.com/keys)

## 2. What the script does (steps it prints)

| Step | Result |
|------|--------|
| 0. Dependencies | checks `claude`, `bun`, `curl`, `jq`, `tmux` |
| 1. Configuration | name, role, description, model (alias, default `sonnet`), language, form of address |
| 2. Shared-brain token | issues a Bearer with `decisions,external,knowledge,inbox,error-patterns,task-board,personal,projects,daily` |
| 3. Workspace | runs `agent-template/install.sh` non-interactively: see [FILES-REFERENCE.md](FILES-REFERENCE.md) |
| 4. Telegram channel | `channel.env`, webhook token, `config.json`, private plugin copy |
| 5. Voice | stores the Groq key in `~/.claude-lab/shared/secrets/groq-api-key` |
| 6. Autostart | `claude-agent-<agent>.service` (systemd → watchdog → tmux + claude) |
| 7. Smoke test | memory_router answers, Telegram `getMe` passes |

Anything that could not be finished is listed at the end as "degraded", with the
command to fix it.

## 3. Fill in by hand afterwards

The installer leaves these as `TODO: fill in`:

- [ ] `core/USER.md` -- your name, profile, communication style, what you need from this agent
- [ ] `core/AGENTS.md` -- the team table
- [ ] `tools/TOOLS.md` -- servers and services this agent works with
- [ ] `CLAUDE.md` -- the extra red-zone line, if the role needs one

Leave `core/rules.md` empty: rules are added later, from the agent's own mistakes.

## 4. Verify

- [ ] `systemctl is-active claude-agent-<agent>` → `active`
- [ ] Message the bot → 👀 reaction, "typing…", then an answer
- [ ] `core/active/episodic.md` got a new `### … [stop-hook] {…}` entry
- [ ] `state/heartbeat` is fresh
- [ ] `python3 ~/labops-ai-assistant/agent-architecture/skills/second_brain-doctor/scripts/second_brain_doctor.py --agent <agent>` is green
- [ ] Another agent can hand it a task through the board (see `AGENT_ROUTER.md`)

No cron is needed: consolidation is nudged in-session and housekeeping runs from the
Stop hook once a day.
