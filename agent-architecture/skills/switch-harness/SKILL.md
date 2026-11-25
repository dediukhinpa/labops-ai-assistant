---
name: switch-harness
description: Use when the operator wants to switch the WHOLE swarm from one agent runtime (harness) to the other — Claude Code (claude, Claude subscription) ⇄ Codex CLI (codex, ChatGPT subscription) — in one command, keeping every agent's settings, memory and identity, and changing the subscription accordingly. Covers both directions and the dry-run.
---

# Switching the swarm between harnesses (claude ⇄ codex)

The harness is one per whole swarm, stored in `~/.claude-lab/shared/swarm.env` (`HARNESS=claude|codex`). The installer refuses to change it for an existing swarm — switching is this separate, scripted procedure. One command does everything (backup, runtime install, login, pii-proxy, stop, convert, flip, restart, auto-rollback on failure): `orchestration/switch-harness.sh`.

Full design and guarantees: `docs/switch-harness.md`.

## How to run it

Run **as the agents user** (whose lab and `swarm.env` these are), **never as root**.

1. **Always dry-run first** — shows the plan, changes nothing:
   ```bash
   bash orchestration/switch-harness.sh codex --dry-run
   ```
2. Then the real switch to the target harness:
   ```bash
   bash orchestration/switch-harness.sh codex     # move the swarm to Codex (ChatGPT)
   bash orchestration/switch-harness.sh claude     # move the swarm to Claude Code
   ```

Useful variables: `PRIMARY_MODEL=<model>` (default is the target harness's own default), `SKIP_LOGIN=1` (subscription already signed in), `SKIP_RUNTIME_INSTALL=1` (target binary already present), `SKIP_PII_PROXY=1` (codex pii-proxy already set up).

## What to tell the operator before running

- **Settings, memory and identity are preserved.** Each agent's `core/` memory, `channel.env`, `agent.env`/bearer stay as-is; only the runtime-specific files (model/MCP config, global rules) and the identity's channel section are regenerated for the target harness.
- **The subscription changes** with the harness: claude → Claude models, codex → ChatGPT/gpt.
- **Conversation history does NOT carry over.** Each agent starts a fresh session on the new harness and recalls its memory through `core/`. There is no dialogue-history migration.
- **Login may be interactive** and is baked into the command: it prompts once (codex device-auth link+code, claude `/login` in a tmux window) unless already signed in. Because of this, run the command yourself in a real terminal — it is **not** something an agent should launch from inside its own Telegram session (that would kill the very session running it and can block on login). The Telegram `/harness` command therefore only reports the current harness and points here.
- On any failure after the point of no return, the command **rolls back automatically** from the backup it took first.

## Doing it for the operator

When asked to perform the switch: confirm the target harness, run the dry-run, show its plan, then run the real command and report the outcome (new harness, model, backup path). If login is required, relay the device-auth link/code or the `tmux attach` instruction the command prints, and wait for the operator to finish it.
