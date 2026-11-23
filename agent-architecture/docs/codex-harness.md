# Running the swarm on Codex (ChatGPT subscription)

[Русская версия](codex-harness.ru.md)

The **harness** is the program the agents live in. LabOps supports two:

| Harness | What the agent runs on | Paid from |
|---|---|---|
| `claude` (default) | Claude Code | your Claude subscription (Max/Pro) |
| `codex` | Codex CLI | your ChatGPT subscription |

Everything else stays the same: the workspace and its memory, the shared second-brain,
the Telegram bot, the watchdog under systemd, the task board, PII masking.

This page explains, in plain words, what changes when you pick `codex`.

---

## 1. One harness for the whole swarm

- The harness is the **first question of the installer**:
  `Harness for the swarm (claude / codex) [claude]`.
  To answer it without a prompt, set `HARNESS=claude` or `HARNESS=codex`
  (`HARNESS=codex bash install.sh`). With `NONINTERACTIVE=1` and no `HARNESS`, the answer is
  `claude`.
- The choice is written to `~/.claude-lab/shared/swarm.env` (`HARNESS=codex`, mode `600`). Every
  script reads it from there. No file, or no `HARNESS` line, means `claude` — swarms installed
  before this option keep working without migration.
- **All agents use the same harness.** A mixed swarm is not supported. New agents
  (`create-agent` / `new-agent.sh`) inherit the harness and never ask about it.
- **You cannot switch the harness of an existing swarm with the installer.** If agents already
  exist and you re-run `install.sh` with the other harness, it stops with an explanation.

## 2. What the installer does on `codex`

1. **Checks the network**: `github.com` (the Codex package), `chatgpt.com` (where the agent's
   model traffic goes) and `auth.openai.com` (sign-in) must be reachable.
2. **Installs Codex CLI, pinned to version `0.171.0`.** It downloads the official release
   package from `github.com/openai/codex/releases`, checks its sha256 and unpacks it into
   `~/.local/share/labops-codex/0.171.0/` of the agents' user, with a link
   `~/.local/bin/codex`. Node.js is not needed. Nothing is put into `/usr/local/bin`.
   Older versions are kept, because running agents may still use them.
   The version is pinned because the Telegram driver relies on the `codex app-server`
   protocol of exactly this version; a newer Codex is adopted only together with a driver
   check and new checksums. Supported: Linux x86_64 and aarch64.
3. **Sets up PII masking — mandatory on Codex.** On a Codex swarm `SKIP_PII_PROXY=1` is
   refused, and if the masking service cannot be installed the installer stops. See section 5.
4. **Signs the swarm in to ChatGPT** (section 3).
5. **Asks for the model.** The default for Codex agents is **`gpt-6.2-sol`**. The model is
   written to the agent's `config.toml` (`model = ...`). Model settings belong to the
   operator — do not change them without the owner.
6. Installs the Telegram channel (`tg-plugin`) **without** Claude Code and without Claude Code
   hooks — they are not needed on Codex.
7. Creates the first agent (Developer), as on Claude.

`bash install.sh --no-agent` prepares the machine — including the host PII-masking service and the
shared sign-in directory `~/.claude-lab/shared/codex` (mode 700) — and prints the sign-in command and
the `new-agent.sh` command instead of creating the agent. Re-running the installer as root (including
with `NONINTERACTIVE=1`) finds the harness already chosen in the agent user's swarm (`AGENT_OS_USER`
names that user explicitly) and does not replace it with the `claude` default.

## 3. Signing in: one ChatGPT login for the whole swarm

All agents share **one** sign-in. It lives in a shared folder:

```bash
CODEX_HOME=~/.claude-lab/shared/codex codex login --device-auth
```

The installer runs this for you (press Enter at the prompt). Codex prints a link and a code.
Open the link on any device (phone or laptop — no browser is needed on the server), sign in to
the ChatGPT account whose subscription the swarm should use, and enter the code.

- To sign in later, type `s` at the prompt or run the installer with `SKIP_CODEX_LOGIN=1`. The
  agent is still created but will not answer until you run the command above. You do not need
  to restart anything afterwards: the watchdog notices the sign-in and brings the agent up.
- Only a **ChatGPT subscription** sign-in is accepted. A Codex signed in with an OpenAI API key
  is treated as "not signed in" (that would be billed outside the subscription).
- Each agent has its own `CODEX_HOME` = `~/.claude-lab/<agent>/.codex/`. In it, `auth.json`,
  `auth.json.lock` and `auth.lock` are **links** to the shared folder. When any agent refreshes
  the token, the new token is written through the link, so every other agent sees it; the shared
  lock files stop two agents from refreshing at the same time. Separate copies would break each
  other on every refresh — that is why the sign-in is shared.
- If an agent already had its own `auth.json`, it is moved into the shared folder (when the
  shared one does not exist yet) or set aside as `auth.json.bak-<time>`.

Check the sign-in at any time:

```bash
CODEX_HOME=~/.claude-lab/shared/codex ~/.local/bin/codex login status   # "Logged in using ChatGPT"
```

## 4. Agent files on Codex

| Path | What it is |
|---|---|
| `~/.claude-lab/<agent>/.claude/` | the agent's workspace, same as on Claude: memory, hooks, scripts, secrets, the channel plugin |
| `~/.claude-lab/<agent>/.claude/AGENTS.md` | the agent's identity for Codex. Built from `AGENTS.src.md` (the same texts as `CLAUDE.md`, with a Codex version of the channel section). Codex cannot `@import` files, so the driver rebuilds `AGENTS.md` before every new thread — memory in it is always fresh. Edit the source and memory files, not `AGENTS.md` |
| `~/.claude-lab/<agent>/.codex/` | `CODEX_HOME` of the agent (mode `700`): `config.toml`, global rules `AGENTS.md`, `rules/`, Codex threads, links to the shared sign-in |
| `~/.claude-lab/shared/codex/` | the shared ChatGPT sign-in of the swarm (mode `700`) |
| `~/.claude-lab/shared/swarm.env` | `HARNESS=codex` |

`config.toml` (mode `600`) holds:

- `model` — the model (default `gpt-6.2-sol`);
- `model_provider = "labops-pii"` — **all model requests go through the agent's local
  pii-proxy** (`http://127.0.0.1:<port>/backend-api/codex`), signed in via ChatGPT;
- `approval_policy = "never"` and `sandbox_mode = "danger-full-access"` — the Codex equivalent
  of `--dangerously-skip-permissions` (see [SECURITY.md](../SECURITY.md));
- request compression turned off — the proxy must be able to read the request to mask it;
- the second-brain MCP servers. Their Bearer is read from the `AGENT_BEARER` environment
  variable (from the agent's `agent.env`); the token itself is not written into this file.

## 5. PII masking is mandatory at install time

On Claude the pii-proxy is on by default but can be turned off. On Codex it cannot:

- the installer and `new-agent.sh` refuse `SKIP_PII_PROXY=1`;
- the agent's proxy is set up **before** its workspace is rendered, because the proxy address
  goes into `config.toml`; if the proxy cannot be set up, the agent is not created;
- `config.toml` has no route to the model other than the proxy.

### When the proxy is down: the agent works directly (owner decision, 23.11.2026)

If the agent's pii-proxy stops answering, the agent **keeps working without it** instead of
going silent. While that lasts, **personal data goes to the model unmasked** — the owner accepts
this risk. How it works:

- the watchdog checks the proxy's `/health` every ~30 s. Three failures in a row switch the
  agent to *direct* mode, two successes in a row switch it back (one slow answer changes
  nothing). It also tries to start the proxy unit itself;
- switching to direct does not wait for the turn: the driver interrupts it (`turn/interrupt`;
  on a dead proxy it would fail anyway), restarts `codex app-server`, continues the **same
  thread** (`thread/resume`), so the conversation is kept, and repeats the same turn input. A
  turn that finished on its own before the interrupt is not repeated; a turn that already
  failed on the dead proxy is repeated without an error message to the user. Switching back
  through the proxy happens only between turns. In direct mode only the provider's address changes
  (`-c model_providers.labops-pii.base_url="https://chatgpt.com/backend-api/codex"`, the same
  backend the proxy forwards to, the same ChatGPT sign-in). The provider itself is not
  switched: Codex refuses to resume a thread with a different provider;
- an agent that starts while the proxy is down starts in direct mode right away;
- the current mode is in `~/.claude-lab/<agent>/.claude/state/pii-mode` (`proxy` or `direct`).

How to notice: Telegram gets **one** message when the agent switches to direct mode ("pii-proxy
is down — working directly, personal data is not masked") and one when it is back through the
proxy. `/doctor` shows the same warning while the proxy is down.

On Codex the proxy forwards to `https://chatgpt.com`, masks the OpenAI Responses requests
Codex sends and restores the values in the streamed answer. Details:
[`pii-proxy/README.md`](../../pii-proxy/README.md).

### Web search goes around the proxy

Codex has its own web search, so agents on Codex need no separate search skill. That search
runs inside chatgpt.com (`codex_apps`), **not through pii-proxy**: a query leaves exactly as the
model wrote it. The owner decided on 23.11.2026 to keep search on and accept this. As a safeguard,
the agent's instructions (`AGENTS.md`) forbid putting personal data from the conversation into a
search query. To switch search off for one agent, add `web_search = "disabled"` and, under `[features]`,
`apps = false` to its `.codex/config.toml` (the search tool comes from the apps feature) and
restart the agent.

## 6. How the agent runs: the driver

On Claude, the watchdog starts the Claude Code terminal app in tmux and the Telegram plugin
lives inside it. On Codex there is no terminal app to type into. Instead:

```
systemd → watchdog.sh → start-agent.sh → tmux session labops-<agent>
                                            └─ driver: the tg-plugin process (bun, LABOPS_HARNESS=codex)
                                                 └─ codex app-server (JSON-RPC over stdio)
```

- The **driver** is the same `tg-plugin` process in Codex mode. It is the agent's main process:
  it reads Telegram, starts `codex app-server` as its child and talks to it over JSON-RPC.
  tmux only hosts the process — nothing is typed into a screen and nothing is parsed from one,
  so there is no "stuck input" class of problems. `tmux attach -t '=labops-<agent>'` shows its
  log.
- The channel tools (`reply`, reactions, sending files, downloading attachments, …) are given
  to Codex over MCP on the plugin's internal port (`127.0.0.1:6000+`, path `/mcp`), protected by
  a random token that changes on every start.
- **One long-lived thread.** The driver keeps one Codex thread for the agent, like one long
  Claude session. Its id is saved; after a restart the driver resumes the same thread, and only
  if that fails starts a new one.
- **One queue for all input.** Telegram messages, tasks from the task board / agent router and
  webhook deliveries all go into the same queue. If the agent is idle, a message starts a new
  turn. If a turn is running and the message comes from the same chat, it is added to the
  running turn (like a person adding a line to an active conversation); a message from another
  chat waits for the turn to end. Tasks from the board arrive as files in
  `state/codex-inbox/` of the workspace; a file is deleted only after the driver accepted it,
  so a crash means a repeat, not a lost task.
- **Reactions and progress.** 👀 when the message is taken into work, 👌 when the turn ends.
  The live progress status in Telegram is built from app-server events, by the same code as on
  Claude.
- **The answer.** The agent's final message of the turn is sent to the chat that started the
  turn automatically — the agent does not have to call `reply`. `reply` is used for progress
  notes and files; text already sent with `reply` is not repeated. If the turn fails, the chat
  gets a short warning with the error.
- **Questions.** When Codex asks the user a question, it appears as buttons in Telegram.
  Approval requests are not expected (`approval_policy = never`); if one comes, the driver
  declines it and logs it.
- **Memory hooks.** On Claude the hooks are called by Claude Code; on Codex the driver calls
  the **same scripts**: `session-start` (fresh memory into the first turn of a new thread),
  `stop` (after each turn), `precompact`, `heartbeat` (on events and once a minute when idle)
  and `brain-flush` (when the driver stops and before `/reset`). On a restart the driver gets up
  to ~30 s to save memory to the second-brain before it is stopped.
- Telegram, webhook, voice and support tokens are removed from the environment Codex gets, so
  commands the model runs cannot read them.
- Per-person sessions (`multichat`) are not available on Codex yet — the agent runs one
  session.

### Watchdog on Codex

The watchdog does not look at a screen. It checks:

- the driver process is alive and its port `6000+` listens (three misses in a row → restart);
- the heartbeat is fresh (older than 5 minutes → the driver hung → restart);
- the swarm is signed in to ChatGPT. If not, the operator gets **one** alert with the sign-in
  command and the watchdog waits instead of restarting in a loop; when the sign-in is back,
  the agent is restarted automatically;
- the pii-proxy answers `/health`. If not, the agent is switched to direct mode (section 5).

## 7. `/reset` and `/doctor` on Codex

- **`/reset force`** — starts the agent from a clean context, memory is kept. On Codex the
  plugin does it itself: it waits until the current turn ends, saves memory to the
  second-brain, rebuilds `AGENTS.md` and starts a new thread. `/reset` without `force` only asks
  for confirmation.
- **`/doctor`** — checks the agent and fixes what it can, as on Claude. On Codex it checks the
  ChatGPT sign-in, the systemd unit, the tmux session, the driver (process, port, heartbeat —
  restarts it if broken), the plumbing and the second-brain. If the plugin itself is down, the
  watchdog reads `/doctor` from Telegram directly.
- **`/stop`** — interrupts the current turn.

## 8. Tasks from other agents (webhook-listener)

The `webhook-listener` runs one-off agent-to-agent jobs. In a Codex swarm it runs
**`codex exec` instead of `claude -p`** — in the agent's workspace, with the agent's
`CODEX_HOME`, so the job uses the same model, the same pii-proxy and the same second-brain
access as the agent. If the proxy does not answer, the job still runs, directly (same
`base_url` override as the driver), and the owner gets a warning at most once an hour. `codex exec` with a ChatGPT sign-in is an officially supported way to use
the subscription, so it is allowed; the ban on headless `claude -p` stays for Claude.

## 9. Troubleshooting

| Symptom | What to do |
|---|---|
| Telegram alert "Codex is not signed in to ChatGPT" | `CODEX_HOME=~/.claude-lab/shared/codex codex login --device-auth` — once for the whole swarm; agents come up by themselves |
| Message "pii-proxy is down — working directly" | the agent works, but personal data is not masked. Check `systemctl --user status labops-pii-proxy@<agent>`; when the proxy is back the agent returns to it by itself and says so |
| The agent is silent, no alert | send `/doctor`; or `tmux attach -t '=labops-<agent>'` to read the driver log |
| Wrong Codex version | `~/.local/bin/codex --version` must print `0.171.0`; re-run `install.sh` to put it back |
| Want to switch the swarm between Claude and Codex | not done by the installer; it is a separate procedure agreed with the owner |
