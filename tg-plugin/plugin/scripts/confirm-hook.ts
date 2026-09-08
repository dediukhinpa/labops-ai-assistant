#!/usr/bin/env bun
// confirm-hook.ts — PreToolUse hook that holds a mutating tool call until the
// operator confirms it in Telegram.
//
// Structural twin of ask-user-question-hook.ts, with ONE deliberate
// difference: this hook is fail-CLOSED. Where the question hook falls back to
// Claude's native UI when the plugin is unreachable, this one denies. An
// unreachable plugin must never turn into a silent approval.
//
// Wire shape:
//
//   stdin (Claude Code PreToolUse envelope):
//     { "hook_event_name": "PreToolUse", "tool_name": "...",
//       "tool_input": { ... } }
//
//   POST $CONFIRM_WEBHOOK_URL
//     { tool_name, tool_input }
//     Authorization: Bearer $TELEGRAM_WEBHOOK_TOKEN
//
//   Plugin replies with:
//     { "status": "allow" }
//     { "status": "deny", "reason": "..." }
//
// Hard invariants:
//   * Exit code 0 in EVERY path. Claude Code reads the decision from stdout
//     JSON; a non-zero exit would short-circuit that channel and hard-block
//     the call with no recoverable signal to the operator.
//   * Anything that is not an explicit `allow` becomes a deny.
//   * The bearer token never reaches stdout or stderr.
//
// Config (env, injected by the hook command in settings.json):
//   CONFIRM_WEBHOOK_URL     e.g. http://127.0.0.1:8093/hooks/confirm/request
//   TELEGRAM_WEBHOOK_TOKEN  bearer token configured on the plugin
//   CONFIRM_GATE            set to "off" to bypass the gate entirely
//   CONFIRM_HTTP_TIMEOUT_MS optional; default 310000 (matches the 310s hook
//                           timeout in settings.json)

import { loadConfirmPolicy } from '../src/safety/confirm-policy.js'
import { decideGate } from '../src/safety/tool-classifier.js'

export type HookDecision =
  | { kind: 'allow' }
  | { kind: 'deny'; reason: string }
  | { kind: 'passthrough' }

const DEFAULT_HTTP_TIMEOUT_MS = 310_000

// Reason codes whose `allow` the hook is willing to make on its own, without
// asking the plugin.
//
// Why this exists: the hook matcher is `*`, so EVERY tool call used to make an
// HTTP round trip, and every one of them denied while the plugin was down.
// That meant a plugin restart blocked `Read`, `Grep`, `ls` — ordinary session
// work the gate would have waved through anyway. Fail-closed has to protect
// business data, not brick the agent whenever its own channel blinks.
//
// The classifier is pure and reads the same policy file the plugin reads, so
// deciding locally cannot diverge from the server. Only the verdicts that
// carry no policy judgement are short-circuited: a local tool, a plain shell
// command, a read-only verb. Everything else — every confirm, every deny, and
// the allows a policy override produced — still goes to the plugin, so the
// audit trail and the operator card stay exactly where they were.
const LOCALLY_DECIDABLE_ALLOW = new Set(['local-tool', 'plain-bash', 'verb-read'])

export type LocalVerdict = 'skip-network' | 'allow-if-unreachable' | 'must-ask'

/**
 * What the hook can work out on its own, before touching the network.
 *
 *  * `skip-network` — routine session traffic. Answered locally; the plugin
 *    is not called at all, which is also what keeps a per-call HTTP round
 *    trip off every `Read` and `Grep`.
 *  * `allow-if-unreachable` — an allow that came from a policy decision
 *    (`overrides.allow`, `mode: off`). Still sent to the plugin so it lands
 *    in the audit log, but if the plugin cannot be reached the hook allows
 *    it rather than blocking: the policy already said yes, and the agent's
 *    own second brain must not stop working because the channel blinked.
 *  * `must-ask` — everything else. Only these can be denied by an
 *    unreachable plugin, and those are exactly the calls worth denying.
 */
export function localVerdict(
  toolName: string,
  toolInput: Record<string, unknown>,
  policyPath: string,
): LocalVerdict {
  if (toolName === '') return 'must-ask'
  if (policyPath === '') return 'must-ask'
  const loaded = loadConfirmPolicy(policyPath)
  if (!loaded.ok) return 'must-ask'
  const decision = decideGate(toolName, toolInput, loaded.policy)
  if (decision.action !== 'allow') return 'must-ask'
  return LOCALLY_DECIDABLE_ALLOW.has(decision.code) ? 'skip-network' : 'allow-if-unreachable'
}

export function decisionFromResponse(status: unknown, reason?: string): HookDecision {
  if (status === 'allow') return { kind: 'allow' }
  if (status === 'deny') return { kind: 'deny', reason: reason ?? 'отклонено оператором' }
  if (status === 'timeout') {
    return { kind: 'deny', reason: 'таймаут подтверждения — вызов заблокирован' }
  }
  return { kind: 'deny', reason: `непонятный ответ плагина: ${JSON.stringify(status)}` }
}

export function renderHookStdout(decision: HookDecision): string {
  if (decision.kind === 'passthrough') return ''
  if (decision.kind === 'allow') {
    return JSON.stringify({
      hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'allow' },
    })
  }
  return JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'deny',
      permissionDecisionReason: decision.reason,
    },
  })
}

// Kill switch. Only the exact word "off" (case- and space-insensitive)
// disables the gate — a typo like "0" or "no" must NOT silently open it.
//
// The agent cannot flip this on itself: hooks inherit the session's
// environment, and an `export` inside a Bash tool call lives only in that
// subshell. The operator sets it in the systemd EnvironmentFile / wrapper
// and restarts the session.
export function shouldBypass(env: Record<string, string | undefined>): boolean {
  return (env.CONFIRM_GATE ?? '').trim().toLowerCase() === 'off'
}

// Where to ask. An explicit CONFIRM_WEBHOOK_URL wins; otherwise the URL is
// derived from the channel's own host/port.
//
// Why derive instead of baking the port into settings.json: new-agent.sh
// picks a free webhook port only AFTER the workspace scaffolder has already
// rendered settings.json from its template. A port written into settings.json
// would either be wrong or force a second patching pass — and would go stale
// the moment the operator moves the agent to another port.
export function resolveWebhookUrl(env: Record<string, string | undefined>): string {
  const explicit = (env.CONFIRM_WEBHOOK_URL ?? '').trim()
  if (explicit !== '') return explicit
  const port = (env.TELEGRAM_WEBHOOK_PORT ?? '').trim()
  if (!/^[0-9]+$/.test(port)) return ''
  const host = (env.TELEGRAM_WEBHOOK_HOST ?? '').trim() || '127.0.0.1'
  return `http://${host}:${port}/hooks/confirm/request`
}

async function readStdin(): Promise<string> {
  const chunks: Uint8Array[] = []
  for await (const chunk of process.stdin) {
    chunks.push(chunk as Uint8Array)
  }
  return Buffer.concat(chunks).toString('utf8')
}

async function main(): Promise<void> {
  let decision: HookDecision

  try {
    if (shouldBypass(process.env)) {
      decision = { kind: 'passthrough' }
    } else {
      const raw = await readStdin()
      let envelope: Record<string, unknown>
      try {
        envelope = JSON.parse(raw) as Record<string, unknown>
      } catch {
        decision = { kind: 'deny', reason: 'хук не смог разобрать конверт вызова' }
        process.stdout.write(renderHookStdout(decision))
        process.exit(0)
      }

      const toolName = typeof envelope.tool_name === 'string' ? envelope.tool_name : ''
      const toolInput =
        typeof envelope.tool_input === 'object' && envelope.tool_input !== null
          ? envelope.tool_input
          : {}

      // Ordinary session traffic never touches the network. See localVerdict
      // for why deciding this here is both safe and necessary.
      const local = localVerdict(
        toolName,
        toolInput as Record<string, unknown>,
        (process.env.CONFIRM_POLICY_PATH ?? '').trim(),
      )
      if (local === 'skip-network') {
        process.stdout.write(renderHookStdout({ kind: 'allow' }))
        process.exit(0)
      }

      const url = resolveWebhookUrl(process.env)
      const token = process.env.TELEGRAM_WEBHOOK_TOKEN ?? ''
      if (url === '') {
        // No channel at all: neither an explicit URL nor a webhook port. The
        // gate was never provisioned in this session, so there is nothing to
        // ask — pass through rather than block every tool call.
        //
        // This is the ONE fail-open branch, and it is about PROVISIONING, not
        // operation: once a channel exists, every failure below denies. A hook
        // registered in a workspace whose plugin was never installed must not
        // brick the agent.
        decision = { kind: 'passthrough' }
      } else {
        const timeoutMs = Number(process.env.CONFIRM_HTTP_TIMEOUT_MS ?? DEFAULT_HTTP_TIMEOUT_MS)
        const controller = new AbortController()
        const timer = setTimeout(() => controller.abort(), timeoutMs)
        try {
          const res = await fetch(url, {
            method: 'POST',
            headers: {
              'content-type': 'application/json',
              ...(token !== '' ? { authorization: `Bearer ${token}` } : {}),
            },
            body: JSON.stringify({ tool_name: toolName, tool_input: toolInput }),
            signal: controller.signal,
          })
          if (!res.ok) {
            // Status code only — a body could echo back the bearer token.
            decision = local === 'allow-if-unreachable'
              ? { kind: 'allow' }
              : { kind: 'deny', reason: `плагин ответил ${res.status} — вызов заблокирован` }
          } else {
            const body = (await res.json()) as { status?: unknown; reason?: unknown }
            const reason = typeof body.reason === 'string' ? body.reason : undefined
            decision = decisionFromResponse(body.status, reason)
          }
        } catch {
          // Never surface the error text: a fetch failure message embeds the
          // request URL, which carries no token today but must not become a
          // leak channel if that ever changes.
          decision = local === 'allow-if-unreachable'
            ? { kind: 'allow' }
            : { kind: 'deny', reason: 'плагин недоступен — вызов заблокирован' }
        } finally {
          clearTimeout(timer)
        }
      }
    }
  } catch {
    decision = { kind: 'deny', reason: 'внутренняя ошибка хука — вызов заблокирован' }
  }

  process.stdout.write(renderHookStdout(decision))
  process.exit(0)
}

// Only run when invoked as a script, so the test file can import the pure
// helpers without triggering a stdin read that would hang the suite.
if (import.meta.main) {
  void main()
}
