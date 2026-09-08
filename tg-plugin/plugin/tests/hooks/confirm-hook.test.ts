// Tests for the confirm-gate PreToolUse hook wrapper.
//
// The wrapper is fail-CLOSED: anything other than an explicit `allow` from
// the plugin becomes a deny. This is the one place where it deliberately
// differs from ask-user-question-hook.ts, which degrades to Claude's native
// UI when the plugin is unreachable.

import { describe, expect, test } from 'bun:test'
import {
  decisionFromResponse,
  renderHookStdout,
  shouldBypass,
  localVerdict,
} from '../../scripts/confirm-hook.js'

describe('decisionFromResponse — fail-closed', () => {
  test('allow', () => expect(decisionFromResponse('allow')).toEqual({ kind: 'allow' }))

  test('deny carries the reason', () => {
    expect(decisionFromResponse('deny', 'отклонено оператором'))
      .toEqual({ kind: 'deny', reason: 'отклонено оператором' })
  })

  test('timeout denies', () => {
    expect(decisionFromResponse('timeout').kind).toBe('deny')
  })

  test('unknown status denies, never allows', () => {
    expect(decisionFromResponse('banana').kind).toBe('deny')
  })

  test('undefined status denies', () => {
    expect(decisionFromResponse(undefined).kind).toBe('deny')
  })
})

describe('renderHookStdout', () => {
  test('allow emits permissionDecision allow', () => {
    expect(JSON.parse(renderHookStdout({ kind: 'allow' }))).toEqual({
      hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'allow' },
    })
  })

  test('deny carries a human-readable reason', () => {
    const out = JSON.parse(renderHookStdout({ kind: 'deny', reason: 'таймаут' }))
    expect(out.hookSpecificOutput.permissionDecision).toBe('deny')
    expect(out.hookSpecificOutput.permissionDecisionReason).toBe('таймаут')
  })

  test('passthrough emits empty stdout', () => {
    expect(renderHookStdout({ kind: 'passthrough' })).toBe('')
  })
})

describe('shouldBypass — kill switch', () => {
  test('CONFIRM_GATE=off bypasses the gate', () => {
    expect(shouldBypass({ CONFIRM_GATE: 'off' })).toBe(true)
  })

  test('unset CONFIRM_GATE does not bypass', () => {
    expect(shouldBypass({})).toBe(false)
  })

  test('any other value does not bypass — only the exact word disables', () => {
    expect(shouldBypass({ CONFIRM_GATE: 'ofF ' })).toBe(true)
    expect(shouldBypass({ CONFIRM_GATE: 'no' })).toBe(false)
    expect(shouldBypass({ CONFIRM_GATE: '0' })).toBe(false)
  })
})

describe('resolveWebhookUrl', () => {
  test('explicit CONFIRM_WEBHOOK_URL wins', async () => {
    const { resolveWebhookUrl } = await import('../../scripts/confirm-hook.js')
    expect(resolveWebhookUrl({ CONFIRM_WEBHOOK_URL: 'http://x/y', TELEGRAM_WEBHOOK_PORT: '6001' }))
      .toBe('http://x/y')
  })

  // The webhook port is only known after new-agent.sh has written
  // channel.env — long after settings.json was rendered. Deriving the URL
  // here keeps the port out of settings.json entirely.
  test('derives from TELEGRAM_WEBHOOK_PORT when the explicit url is absent', async () => {
    const { resolveWebhookUrl } = await import('../../scripts/confirm-hook.js')
    expect(resolveWebhookUrl({ TELEGRAM_WEBHOOK_PORT: '6001' }))
      .toBe('http://127.0.0.1:6001/hooks/confirm/request')
  })

  test('honours a non-default host', async () => {
    const { resolveWebhookUrl } = await import('../../scripts/confirm-hook.js')
    expect(resolveWebhookUrl({ TELEGRAM_WEBHOOK_HOST: '127.0.0.5', TELEGRAM_WEBHOOK_PORT: '6002' }))
      .toBe('http://127.0.0.5:6002/hooks/confirm/request')
  })

  test('no port and no url yields empty — caller decides what that means', async () => {
    const { resolveWebhookUrl } = await import('../../scripts/confirm-hook.js')
    expect(resolveWebhookUrl({})).toBe('')
  })

  test('a non-numeric port is not trusted', async () => {
    const { resolveWebhookUrl } = await import('../../scripts/confirm-hook.js')
    expect(resolveWebhookUrl({ TELEGRAM_WEBHOOK_PORT: 'nope' })).toBe('')
  })
})

// ─────────────────────────────────────────────────────────────────────
// The hook classifies before it dials.
//
// Reason: the matcher is `*`, so every tool call reached the plugin, and a
// plugin that was down denied all of them — `Read`, `Grep`, `ls` included.
// A plugin restart bricked the session. Fail-closed must protect business
// data, not stop the agent whenever its own channel blinks.
// ─────────────────────────────────────────────────────────────────────

const POLICY_PATH = new URL('../../../examples/confirm-policy.example.yaml', import.meta.url)
  .pathname

describe('localVerdict — ordinary session traffic never dials the plugin', () => {
  const ROUTINE: Array<[string, Record<string, unknown>]> = [
    ['Read', { file_path: '/tmp/x.ts' }],
    ['Edit', { file_path: '/home/u/src/app.ts' }],
    ['Write', { file_path: '/home/u/src/app.ts' }],
    ['Grep', { pattern: 'TODO' }],
    ['Glob', { pattern: '**/*.ts' }],
    ['Task', {}],
    ['TodoWrite', {}],
    ['WebSearch', { query: 'x' }],
    ['WebFetch', { url: 'https://example.com' }],
    ['Bash', { command: 'git status' }],
    ['Bash', { command: 'npm install' }],
    ['Bash', { command: 'pytest -q' }],
    ['Bash', { command: 'curl https://api.github.com/repos/x/y' }],
    ['mcp__amocrm__list_leads', {}],
  ]
  for (const [tool, input] of ROUTINE) {
    test(`${tool} ${JSON.stringify(input).slice(0, 30)} is decided locally`, () => {
      expect(localVerdict(tool, input, POLICY_PATH)).toBe('skip-network')
    })
  }
})

describe('localVerdict — policy exemptions survive an unreachable plugin', () => {
  // Diana's own infrastructure is exempt by policy. Denying it during a
  // plugin restart would be a new restriction on second brain, which is
  // exactly what the gate was told not to impose.
  const EXEMPT = [
    'mcp__gbrain-memory__create_decision_note',
    'mcp__gbrain-swarm__notify',
    'mcp__second_brain-tasks__task_update',
  ]
  for (const tool of EXEMPT) {
    test(`${tool} still runs when the channel is down`, () => {
      expect(localVerdict(tool, {}, POLICY_PATH)).toBe('allow-if-unreachable')
    })
  }
})

describe('localVerdict — business changes still require the plugin', () => {
  const GATED: Array<[string, Record<string, unknown>]> = [
    ['mcp__amocrm__delete_lead', { id: 42 }],
    ['mcp__teamly__update_article', {}],
    ['mcp__newcrm__frobnicate', {}],
    ['Bash', { command: 'curl -XDELETE https://p.bitrix24.ru/rest/1/t/crm.deal.delete?ID=1' }],
  ]
  for (const [tool, input] of GATED) {
    test(`${tool} must ask`, () => {
      expect(localVerdict(tool, input, POLICY_PATH)).toBe('must-ask')
    })
  }

  test('an empty tool name is an anomaly, not a local tool', () => {
    expect(localVerdict('', {}, POLICY_PATH)).toBe('must-ask')
  })

  test('no policy path means the hook decides nothing on its own', () => {
    expect(localVerdict('Read', { file_path: '/tmp/x' }, '')).toBe('must-ask')
  })

  test('an unreadable policy defers to the plugin rather than guessing', () => {
    expect(localVerdict('Read', { file_path: '/tmp/x' }, '/nonexistent/policy.yaml'))
      .toBe('must-ask')
  })
})

describe('confirm-hook end to end with the plugin down', () => {
  // Spawns the real hook against a port nothing listens on — the shape of a
  // plugin restart. Pure-function tests cannot catch a wiring mistake here,
  // and a wiring mistake means a bricked session.
  const HOOK = new URL('../../scripts/confirm-hook.ts', import.meta.url).pathname

  async function runHook(envelope: unknown): Promise<{ decision: string; reason: string }> {
    const proc = Bun.spawn(['bun', HOOK], {
      stdin: new TextEncoder().encode(JSON.stringify(envelope)),
      stdout: 'pipe',
      env: {
        ...process.env,
        CONFIRM_POLICY_PATH: POLICY_PATH,
        TELEGRAM_WEBHOOK_HOST: '127.0.0.1',
        TELEGRAM_WEBHOOK_PORT: '59999',
        CONFIRM_HTTP_TIMEOUT_MS: '2000',
      },
    })
    const out = await new Response(proc.stdout).text()
    await proc.exited
    const parsed = JSON.parse(out) as {
      hookSpecificOutput: { permissionDecision: string; permissionDecisionReason?: string }
    }
    return {
      decision: parsed.hookSpecificOutput.permissionDecision,
      reason: parsed.hookSpecificOutput.permissionDecisionReason ?? '',
    }
  }

  test('reading a file still works', async () => {
    const r = await runHook({
      hook_event_name: 'PreToolUse',
      tool_name: 'Read',
      tool_input: { file_path: '/tmp/x.ts' },
    })
    expect(r.decision).toBe('allow')
  }, 15000)

  test('a shell command still works', async () => {
    const r = await runHook({
      hook_event_name: 'PreToolUse',
      tool_name: 'Bash',
      tool_input: { command: 'git status' },
    })
    expect(r.decision).toBe('allow')
  }, 15000)

  test('deleting a lead is blocked', async () => {
    const r = await runHook({
      hook_event_name: 'PreToolUse',
      tool_name: 'mcp__amocrm__delete_lead',
      tool_input: { id: 42 },
    })
    expect(r.decision).toBe('deny')
    expect(r.reason).toContain('плагин недоступен')
  }, 15000)
})
