# Hooks -- agent-template

Bash hooks wired into Claude Code via `templates/settings.json.template`. They
run inside the `~/.claude-lab/<agent-id>/.claude/` workspace produced by
`install.sh`.

All hooks are **non-blocking**: any failure logs to `logs/hooks.log` and exits 0
so the harness is never stalled.

## Hooks

| File | Hook event | Purpose |
|---|---|---|
| `session-start-hook.sh` | `SessionStart` | Log session start; optionally call `scripts/second_brain-memory_router-on-start.sh` to pull top-N relevant items from shared second_brain into `core/hot/recent.md`. |
| `stop-hook.sh` | `Stop` (end of each turn) | Append a 200-char snippet to `core/hot/recent.md`; append a verbose JSON line to `logs/verbose-YYYY-MM-DD.jsonl` (full payload, for replay). |
| `precompact-hook.sh` | `PreCompact` | Snapshot `core/hot/recent.md` to `core/hot/pre-compact/recent-<ts>.md`; keep newest `KEEP_SNAPSHOTS` (default 10). |

## Environment

Hooks read these env vars (all optional):

| Var | Used by | Default |
|---|---|---|
| `AGENT_WORKSPACE` | all | derived from script path (`hooks/..`) |
| `AGENT_ID` | all | derived from workspace parent dir |
| `MCP_HOST` | session-start | host/IP only (no protocol/port); used to derive `SECOND_BRAIN_*_URL` defaults; unset -> skip recall |
| `SECOND_BRAIN_MEMORY_ROUTER_URL` | session-start | full URL to memory_router `/mcp` (default `http://${MCP_HOST}:5002/mcp`); unset -> skip recall |
| `AGENT_BEARER` | session-start | unset -> skip recall |
| `RECALL_LIMIT` | session-start (-> recall script) | 5 |
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

`core/hot/pre-compact/` holds the rotating PreCompact snapshots.
