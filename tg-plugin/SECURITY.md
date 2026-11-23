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

## Codex harness (driver mode)

On a swarm that runs on Codex CLI the plugin is the agent's main process and starts
`codex app-server` itself (see the README, "Codex harness"). Security-relevant facts:

- The channel tools are served to Codex as MCP over HTTP on the plugin's internal
  `127.0.0.1:6000+` webhook server (`/mcp`), protected by a random Bearer token that is generated
  at every start and kept only in memory and in the Codex child's environment.
- `TELEGRAM_BOT_TOKEN`, `TELEGRAM_WEBHOOK_TOKEN`, `VOICE_TRANSCRIBER_TOKEN` and
  `SUPPORT_FOLLOWUP_TOKEN` are removed from the environment Codex (and every command the model
  runs) receives.
- Codex runs with `approval_policy = "never"` and `sandbox_mode = "danger-full-access"`; approval
  requests, if any arrive, are declined. Run agents as a dedicated non-root user without sudo.
- The swarm's ChatGPT sign-in (`~/.claude-lab/shared/codex/auth.json`, `600` in a `700` folder)
  gives access to the owner's ChatGPT subscription — treat it as a password. Details:
  [`../agent-architecture/SECURITY.md`](../agent-architecture/SECURITY.md).
- `codex exec` in the webhook-listener (Codex swarm) is allowed; it runs with the agent's
  `CODEX_HOME`, so it uses the same config and pii-proxy as the agent.
- **pii-proxy down → direct.** If the agent's pii-proxy does not answer `/health`, the Codex
  driver, multichat sessions and the webhook-listener (`claude -p` and `codex exec`) keep
  working directly, without masking (owner decision, 23.11.2026). A turn running when the
  switch happens is interrupted and its input is repeated directly, so that input reaches the
  model unmasked too. The owner is warned in Telegram (the listener at most
  once an hour, the watchdog once per outage and once on recovery). Personal data is not masked
  while this lasts — see [`../agent-architecture/SECURITY.md`](../agent-architecture/SECURITY.md).

## Supported versions

Security fixes target the latest commit on the default branch (`main`). There are
no separately maintained release branches at this time.
