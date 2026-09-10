# Skills bundle

A small bundle of Claude Code skills that pair well with this second_brain distro.
Most are independent — you can install one, several, or none of them.

## How to install

Pick one of these per skill:

```sh
# 1. Symlink (recommended — survives skill updates via git pull on this repo):
ln -s "$PWD/skills/<name>" ~/.claude/skills/<name>

# 2. Or per-agent:
ln -s "$PWD/skills/<name>" ~/.claude-lab/<your-agent>/.claude/skills/<name>

# 3. Or copy:
cp -R skills/<name> ~/.claude/skills/<name>
```

After install, Claude Code picks up the skill on the next session and routes to
it when the description matches.

## Skills in this bundle

| Skill | What it does | Needs |
|---|---|---|
| `create-agent` | Roll out a new agent end to end: identity, Telegram bot, voice, autostart, smoke test. | this repo |
| `memory-consolidate` | Distil raw episodic memory into durable insights on a reflection nudge. | the agent memory layout |
| `second_brain-doctor` | Diagnose the agent's second_brain setup end to end; output is redacted. | second_brain |
| `groq-voice` | Transcribe voice messages (`.ogg`) via Groq Whisper. | `GROQ_API_KEY` |
| `markdown-new` | Clean Markdown extraction from any URL via the external `markdown.new` service (the URL is sent to a third party). | none |
| `mcp-builder` | Anthropic-authored guide to building new MCP servers from scratch. | none |
| `agent-browser` | Browser automation CLI (Chrome/Chromium via CDP). Navigate, click, fill forms, screenshot. | `agent-browser` binary + Chrome, not installed by `install.sh` |

## Skill independence

`groq-voice`, `markdown-new`, `mcp-builder` and `agent-browser` do not depend on each other
or on second_brain and run in a vanilla Claude Code workspace. `create-agent`,
`memory-consolidate` and `second_brain-doctor` are part of this distro and expect its
workspace layout.
