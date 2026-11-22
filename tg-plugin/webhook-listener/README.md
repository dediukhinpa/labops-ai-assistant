# labops-plugin webhook listener

A small Python aiohttp service that accepts swarm webhooks from
[second_brain](https://github.com/qwwiwi/second_brain) and spawns a
headless agent run against the configured agent workspace: `claude -p` on a
Claude Code swarm, `codex exec` on a Codex swarm (see «Harness» below).

It is the inter-agent ingress that complements the labops-channel plugin
(Telegram ingress). The plugin handles human-driven chat sessions; this
listener handles agent-to-agent task delivery.

## Why it exists

The labops-channel plugin has no inbox-poll loop. When another agent
publishes a swarm delivery for this agent, the second_brain worker calls the
webhook below, which:

1. verifies the Bearer token
2. enriches the payload from `list_my_pending` if the swarm worker sent
   a degraded (empty) retry (the v6.3 active-patch)
3. sends a Telegram pre-ack to the owner (optional, opt-in)
4. spawns `claude -p` (or `codex exec`) in the agent workspace with a
   structured prompt that tells the agent how to pick up and complete the task

## Endpoints

| Method | Path             | Notes                                          |
| ------ | ---------------- | ---------------------------------------------- |
| POST   | `/hooks/agent`   | Bearer-auth, JSON body. Returns `accepted` or `empty_inbox`; `503 harness_unavailable` when a Codex agent's pii-proxy is down. |
| GET    | `/healthz`       | Static health probe.                           |

## Configuration

All knobs come from the environment. Defaults match a single-agent
single-host install; override anything that is host-specific.

| Env var                       | Default                                    | Required | Notes                                                                |
| ----------------------------- | ------------------------------------------ | -------- | -------------------------------------------------------------------- |
| `WEBHOOK_PORT`                | `6100`                                     | no       | TCP port to bind.                                                    |
| `WEBHOOK_BIND_HOST`           | `127.0.0.1`                                | no       | Loopback by default — flip to `0.0.0.0` only behind a TLS reverse proxy with IP allowlisting. |
| `WEBHOOK_BEARER_FILE`         | `/etc/labops-plugin/webhook.token`          | yes      | File with the shared Bearer (one line, no trailing newline).         |
| `WEBHOOK_AGENT_NAME`          | _(no default — required)_                  | yes      | Logical agent name. Embedded into the spawn prompt.                  |
| `WEBHOOK_AGENT_WORKSPACE`     | `$HOME/.claude`                            | yes      | CWD passed to `claude -p`. Must contain `CLAUDE.md`.                 |
| `CLAUDE_BIN`                  | `/usr/local/bin/claude`                    | no       | Path to the Claude Code binary.                                      |
| `CLAUDE_LAB`                  | `$HOME/.claude-lab`                        | no       | Lab root; the harness is read from `$CLAUDE_LAB/shared/swarm.env`.   |
| `CODEX_BIN`                   | `$HOME/.local/bin/codex`                   | no       | Path to the Codex CLI binary (Codex swarm only).                     |
| `WEBHOOK_CODEX_HOME`          | `<WEBHOOK_AGENT_WORKSPACE>/../.codex`      | no       | Agent's `CODEX_HOME` (Codex swarm only). Must contain `config.toml`. |
| `WEBHOOK_LOG_DIR`             | `/var/log/labops-plugin-webhook`            | no       | Where per-invocation stdout/stderr lands.                            |
| `INVOCATION_TIMEOUT_SEC`      | `1800`                                     | no       | Hard kill ceiling for a spawned run (Codex: its whole process group). |
| `WEBHOOK_SECOND_BRAIN_TOKEN_FILE`   | `$HOME/.secrets/second_brain.token`        | conditional | second_brain agent_router token. Required only if `WEBHOOK_SECOND_BRAIN_AGENT_ROUTER_URL` is set. |
| `WEBHOOK_SECOND_BRAIN_AGENT_ROUTER_URL`    | _(unset — enrichment disabled)_            | no       | JSON-RPC endpoint of **your own** agent_router MCP (see «Bring-your-own agent_router endpoint» below). Leave empty to disable the v6.3 enrichment fallback. |
| `WEBHOOK_OWNER_CHAT_ID`       | _(unset — feature off)_                    | no       | Telegram chat id that receives pre-ack pings. Empty → notification disabled. |
| `WEBHOOK_TG_BOT_TOKEN_FILE`   | `$HOME/.secrets/telegram-bot-token`        | conditional | Required only if `WEBHOOK_OWNER_CHAT_ID` is set.                  |
| `WEBHOOK_NOTIFY_TTL_SEC`      | `300`                                      | no       | Dedup window for repeated owner pings on the same task.              |

## Harness

The whole swarm runs on one harness, chosen by the installer and stored as
`HARNESS=claude|codex` in `$CLAUDE_LAB/shared/swarm.env`. The listener reads it
**once at startup** (the file is parsed, never sourced): no file or no line means
`claude`, an unknown value stops the listener. Restart the listener after the
harness changes.

- **claude**: `claude -p <prompt> --dangerously-skip-permissions`, as before.
- **codex**: `codex exec --skip-git-repo-check <prompt>` with stdin closed (an
  open stdin makes `codex exec` wait for input), `cwd` = `WEBHOOK_AGENT_WORKSPACE`
  (`<lab>/<agent>/.claude`), `CODEX_HOME` = `<lab>/<agent>/.codex`
  (override: `WEBHOOK_CODEX_HOME`). No approval/sandbox flags are passed: the agent's
  `config.toml` already sets `approval_policy = "never"` and
  `sandbox_mode = "danger-full-access"`, plus the model, the pii-proxy provider and
  the second-brain MCP servers. The listener refuses to start on a Codex swarm if
  that `config.toml` is missing — Codex would otherwise talk to the model directly,
  bypassing the pii-proxy.
- **codex environment**: the baseline allowlist (`HOME`, `PATH`, `USER`, `LANG`,
  `LC_*`, `TERM`, `TZ`), `CODEX_HOME`, and `AGENT_BEARER` read from
  `$WEBHOOK_AGENT_WORKSPACE/agent.env` (the second-brain MCP servers in `config.toml`
  use it via `bearer_token_env_var`; the `CHANGE_ME` placeholder is not passed). No
  other secret, no `CLAUDE_*` / `ANTHROPIC_*` variables.
- **pii-proxy check (codex)**: `codex exec` does not fail when its model provider is
  unreachable — it keeps reconnecting until the timeout. So before every run the
  listener takes `base_url` of the agent's `model_provider` from `config.toml`
  (local `http://127.0.0.1|localhost:<port>` only) and calls `GET /health` (3 s).
  If the proxy does not answer, the task is not started, a warning is logged and
  the webhook answers `503`: the delivery worker does not mark the task acked and
  retries it later, so it stays pending in second-brain. No proxy in `config.toml`
  means no check.
- **timeout (codex)**: `codex exec` runs in its own process group; on
  `INVOCATION_TIMEOUT_SEC` the whole group (commands, MCP servers) is killed.

## Install

This repo ships the listener as source. A typical install on Linux:

```bash
sudo mkdir -p /opt/labops-plugin-webhook /etc/labops-plugin /var/log/labops-plugin-webhook
sudo cp webhook-listener/listener.py /opt/labops-plugin-webhook/

# Write the Bearer token without leaking it into shell history:
sudo install -m 0600 -o root -g root /dev/null /etc/labops-plugin/webhook.token
sudoedit /etc/labops-plugin/webhook.token   # paste the secret, save, exit

python3 -m venv /opt/labops-plugin-webhook/.venv
/opt/labops-plugin-webhook/.venv/bin/pip install -r webhook-listener/requirements.txt

sudo cp examples/webhook-listener.service.example \
  /etc/systemd/system/labops-plugin-webhook.service
# edit /etc/systemd/system/labops-plugin-webhook.service to set User= and EnvironmentFile=
sudo cp examples/webhook-listener.env.example /etc/labops-plugin/webhook.env
# edit /etc/labops-plugin/webhook.env to point to your workspace + tokens
sudo systemctl daemon-reload
sudo systemctl enable --now labops-plugin-webhook
```

## Bring-your-own agent_router endpoint

The v6.3 enrichment fallback expects `WEBHOOK_SECOND_BRAIN_AGENT_ROUTER_URL` to point at
**your own** [second_brain](https://github.com/qwwiwi/second_brain) instance.
This repo intentionally ships no default — you stand up your own agent_router
coordinator and expose it over HTTPS. Two common patterns:

1. **Cloudflare Tunnel** (no public IP, no inbound firewall rule):
   - Run second_brain on your own host (LAN, Tailscale, anywhere reachable from
     itself). Bind the MCP servers to `127.0.0.1:<port>`.
   - Install `cloudflared`, run `cloudflared tunnel login`, then
     `cloudflared tunnel create <name>`.
   - Add an `ingress` mapping `mcp.<your-domain>` → `http://127.0.0.1:<port>`
     in `~/.cloudflared/config.yml` and route the tunnel:
     `cloudflared tunnel route dns <name> mcp.<your-domain>`.
   - Start the tunnel via systemd unit (`cloudflared service install`).
   - Set `WEBHOOK_SECOND_BRAIN_AGENT_ROUTER_URL=https://mcp.<your-domain>/agent_router/mcp`.

2. **Tailscale + caddy/nginx**: terminate TLS on a host inside the tailnet
   and reach it via the MagicDNS name. Same env shape — point
   `WEBHOOK_SECOND_BRAIN_AGENT_ROUTER_URL` at your tailnet hostname.

Either way: the URL you set in `WEBHOOK_SECOND_BRAIN_AGENT_ROUTER_URL` is yours, never
a third-party endpoint. The listener also redacts Bearer tokens from log
records so the token does not surface in journal output.

## PII proxy

On a Codex swarm the proxy is configured in the agent's `config.toml` and checked
before each run (see «Harness»). The rest of this section is about Claude Code.

`claude -p` runs with `cwd` set to the agent workspace, so it does not read the agent's own
`settings.json`. The listener therefore copies `ANTHROPIC_BASE_URL` (the agent's local
`pii-proxy`) and the telemetry-off flags from the `env` block of
`$WEBHOOK_AGENT_WORKSPACE/settings.json` into the child environment; a value already present in
the listener's own environment wins. Without this, background tasks bypass the masking proxy.
Redeploy the listener to apply it to an already installed agent.

## Security

- The listener fails to start if the Bearer file is missing — no silent
  open mode.
- All log records pass through a redacting formatter that masks Bearer
  tokens, `sk-...` strings, and `password=...` query fragments. If you
  add new secret-bearing log lines, extend `_TOXIC` accordingly.
- Default bind is `127.0.0.1`. For network-facing deploys, terminate
  TLS upstream and allowlist the second_brain swarm worker; the bare process
  trusts only the Bearer header for AuthZ.
- `_notify_owner` `parse_mode=HTML` interpolation goes through
  `html.escape`, so a hostile `from_agent` / `task_id` / `title` cannot
  break the Telegram message or inject markup.
- `--dangerously-skip-permissions` is passed to `claude -p` (Codex: `approval_policy
  = "never"` + `danger-full-access` from the agent's `config.toml`). The
  spawned agent runs with full permissions inside the configured
  workspace. Keep `WEBHOOK_AGENT_WORKSPACE` confined to a directory
  whose contents you trust.
- The subprocess environment is allowlisted (`HOME`, `PATH`, `USER`,
  `LANG`, `LC_*`, `TERM`, `TZ`, plus `CLAUDE_*` / `ANTHROPIC_*`
  prefixes; Codex gets the baseline plus `CODEX_HOME` and `AGENT_BEARER` only).
  `WEBHOOK_*` listener-config vars and any local secret-file paths set in the
  service environment do not propagate to the spawned agent.
- `task_id` is sanitized (`[A-Za-z0-9_.:-]{,64}`) before reaching the
  spawn prompt and the per-invocation log filename, so a payload field
  cannot path-traverse the log directory or break prompt structure.
- The `/healthz` endpoint returns a constant `{"status": "ok"}`; it does
  not echo any server-side configuration even if reachable from the
  network.
