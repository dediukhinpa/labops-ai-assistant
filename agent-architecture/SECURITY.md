# Security policy

LabOps.ai takes the security of this software seriously. Thank you for helping keep it and its users safe.

## Reporting a vulnerability

**Please do not open a public issue for security problems.**

Report privately through either channel:

- **GitHub** — use *Security → Report a vulnerability* (private advisory) on this repository.
- **Email** — `security@labopsai.pro`

Please include: a description of the issue, steps to reproduce (a proof-of-concept if possible), the affected version/commit, and the impact you foresee.

We aim to acknowledge a report within **3 business days** and to share a remediation timeline after triage. Please give us reasonable time to fix the issue before any public disclosure (coordinated disclosure).

## Scope

- **In scope:** the code in this repository — scripts, services, templates.
- **Out of scope:** third-party services this software talks to (Telegram, Anthropic, OpenAI, …). Report those to the respective vendor. See the **Data & privacy** section of the README for the exact endpoints used.

## Secrets & operator responsibility

This software is **self-hosted**: you run it on your own server and hold your own
credentials. Keep secrets out of git — bot tokens and API keys live in `channel.env` /
`.env` / `.claude/secrets/` with restrictive permissions (`chmod 600`/`640`) and are
never committed. A leaked
*token* is rotated with the provider (BotFather, the Anthropic console, ChatGPT account settings, …), not
through this repository. This repo also runs `gitleaks` in CI and ships its own
secret-scan guards to catch accidental commits.

Restrictive file permissions are necessary but not sufficient: a secret passed on a
**command line** is world-readable in `ps` regardless of the permissions on the file
it came from. Agent sessions therefore receive their environment from
`orchestration/lib/agent-env.sh`, assembled inside the tmux pane by
`orchestration/session-exec.sh`; only the agent id appears in the process arguments.
Keep it that way when adding new configuration — pass it through `channel.env` or
`.claude/secrets/`, never as a flag.

## PII masking and data localisation

Agents are installed behind a local `pii-proxy` by default (`SKIP_PII_PROXY=1` disables it
explicitly). Masking does not replace 152-FZ localisation: `install.sh` warns when the host IP is
outside Russia, and the operator decides where personal data of Russian citizens may be stored.

## Codex harness (ChatGPT subscription)

When the swarm runs on Codex CLI instead of Claude Code (see
[`docs/codex-harness.md`](docs/codex-harness.md)), a few
more things deserve care:

- **The swarm's ChatGPT sign-in is a password.** It lives in
  `~/.claude-lab/shared/codex/auth.json` (file `600`, folder `700`, owned by the agents' user);
  every agent's `CODEX_HOME` (`~/.claude-lab/<agent>/.codex/`, `700`) only links to it. Whoever
  can read this file can use the owner's ChatGPT subscription until the session is revoked. Never
  copy it to another machine, never commit it, never paste it into a chat. If it leaks, sign out
  of all sessions in the ChatGPT account settings and sign the swarm in again
  (`CODEX_HOME=~/.claude-lab/shared/codex codex login --device-auth`).
- **Sign-in headers pass through pii-proxy untouched and are not logged.** The local proxy
  forwards `Authorization` and `chatgpt-account-id` to `chatgpt.com` as they are; its log records
  only the route, status, timings, a hashed session id and, on upstream errors, an allowlist of
  response headers (request id, rate limits) — never request headers or bodies.
- **The agent runs without confirmations.** `config.toml` sets `approval_policy = "never"` and
  `sandbox_mode = "danger-full-access"` — the Codex equivalent of
  `--dangerously-skip-permissions`. The only boundary is the OS user, so agents must run as a
  dedicated **non-root** user **without sudo rights**. Codex has no equivalent of Claude Code's
  `Bash(sudo *)` deny rule in this setup.
- **Headless runs.** `codex exec` (used by the webhook-listener for agent-to-agent jobs on a
  Codex swarm) is allowed: it uses the same ChatGPT sign-in, config and pii-proxy as the agent.
  The ban on headless `claude -p` / `claude setup-token` in the installer and orchestration stays
  for Claude.

## Supported versions

Security fixes target the latest commit on the default branch (`main`). There are
no separately maintained release branches at this time.
