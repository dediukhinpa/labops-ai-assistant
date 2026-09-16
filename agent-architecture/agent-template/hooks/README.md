# Hooks -- agent-template

Bash hooks wired into Claude Code via `templates/settings.json.template`. They
run inside the `~/.claude-lab/<agent-id>/.claude/` workspace produced by
`install.sh`.

All hooks are **non-blocking**: any failure logs to `logs/hooks.log` and exits 0
so the harness is never stalled.

## Hooks

| File | Hook event | Purpose |
|---|---|---|
| `session-start-hook.sh` | `SessionStart` | Log session start (and whether `core/active/handoff.md` has content). Never edits `episodic.md`. |
| `stop-hook.sh` | `Stop` (end of each turn) | Append a salience-tagged episodic entry to `core/active/episodic.md` (via `scripts/active-writer.sh`) + a verbose JSON line to `logs/verbose-YYYY-MM-DD.jsonl`; increment the turn counter and, every `MEMORY_CHECKPOINT_EVERY_N_TURNS` (default 20), fire `scripts/reflect-nudge.sh --reason checkpoint`; once a day run `decay-sweep.sh` + `archive-roll.sh`. |
| `precompact-hook.sh` | `PreCompact` | Snapshot `core/active/episodic.md` to `core/active/pre-compact/recent-<ts>.md`; keep newest `KEEP_SNAPSHOTS` (default 10); then `scripts/brain-flush.sh --reason precompact`. |
| `heartbeat-hook.sh` | SessionStart, UserPromptSubmit, Pre/PostToolUse, Notification, Stop | Touch `state/heartbeat` -- the watchdog reads it as the liveness signal. |

`SessionEnd` runs `scripts/brain-flush.sh --reason session-end` directly (no wrapper hook).

Recall under a task is not a hook: `CLAUDE.md` tells the agent to query the shared
brain itself before non-trivial work, keyed on the real task.

## Environment

Hooks read these env vars (all optional):

| Var | Used by | Default |
|---|---|---|
| `AGENT_WORKSPACE` | all | derived from script path (`hooks/..`) |
| `AGENT_ID` | all | derived from workspace parent dir |
| `AGENT_BEARER` | reflect-nudge | unset -> read from the agent's `.mcp.json`; no token anywhere -> falls back to a `consolidate.request` marker file |
| `MEMORY_CHECKPOINT_EVERY_N_TURNS` | stop | 20 (turns between checkpoint reflect-nudges) |
| `MEMORY_HOUSEKEEPING_INTERVAL_SEC` | stop | 86400 (how often decay-sweep + archive-roll run) |
| `KEEP_SNAPSHOTS` | precompact | 10 |

`install.sh` writes `MCP_HOST`, the four `SECOND_BRAIN_*_URL` vars,
`AGENT_BEARER` and `AGENT_SCOPES` to a per-agent `agent.env` file that the launcher
sources before starting Claude Code.
`MCP_HOST` is the host/IP only (no protocol or port); the `SECOND_BRAIN_*_URL`
vars are the actual per-service endpoint URLs (memory `:5001`, memory_router
`:5002`, agent_router `:5000`, tasks `:5003` by default) and can be overridden directly for
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
