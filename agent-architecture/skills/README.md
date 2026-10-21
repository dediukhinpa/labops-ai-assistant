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
| `agent-browser` | Browser automation CLI (Chrome/Chromium via CDP). Navigate, click, fill forms, screenshot. | `agent-browser` binary + Chrome, not installed by `install.sh` |

| `deep-research` | Cited, cross-checked research report with stated confidence and gaps. | web search; perplexity-research skill optional |
| `report-generator` | Formatted report from numbers, tables and metrics. | - |
| `meeting-summarizer` | Minutes, tasks, owners and deadlines from a meeting transcript. | - |
| `customer-research` | Interviews, surveys, reviews into personas and JTBD. | - |
| `competitor-profiling` | Competitor profiles and a landscape summary from their URLs. | - |
| `social` | Social posts, short-video scripts, social listening. | - |
| `web-design-guidelines` | UI and accessibility review against web interface guidelines. | - |
| `supergoal` | Build a task autonomously from plan to result. | - |
| `skill-finder` | Vet a skill from a registry before adopting it. | - |
| `cross-review` | Cross-review of PRs between agents, change levels. | gh CLI |

More skills (docx, pptx, pdf, xlsx, research, MCP, process skills) are not stored here: see
`external-skills.manifest`, installed by `install.sh` and `sync-skills.sh` at pinned commits.
Provenance and licenses: `THIRD_PARTY.md`.

## Skill independence

`groq-voice` and `agent-browser` do not depend on each other
or on second_brain and run in a vanilla Claude Code workspace. `create-agent`,
`memory-consolidate` and `second_brain-doctor` are part of this distro and expect its
workspace layout.
