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
