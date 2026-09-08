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
