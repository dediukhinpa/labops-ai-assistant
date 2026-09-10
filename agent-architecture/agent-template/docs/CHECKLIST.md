# New Agent Checklist

> **NOTE:** `jarvis` is an example name. Replace with your own agent name.

## 1. Create Workspace

```bash
AGENT_NAME="jarvis"  # ← replace with your agent name

mkdir -p ~/.claude-lab/${AGENT_NAME}/.claude/core/{passive,active}
mkdir -p ~/.claude-lab/${AGENT_NAME}/.claude/core/archived/{episodic,superseded}
mkdir -p ~/.claude-lab/${AGENT_NAME}/.claude/tools
mkdir -p ~/.claude-lab/${AGENT_NAME}/.claude/agents
mkdir -p ~/.claude-lab/${AGENT_NAME}/.claude/scripts

# Symlink shared skills
ln -s ~/.claude-lab/shared/skills ~/.claude-lab/${AGENT_NAME}/.claude/skills

# Initialize memory files with headers
echo "# PASSIVE -- semantic insights" > ~/.claude-lab/${AGENT_NAME}/.claude/core/passive/insights.md
echo "# PASSIVE DECISIONS" > ~/.claude-lab/${AGENT_NAME}/.claude/core/passive/decisions.md
echo "# Active memory -- raw append-only episodic diary" > ~/.claude-lab/${AGENT_NAME}/.claude/core/active/episodic.md
echo "# PREFERENCES" > ~/.claude-lab/${AGENT_NAME}/.claude/core/passive/preferences.md
```

## 2. Write Identity Files

| File | What to write |
|------|--------------|
| `.claude/CLAUDE.md` | SOUL: role, character, style, @includes |
| `core/AGENTS.md` | Models, subagents config, pipelines |
| `core/USER.md` | Operator profile, preferences |
| `core/rules.md` | Rules learned from mistakes; zones live in CLAUDE.md |
| `tools/TOOLS.md` | Available servers, Docker, services |

## 3. Create Telegram Bot

1. Open @BotFather in Telegram
2. `/newbot` → choose name and username
3. Copy token to `secrets/telegram/bot-token`

## 4. Configure Gateway

Edit `~/.claude-lab/shared/gateway/config.json`:

```json
{
  "agents": {
    "jarvis": {
      "enabled": true,
      "telegram_bot_token_file": "~/.claude-lab/shared/secrets/telegram/bot-token-jarvis",
      "workspace": "~/.claude-lab/jarvis/.claude",
      "model": "opus",
      "timeout_sec": 300
    }
  }
}
```

## 5. Create Systemd Service

```bash
sudo cat > /etc/systemd/system/jarvis-gateway.service << 'EOF'
[Unit]
Description=JARVIS Telegram Gateway
After=network.target

[Service]
Type=simple
User=YOUR_USER
WorkingDirectory=/home/YOUR_USER/.claude-lab/jarvis
ExecStart=/usr/bin/python3 /home/YOUR_USER/.claude-lab/shared/gateway/gateway.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable jarvis-gateway
sudo systemctl start jarvis-gateway
```

## 6. Setup second_brain Namespace

```bash
SECOND_BRAIN_BEARER=$(cat ~/.claude-lab/shared/secrets/second_brain.key)
# second_brain auto-creates namespace on first write
# Just ensure the key file exists
```

## 7. Setup Housekeeping Cron (optional)

Consolidation is **event-driven**, not cron: reflection is nudged in-session by
checkpoint (every 20 turns) and watchdog idle (10 min) -- no model crons. The only
cron is optional nightly **pure-bash** housekeeping (no model):

```bash
0 3 * * * /path/to/scripts/decay-sweep.sh      # 03:00 -- reinforce + decay passive/ -> archived/superseded/
5 3 * * * /path/to/scripts/archive-roll.sh     # 03:05 -- size-roll episodic.md -> archived/episodic/YYYY-MM.md
```

## 8. Test

1. Send message to Telegram bot
2. Verify response arrives
3. Check `core/active/episodic.md` has the salience-tagged entry
4. Check `core/passive/preferences.md` exists (CLAUDE.md imports it)
5. Verify other agent can message via inbox
