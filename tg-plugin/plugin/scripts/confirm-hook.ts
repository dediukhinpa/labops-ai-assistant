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

export type HookDecision =
  | { kind: 'allow' }
  | { kind: 'deny'; reason: string }
  | { kind: 'passthrough' }

const DEFAULT_HTTP_TIMEOUT_MS = 310_000

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

      const url = process.env.CONFIRM_WEBHOOK_URL ?? ''
      const token = process.env.TELEGRAM_WEBHOOK_TOKEN ?? ''
      if (url === '') {
        decision = { kind: 'deny', reason: 'CONFIRM_WEBHOOK_URL не задан — гейт не настроен' }
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
            decision = { kind: 'deny', reason: `плагин ответил ${res.status} — вызов заблокирован` }
          } else {
            const body = (await res.json()) as { status?: unknown; reason?: unknown }
            const reason = typeof body.reason === 'string' ? body.reason : undefined
            decision = decisionFromResponse(body.status, reason)
          }
        } catch {
          // Never surface the error text: a fetch failure message embeds the
          // request URL, which carries no token today but must not become a
          // leak channel if that ever changes.
          decision = { kind: 'deny', reason: 'плагин недоступен — вызов заблокирован' }
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
