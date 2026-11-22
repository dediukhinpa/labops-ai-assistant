<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/labops-logo-dark.svg">
    <img src="assets/labops-logo.svg" alt="LabOps.ai" width="280">
  </picture>
</p>

<h1 align="center">labops-ai-assistant</h1>

<p align="center"><em>AI operations — from inside the profession</em></p>

<p align="center">
  <a href="https://labopsai.pro"><img src="https://img.shields.io/badge/%F0%9F%8C%90%20labopsai.pro-6E56CF?style=for-the-badge" alt="labopsai.pro"></a>
  <a href="./LICENSE"><img src="https://img.shields.io/badge/License-Proprietary-CC2B2B?style=for-the-badge" alt="License: Proprietary"></a>
  <img src="https://img.shields.io/badge/Built%20by-LabOps.ai-111111?style=for-the-badge" alt="Built by LabOps.ai">
</p>

<p align="center"><a href="README.md"><b>English</b></a> · <a href="README.ru.md">Русский</a></p>

<p align="center">
  <b>Bundles:</b>
  <a href="agent-architecture/">agent-architecture</a> ·
  <a href="tg-plugin/">tg-plugin</a>
  &nbsp;|&nbsp;
  <b>Sibling:</b>
  <a href="https://github.com/dediukhinpa/labops-second-brain">second-brain</a>
</p>

<p align="center">
  <img src="assets/demo.svg" alt="Demo: Telegram chat — receive → 👀 → reply → 👌" width="560">
</p>
<p align="center"><sub><i>Illustrative mockup of the two-stage reaction flow (👀 received → 👌 done) — not a screen recording.</i></sub></p>

**A self-hosted AI assistant you talk to in Telegram** — a single, long-lived Claude Code session (or Codex, if you choose the [Codex harness](#choosing-the-harness-claude-code-or-codex)) that lives on your own server, remembers, self-heals under systemd, and grows into a swarm. This repository **combines the two layers that make that assistant run** into one deployable unit:

- **[`agent-architecture/`](agent-architecture/)** — the **runtime & lifecycle** layer: how an agent *lives*. Workspaces, layered memory, the `agent-template` scaffolder, a self-healing supervisor (`watchdog.sh → start-agent.sh → tmux → a long-lived Claude Code session`), systemd units, lifecycle hooks, and the **`create-agent`** skill the first agent uses to roll out the rest of the swarm.
- **[`tg-plugin/`](tg-plugin/)** — the **Telegram I/O channel**: a Claude Code plugin (Bun/TypeScript) that turns an ordinary `claude` session into a long-lived Telegram agent — text, voice, media, status reactions, and interactive buttons — registered as an **MCP server inside the live session**, not a headless process per message.

The third layer of the system — shared long-term memory — lives in the sibling repository **[`labops-second-brain`](https://github.com/dediukhinpa/labops-second-brain)** (Postgres + pgvector, served over MCP). It is a runtime *dependency* the agent talks to, not part of this bundle.

> [!IMPORTANT]
> **Platform:** Linux + systemd + tmux. On macOS / without systemd you can run an agent manually in tmux, but not as a service (no autostart / self-healing).

---

## Table of contents

1. [What it is](#what-it-is)
2. [Repository layout](#repository-layout)
3. [How the pieces fit](#how-the-pieces-fit)
4. [Quickstart](#quickstart)
5. [Choosing the harness: Claude Code or Codex](#choosing-the-harness-claude-code-or-codex)
6. [Component · agent-architecture](#component--agent-architecture)
7. [Component · tg-plugin](#component--tg-plugin)
8. [Security](#security)
9. [Data & privacy](#data--privacy)
10. [Part of labops](#part-of-labops)
11. [License](#license)

---

## What it is

In the labops system the **backend is Agent-Native**: memory, swarm, and channel are APIs/MCP *for agents*, not a UI for humans. A human (the Operator) sees only Telegram. This bundle is what turns the Claude Code "engine" into a **continuously living agent** — it gives it a workplace (a workspace with memory), a supervisor (a watchdog under systemd), lifecycle events (hooks), and a way to talk to you (Telegram).

- **One assistant, two layers, one deploy.** `agent-architecture` owns how the agent *lives*; `tg-plugin` owns how it *talks*. Together they are the complete client side of a labops agent.
- **Plugin, not gateway.** The Telegram channel registers *inside* a live Claude Code session (MCP), so every message reuses the same context, memory, skills, and billing — instead of spinning up a fresh headless `claude -p` per turn.
- **Self-bootstrapping swarm.** You install only the **first agent — Developer** — and from there it rolls out the next ones itself via the [`create-agent`](agent-architecture/) skill.
- **Nested self-healing.** systemd holds the watchdog, the watchdog holds tmux+claude, claude holds the channel server. A failure at any level is healed by the level above.
- **Truth beats memory.** The hierarchy is live check (exec/grep) → second_brain (shared brain) → git history → local memory. When memory contradicts a live check, the check wins.

| Layer | Directory | Stack | Owns |
|---|---|---|---|
| **Runtime / lifecycle** | [`agent-architecture/`](agent-architecture/) | Bash · systemd · tmux · Python | workspaces, memory, watchdog, systemd, hooks, swarm automation, `create-agent` |
| **Channel** | [`tg-plugin/`](tg-plugin/) | TypeScript · Bun · Python | Telegram long-poll, replies/reactions, voice, webhook `:6000+`, channel MCP tools |
| **Memory** *(sibling)* | [`labops-second-brain`](https://github.com/dediukhinpa/labops-second-brain) | Python · Postgres/pgvector | shared L4 memory, swarm event bus, RBAC by Bearer |

---

## Repository layout

```
labops-ai-assistant/
├── README.md              # this file (EN)
├── README.ru.md           # Русский
├── LICENSE                # Proprietary — © LabOps.ai
├── SECURITY.md            # private vulnerability reporting
├── install.sh             # ← unified installer (both components, one command)
├── assets/                # shared logos + demo mockups
├── agent-architecture/    # ← runtime & lifecycle layer (full repo)
│   ├── install.sh · test.sh
│   ├── agent-template/    # workspace scaffolder
│   ├── orchestration/     # watchdog, start-agent, swarm one-shots
│   ├── skills/            # create-agent + bundled skills
│   └── systemd/           # unit templates
└── tg-plugin/             # ← Telegram channel layer (full repo)
    ├── install.sh · uninstall.sh
    ├── plugin/            # Bun/TS MCP server + poller + hook webhook
    ├── webhook-listener/  # separate aiohttp a-to-a ingress
    └── docs/              # placement + setup guides
```

> [!NOTE]
> The two components live as subdirectories of this single repository — install them with the one root [`install.sh`](install.sh) (it drives each component's own installer for you). Each subdirectory keeps its own `README.md` / `README.ru.md`, tests, and `LICENSE` for layer-specific detail; open the component's own README from the sections below.

---

## How the pieces fit

Nobody runs the agent "by hand" — **systemd** holds everything, and the agent brings itself back up after any crash. `agent-architecture` supplies the supervision and the workspace; `tg-plugin` supplies the channel that plugs into the live session; `second_brain` (sibling) supplies shared memory over MCP.

```mermaid
%%{init: {'theme':'base','themeVariables':{'primaryColor':'#EDE9FE','primaryTextColor':'#4C1D95','primaryBorderColor':'#8B5CF6','lineColor':'#8B5CF6','secondaryColor':'#F1F5F9','tertiaryColor':'#ffffff','clusterBkg':'transparent','clusterBorder':'#B794F4','fontFamily':'Helvetica,Arial,sans-serif'}}}%%
flowchart LR
  subgraph arch["agent-architecture · supervision"]
    direction TB
    SD["systemd: claude-agent-&lt;agent&gt;.service"]
    WD["watchdog.sh &lt;agent&gt;<br/>eternal supervisor"]
    SA["start-agent.sh<br/>injects env/secrets"]
    TM["tmux session labops-&lt;agent&gt;"]
    PL["task-poller.sh + task_poller.py<br/>board poller, one MCP session"]
    SD -->|ExecStart| WD --> SA --> TM
    WD -->|supervises| PL
  end
  subgraph live["Live runtime"]
    direction TB
    CC["claude (Claude Code CLI)<br/>--dangerously-skip-permissions"]
    BUN["tg-plugin channel server (bun)<br/>Telegram long-poll + webhook :6000+"]
  end
  TM --> CC
  CC -->|spawn child, stdio MCP| BUN
  CC -->|HTTP + Bearer| SB["second_brain MCP<br/>memory / memory_router / agent_router / tasks"]
  BUN <-->|getUpdates / sendMessage| TG["Telegram (Operator)"]
  classDef brand fill:#8B5CF6,stroke:#6D28D9,color:#ffffff,font-weight:bold
  classDef ext fill:#CCFBF1,stroke:#0D9488,color:#0F766E
  classDef store fill:#FEF3C7,stroke:#D97706,color:#92400E
  classDef sys fill:#E2E8F0,stroke:#334155,color:#1E293B
  linkStyle default stroke:#8B5CF6,stroke-width:1.5px
  class CC brand
  class SD,WD,SA,TM,PL sys
  class BUN,SB,TG ext
```

**Message flow:** user msg → 👀 reaction (poller) → MCP notification to the live session → the session thinks / calls tools → lifecycle hooks fire to the channel's `127.0.0.1:6000+` webhook (progress status) → the agent replies via the channel MCP tool → the `Stop` hook sets 👌.

> [!IMPORTANT]
> An incoming Telegram message does **not** go through the webhook server. Poller → MCP notification → session. The `:6000+` webhook only receives **Claude Code lifecycle hooks**, not Telegram traffic.

**Agent-to-agent flow:** a caller writes `task_create(assignee=…)` on the board → the agent's poller sees `status=new` within ~5 s and types a line into its live pane → the agent runs `task_claim` → `task_review` → `task_done`. No headless `claude -p` anywhere, so a delegated task costs no SDK credits.

---

## Quickstart

**One unified installer** brings up both bundled components — the runtime/lifecycle layer *and* the Telegram channel — in a single run. The shared brain (`labops-second-brain`) is an external dependency, installed separately.

```bash
git clone https://github.com/dediukhinpa/labops-ai-assistant.git
cd labops-ai-assistant

# One command: deps + Claude Code + self-test + Developer agent, then the
# bundled Telegram channel (tg-plugin) — all wired together automatically.
bash install.sh
```

The first question the installer asks is the **harness** — `claude` (Claude Code, Claude subscription; the default) or `codex` (Codex CLI, ChatGPT subscription); see [below](#choosing-the-harness-claude-code-or-codex). To skip the question: `HARNESS=codex bash install.sh`.

The root `install.sh` installs `agent-architecture` (deps, Claude Code or Codex, the first agent) and then the bundled `tg-plugin` from this tree — nothing is cloned for the channel, it is already here. Flags pass through: `bash install.sh --no-agent` (prepare only), `bash install.sh --test-only` (self-test).

**Shared memory** — `labops-second-brain` is a *separate* dependency, not part of this repo. `install.sh` clones it next to the repo (unless `SKIP_SECOND_BRAIN=1`); install it with `sudo bash ~/labops-second-brain/scripts/install.sh` (or hand it to a Claude Code agent following its `AGENT.md`). It issues the agent a Bearer token and brings up MCP `memory:5001` / `memory_router:5002` / `agent_router:5000` / `tasks:5003` (the task board).

> [!TIP]
> The default model is `sonnet` (an alias — always the latest model of its tier). You install only the **first** agent — then the swarm grows itself: the Developer spawns the rest via the `create-agent` skill.

> [!IMPORTANT]
> **Model & auth.** Sign in once with `claude setup-token` (Max/Pro subscription, first-party — no third-party risk). The agent's model is set in `settings.json` (the `model` field). Model config is **operator-owned** — never change it without the owner. Without sign-in the agent starts under systemd but can't reach the model — the smoke test catches this.
>
> On the **Codex harness** the swarm signs in once to ChatGPT (`codex login --device-auth`, see below), the model is set in the agent's `config.toml`, and the default model is `gpt-6.2-sol`.

> [!WARNING]
> **Never run agents as root.** They run with `--dangerously-skip-permissions`; a dedicated non-root user is expected. Secrets live in `channel.env` / `.env` / `.claude/secrets/` (`chmod 600/640`), are git-ignored, and are never committed.

Full, layer-specific instructions live in each component's README:
[`agent-architecture/README.md`](agent-architecture/README.md) · [`tg-plugin/README.md`](tg-plugin/README.md).

---

## Choosing the harness: Claude Code or Codex

The **harness** is the program the agents live in. The swarm can run on **Claude Code** (paid from your Claude subscription) or on **Codex CLI** (paid from your ChatGPT subscription). Memory, second-brain, Telegram, the watchdog, the task board and PII masking work the same on both. Full guide: [`agent-architecture/docs/codex-harness.md`](agent-architecture/docs/codex-harness.md).

- **One harness for the whole swarm.** It is the first question of `install.sh` (`HARNESS=claude|codex` answers it without a prompt) and is stored in `~/.claude-lab/shared/swarm.env`. New agents inherit it. If agents already exist, the installer refuses to switch the swarm to the other harness.
- **Codex is pinned to version `0.171.0`.** The installer downloads the official release package (checked by sha256) into `~/.local/share/labops-codex/` of the agents' user and links `~/.local/bin/codex` — not `/usr/local/bin`.
- **One ChatGPT sign-in for the whole swarm:** `CODEX_HOME=~/.claude-lab/shared/codex codex login --device-auth`. Codex prints a link and a code; open the link on any device, sign in to ChatGPT and enter the code. Every agent's `CODEX_HOME` (`~/.claude-lab/<agent>/.codex/`) links to this shared sign-in, so a token refresh by one agent reaches all of them. API-key sign-in is not accepted.
- **PII masking is mandatory on Codex.** An agent on Codex is not installed and not started without its local `pii-proxy`; all model traffic goes through it.
- **Default model:** `gpt-6.2-sol`.
- **No terminal app in tmux.** The watchdog starts the Telegram plugin in "driver" mode, and the driver runs `codex app-server` and talks to it over JSON-RPC: one queue for Telegram messages and tasks, 👀/👌 reactions, the agent's final message goes to the chat by itself, memory hooks are called by the driver, the conversation thread is resumed after a restart.
- **`/reset force` and `/doctor`** work on Codex too; `/stop` interrupts the current turn.
- **Tasks from other agents:** in a Codex swarm the `webhook-listener` runs `codex exec` instead of `claude -p`.

---

## Component · agent-architecture

> Runtime & lifecycle — how an agent *lives*. Full docs: [`agent-architecture/README.md`](agent-architecture/README.md).

- **`agent-template/`** — the scaffolder: `install.sh` renders `templates/*.template` into a per-agent workspace `~/.claude-lab/<agent-id>/.claude/` (`CLAUDE.md` = identity, `settings.json` = hooks + `model`, `.mcp.json` = second_brain endpoints). Memory is role-based: identity + `core/` rules + `active/` (episodic diary + materialised recall) + `passive/` (distilled insights) + `archive/`, plus the shared second_brain over MCP. Consolidation is event-driven (in-session reflection on checkpoint / idle), not cron — see [`agent-architecture/docs/MEMORY-REDESIGN.md`](agent-architecture/docs/MEMORY-REDESIGN.md).
- **`orchestration/`** — the running swarm: `watchdog.sh <agent>` is the systemd `ExecStart`; it launches `start-agent.sh` which sources `channel.env`, computes a per-agent webhook port (base `6000 + roster index`), and starts tmux session `labops-<agent>`. `lib/agents.sh` resolves the roster dynamically; `lib/notify.sh` sends throttled Telegram alerts.
- **`skills/`** — bundled Claude Code skills; **`create-agent`** is the key one — it drives a full deployment (role → scaffold → bot → voice → token → systemd → smoke) so the swarm grows itself.

<details>
<summary><b>Three levels of self-healing</b></summary>

| What is fixed | Who fixes it | How |
|---|---|---|
| frozen / dead agent session | `watchdog.sh` | detects a frozen pane → `start-agent.sh` recreates the session (the diary `episodic.md` and the shared brain keep the latest events) |
| crashed watchdog | `systemd` | `Restart=on-failure` + `RestartSec=15` |
| orphaned bun (claude died, bun on PID 1) | `watchdog.sh` / `start-agent.sh` | `pkill -9` by the agent's path |
| MCP server / worker wedged or crash-looping | `second_brain-monitor.sh` (systemd timer) | `systemctl is-active` + an HTTP `/mcp` probe → Telegram alert on the down/up transition |

</details>

---

## Component · tg-plugin

> The Telegram I/O channel. Full docs: [`tg-plugin/README.md`](tg-plugin/README.md).

A single Bun process (`plugin/src/server.ts`) plays **three roles at once**:

1. **MCP stdio server** — registered in the session's `.mcp.json` as `labops-channel`; gives Claude the channel tools (reply, ask-with-buttons, request-permission).
2. **Telegram long-poller** — pulls updates via `getUpdates` (**pull**, not webhook): no public IP/domain/TLS needed, works behind NAT. Hands an incoming message to the session as an MCP notification.
3. **Internal webhook server** (`127.0.0.1:6000+`) — listens for **Claude Code lifecycle hooks** to drive reactions and the progress status. This is **not** a Telegram webhook.

| Capability | What it does |
|---|---|
| **Two-stage reactions** | 👀 "received" immediately, 👌 "done" at the end of the turn |
| **Voice & media** | voice → transcription → text to the agent; photos/documents/albums buffered as attachments |
| **AskUserQuestion / Permission** | interactive option & confirmation buttons right in Telegram |
| **Progress mirror** | live "what the agent is doing now" status |
| **Security** | allowlist by user_id/chat_id, anti-spoof bot_id check, secret redaction, HTML validator, rate-limit |

> [!NOTE]
> `webhook-listener/` is a **separate** Python aiohttp service (port `6100`) for agent-to-agent ingress from `second_brain` — distinct from both the human Telegram ingress and the internal hook webhook.

---

## Security

Report vulnerabilities privately — see [`SECURITY.md`](SECURITY.md). **Do not open a public issue** for security problems; use GitHub *Security → Report a vulnerability* or email `security@labopsai.pro`.

- **Self-hosted, no telemetry.** You run it on your own server and hold your own credentials.
- **Secrets never committed.** They live in `channel.env` / `.env` / `.claude/secrets/` (`chmod 600/640`), git-ignored, guarded by `gitleaks` CI (`.github/workflows/gitleaks.yml`) and repo secret-scans.
- **Channel hardening.** Allowlist by `user_id`/`chat_id`, anti-spoof `TELEGRAM_EXPECTED_BOT_ID`, outbound secret redaction, HTML whitelist validator, Telegram rate-limiting.
- **No header → 401.** The shared brain authenticates every request by per-agent Bearer (only a salted `sha256` is stored) — never a silent fallback.

---

## Data & privacy

Self-hosted by design: agents run on the operator's own Linux server, `second_brain` (Postgres + vault) is local, and there is no telemetry. The only outbound traffic goes to the AI / messaging providers the operator configures.

| Endpoint | Purpose | When | Optional |
|---|---|---|---|
| `api.anthropic.com` (via the Claude Code engine) | LLM inference — the model the agent runs on | while the agent is active, Claude harness | no (core) |
| `chatgpt.com` (via Codex CLI, through the local pii-proxy) | LLM inference on the ChatGPT subscription | while the agent is active, Codex harness | no (core on Codex) |
| `auth.openai.com` | ChatGPT sign-in and token refresh | Codex harness | no (on Codex) |
| `api.telegram.org` | chat I/O — receiving and sending messages | while running | no |
| `127.0.0.1` (local voice-transcriber, faster-whisper) | voice transcription | only on voice messages | local — audio never leaves the host |
| `second_brain` (`localhost` MCP, Postgres + vault) | conversation memory & state | always | local — never leaves the host |

> [!IMPORTANT]
> The only data that leaves the machine is the prompt / response traffic to the configured AI providers — which is required for any LLM agent to function. Everything else stays on the operator's host.

---

## Part of labops

| Repository | Layer | Provides |
|---|---|---|
| **agent-architecture** (bundled here) | runtime / lifecycle | workspaces, memory, watchdog/systemd, hooks, swarm automation, `create-agent` |
| **tg-plugin** (bundled here) | channel | per-agent Telegram bot, voice, reactions, webhook `:6000+`, channel MCP tools |
| **[labops-second-brain](https://github.com/dediukhinpa/labops-second-brain)** | memory | Postgres+pgvector, MCP `memory:5001` / `memory_router:5002` / `agent_router:5000` / `task:5003`, RBAC by Bearer |

---

## License

Proprietary — © 2026 LabOps.ai. All rights reserved. See [LICENSE](./LICENSE).
