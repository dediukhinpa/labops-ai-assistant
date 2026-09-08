// Tests for the confirm-gate Telegram card.
//
// The card reuses the visual shape of the permission relay (See more /
// Allow / Deny) but lives in its own `confirm:` callback namespace, so a
// tap on one relay can never be consumed by the other.

import { describe, expect, test } from 'bun:test'
import { renderConfirmCard, parseConfirmCallback } from '../../src/telegram/confirm-card.js'
import type { GateDecision } from '../../src/safety/tool-classifier.js'

const DESTROY: GateDecision = {
  action: 'confirm',
  reason: 'destructive verb "delete"',
  cls: 'destroy',
}

describe('renderConfirmCard', () => {
  test('names the tool and the reason', () => {
    const c = renderConfirmCard('mcp__crm__delete_deal', DESTROY, '{"id":42}')
    expect(c.text).toContain('mcp__crm__delete_deal')
    expect(c.text).toContain('delete')
  })

  test('keyboard carries confirm/deny/more callbacks', () => {
    const c = renderConfirmCard('mcp__crm__delete_deal', DESTROY, '{}')
    const data = c.replyMarkup.inline_keyboard.flat().map(b => b.callback_data)
    expect(data.some(d => d?.startsWith('confirm:allow:'))).toBe(true)
    expect(data.some(d => d?.startsWith('confirm:deny:'))).toBe(true)
    expect(data.some(d => d?.startsWith('confirm:more:'))).toBe(true)
  })

  test('callback ids match the returned requestId', () => {
    const c = renderConfirmCard('mcp__crm__delete_deal', DESTROY, '{}')
    expect(c.replyMarkup.inline_keyboard[0]?.[1]?.callback_data)
      .toBe(`confirm:allow:${c.requestId}`)
  })

  test('escapes HTML in the tool name', () => {
    const c = renderConfirmCard('mcp__x__<b>evil</b>', DESTROY, '{}')
    expect(c.text).not.toContain('<b>evil')
  })
})

describe('parseConfirmCallback', () => {
  test('parses allow', () => {
    expect(parseConfirmCallback('confirm:allow:abcde'))
      .toEqual({ behavior: 'allow', requestId: 'abcde' })
  })
  test('rejects the permission relay namespace', () => {
    expect(parseConfirmCallback('perm:allow:abcde')).toBeNull()
  })
  test('rejects a malformed id', () => {
    expect(parseConfirmCallback('confirm:allow:TOOLONGID')).toBeNull()
  })
})

describe('renderConfirmDetails', () => {
  test('pretty-prints the arguments so the operator sees WHAT changes', async () => {
    const { renderConfirmDetails } = await import('../../src/telegram/confirm-card.js')
    const d = renderConfirmDetails('mcp__crm__delete_deal', DESTROY, '{"id":42}', 'abcde')
    expect(d.text).toContain('"id": 42')
  })

  test('falls back to the raw preview when it is not JSON', async () => {
    const { renderConfirmDetails } = await import('../../src/telegram/confirm-card.js')
    const d = renderConfirmDetails('mcp__crm__delete_deal', DESTROY, 'not json', 'abcde')
    expect(d.text).toContain('not json')
  })

  test('clips an oversized preview to stay under the Telegram limit', async () => {
    const { renderConfirmDetails } = await import('../../src/telegram/confirm-card.js')
    const huge = JSON.stringify({ blob: 'x'.repeat(9000) })
    const d = renderConfirmDetails('mcp__crm__delete_deal', DESTROY, huge, 'abcde')
    expect(d.text.length).toBeLessThan(4096)
  })

  test('drops the "more" button — details are already expanded', async () => {
    const { renderConfirmDetails } = await import('../../src/telegram/confirm-card.js')
    const d = renderConfirmDetails('mcp__crm__delete_deal', DESTROY, '{}', 'abcde')
    const data = d.replyMarkup.inline_keyboard.flat().map(b => b.callback_data)
    expect(data.some(x => x?.startsWith('confirm:more:'))).toBe(false)
  })
})
