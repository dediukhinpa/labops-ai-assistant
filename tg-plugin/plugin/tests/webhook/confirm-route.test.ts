// Tests for the pending-confirmation registry.
//
// One entry per held tool call: the HTTP handler awaits `wait`, the
// Telegram callback calls `settle`. The timeout MUST resolve to 'deny' —
// a confirmation nobody answered is not a confirmation.

import { describe, expect, test } from 'bun:test'
import { createConfirmRegistry } from '../../src/webhook/confirm-route.js'
import type { GateDecision } from '../../src/safety/tool-classifier.js'

const D: GateDecision = {
  action: 'confirm',
  reason: 'destructive verb "delete"',
  cls: 'destroy',
  code: 'verb-destroy',
  detail: 'delete',
}

describe('createConfirmRegistry', () => {
  test('settle(allow) resolves the waiter', async () => {
    const reg = createConfirmRegistry(5000)
    const { requestId, wait } = reg.create('mcp__crm__delete_deal', D, '{}')
    expect(reg.settle(requestId, 'allow')).toBe(true)
    expect(await wait).toBe('allow')
  })

  test('settle(deny) resolves deny', async () => {
    const reg = createConfirmRegistry(5000)
    const { requestId, wait } = reg.create('mcp__crm__delete_deal', D, '{}')
    reg.settle(requestId, 'deny')
    expect(await wait).toBe('deny')
  })

  test('timeout resolves deny, never allow', async () => {
    const reg = createConfirmRegistry(30)
    const { wait } = reg.create('mcp__crm__delete_deal', D, '{}')
    expect(await wait).toBe('deny')
  })

  test('settling twice is a no-op', async () => {
    const reg = createConfirmRegistry(5000)
    const { requestId, wait } = reg.create('mcp__crm__delete_deal', D, '{}')
    expect(reg.settle(requestId, 'allow')).toBe(true)
    expect(reg.settle(requestId, 'deny')).toBe(false)
    expect(await wait).toBe('allow')
  })

  test('unknown id cannot be settled', () => {
    const reg = createConfirmRegistry(5000)
    expect(reg.settle('zzzzz', 'allow')).toBe(false)
  })

  test('entry is retrievable for the "more" button until settled', () => {
    const reg = createConfirmRegistry(5000)
    const { requestId } = reg.create('mcp__crm__delete_deal', D, '{"id":42}')
    expect(reg.get(requestId)?.inputPreview).toBe('{"id":42}')
    reg.settle(requestId, 'deny')
    expect(reg.get(requestId)).toBeUndefined()
  })
})
