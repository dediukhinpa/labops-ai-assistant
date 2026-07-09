# Hooks -- agent-template

Bash hooks wired into Claude Code via `templates/settings.json.template`. They
run inside the `~/.claude-lab/<agent-id>/.claude/` workspace produced by
`install.sh`.

All hooks are **non-blocking**: any failure logs to `logs/hooks.log` and exits 0
so the harness is never stalled.

## Hooks

| File | Hook event | Purpose |
|---|---|---|
| `session-start-hook.sh` | `SessionStart` | Log session start; rebuild `core/active/working-set.md` via `scripts/working-set-build.sh` -- fuses shared second_brain recall (if creds present) with local `passive/` lexical recall. Never edits `episodic.md`. |
| `user-prompt-submit-hook.sh` | `UserPromptSubmit` | Proactive recall: a pure-bash worthiness gate drops acknowledgements ("ok"/"спасибо"); for substantive prompts it rebuilds `core/active/working-set.md` keyed on the prompt, in the background (working-set-build self-caps with a hard timeout). |
| `stop-hook.sh` | `Stop` (end of each turn) | Append a salience-tagged episodic entry to `core/active/episodic.md` (via `scripts/active-writer.sh`) + a verbose JSON line to `logs/verbose-YYYY-MM-DD.jsonl`; increment the turn counter and, every `MEMORY_CHECKPOINT_EVERY_N_TURNS` (default 20), fire `scripts/reflect-nudge.sh --reason checkpoint`. |
| `precompact-hook.sh` | `PreCompact` | Snapshot `core/active/episodic.md` to `core/active/pre-compact/recent-<ts>.md`; keep newest `KEEP_SNAPSHOTS` (default 10). |

## Environment

Hooks read these env vars (all optional):

| Var | Used by | Default |
|---|---|---|
| `AGENT_WORKSPACE` | all | derived from script path (`hooks/..`) |
| `AGENT_ID` | all | derived from workspace parent dir |
| `MCP_HOST` | session-start / user-prompt-submit | host/IP only (no protocol/port); used to derive `SECOND_BRAIN_*_URL` defaults; unset -> shared recall skipped, local `passive/` recall still runs |
| `SECOND_BRAIN_MEMORY_ROUTER_URL` | working-set-build | full URL to memory_router `/mcp` (default `http://${MCP_HOST}:5002/mcp`); unset -> shared half skipped |
| `AGENT_BEARER` | working-set-build / reflect-nudge | unset -> shared half skipped (file-only recall) |
| `RECALL_LIMIT` | working-set-build | 5 |
| `RECALL_TIMEOUT_MS` | working-set-build | 1000 (hard timeout; skip-on-timeout, non-blocking) |
| `RECALL_MIN_OVERLAP` | working-set-build | 2 (local lexical-fallback keyword overlap) |
| `MEMORY_CHECKPOINT_EVERY_N_TURNS` | stop | 20 (turns between checkpoint reflect-nudges) |
| `KEEP_SNAPSHOTS` | precompact | 10 |

`install.sh` writes `MCP_HOST`, the three `SECOND_BRAIN_*_URL` vars, and
`AGENT_BEARER` to a per-agent `agent.env` file that you `source` before
launching Claude Code, or you can export them in your shell profile.
`MCP_HOST` is the host/IP only (no protocol or port); the `SECOND_BRAIN_*_URL`
vars are the actual per-service endpoint URLs (memory `:5001`, memory_router
`:5002`, agent_router `:5000` by default) and can be overridden directly for
remote deployments fronted by your own reverse proxy.

## Wiring

`install.sh` copies `templates/settings.json.template` to
`~/.claude-lab/<agent-id>/.claude/settings.json` and renders the `{{AGENT_ID}}`
placeholder. Claude Code picks up that settings file automatically when launched
from inside the workspace.

## Logs

- `logs/hooks.log` -- one line per hook invocation
- `logs/verbose-YYYY-MM-DD.jsonl` -- one JSON object per turn (Stop hook)

`core/active/pre-compact/` holds the rotating PreCompact snapshots.
