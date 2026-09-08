// Tests for the confirm-gate Telegram card.
//
// The card reuses the visual shape of the permission relay (See more /
// Allow / Deny) but lives in its own `confirm:` callback namespace, so a
// tap on one relay can never be consumed by the other.

import { describe, expect, test } from 'bun:test'
import {
  renderConfirmCard, renderConfirmDetails, parseConfirmCallback, reasonInRussian,
  newConfirmId, shortPreview,
} from '../../src/telegram/confirm-card.js'
import { redactSecrets } from '../../src/safety/redact.js'
import type { GateDecision } from '../../src/safety/tool-classifier.js'

const DESTROY: GateDecision = {
  action: 'confirm',
  reason: 'destructive verb "delete"',
  cls: 'destroy',
  code: 'verb-destroy',
  detail: 'delete',
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

// ─────────────────────────────────────────────────────────────────────
// The card is client-facing. Two invariants that a rendered demo caught
// only after the code was already written:
//   1. the reason line must be Russian, not the English audit string;
//   2. the "Подробнее" view prints tool_input verbatim, so whatever sends
//      it must redact first — that view routinely carries a REST URL with
//      a webhook token in the path.
// ─────────────────────────────────────────────────────────────────────

describe('reasonInRussian', () => {
  test('destructive verb reads as Russian prose, not the audit string', () => {
    const line = reasonInRussian(DESTROY)
    expect(line).toBe('в имени инструмента разрушающий глагол «delete»')
    expect(line).not.toContain('destructive verb')
  })

  test('a verb found in the URL says so, and keeps the destroy wording', () => {
    expect(reasonInRussian({
      action: 'confirm', reason: 'url destructive verb "delete"', cls: 'destroy',
      code: 'url-verb', detail: 'delete',
    })).toBe('в адресе запроса разрушающий глагол «delete»')
  })

  test('an unknown verb explains why it is asking at all', () => {
    expect(reasonInRussian({
      action: 'confirm', reason: 'no known verb in tool name', cls: 'unknown',
      code: 'verb-unknown', detail: '',
    })).toBe('глагол не распознан — по умолчанию спрашиваем')
  })

  test('every reason code that can reach a card renders without Latin leftovers', () => {
    const cases: GateDecision[] = [
      { action: 'confirm', reason: '', cls: 'mutate', code: 'verb-mutate', detail: 'update' },
      { action: 'confirm', reason: '', cls: 'mutate', code: 'http-method', detail: 'PATCH' },
      { action: 'confirm', reason: '', cls: 'destroy', code: 'bash-http-method', detail: 'DELETE' },
      { action: 'confirm', reason: '', cls: 'mutate', code: 'bash-pattern', detail: 'confirm-policy.yaml' },
      { action: 'confirm', reason: '', cls: 'mutate', code: 'protected-file', detail: 'settings.json' },
      { action: 'deny', reason: '', cls: 'destroy', code: 'override-deny', detail: 'mcp__x__drop_*' },
    ]
    for (const c of cases) {
      const line = reasonInRussian(c)
      // Strip the detail (a tool name / method / filename is legitimately
      // Latin); what remains must be Russian.
      const prose = line.replaceAll(c.detail, '')
      expect(prose).toMatch(/[а-яА-ЯёЁ]/)
      expect(prose).not.toMatch(/[a-z]{4,}/)
    }
  })
})

describe('details view redaction wiring', () => {
  test('server.ts redacts the details text before editMessageText', async () => {
    // A source-level guard, deliberately. The renderer is pure and cannot
    // know about secrets; the only place the invariant lives is the call
    // site. If someone drops the redactSecrets call, this fails loudly
    // rather than shipping a webhook token to Telegram.
    const src = await Bun.file(new URL('../../src/server.ts', import.meta.url)).text()
    const branch = src.slice(src.indexOf('const confirmTap = parseConfirmCallback'))
    const upToEdit = branch.slice(0, branch.indexOf('await ctx.editMessageText'))
    expect(upToEdit).toContain('redactSecrets(details.text, apiSecrets)')
  })

  test('redaction survives the details rendering shape', () => {
    const cmd = JSON.stringify({
      command: "curl 'https://portal.example.ru/rest/1/s3cr3tw3bh00kc0d3v4lu3xyz/crm.deal.delete?ID=1'",
    })
    const rendered = renderConfirmDetails('Bash', DESTROY, cmd, 'abcde')
    expect(redactSecrets(rendered.text)).not.toContain('s3cr3tw3bh00kc0d3v4lu3xyz')
  })
})

describe('newConfirmId', () => {
  test('5 chars from the unambiguous alphabet, never the letter l', () => {
    for (let i = 0; i < 200; i += 1) {
      const id = newConfirmId()
      expect(id).toMatch(/^[a-km-z]{5}$/)
    }
  })

  test('ids do not repeat across a large sample', () => {
    const seen = new Set<string>()
    for (let i = 0; i < 500; i += 1) seen.add(newConfirmId())
    // 9.7M space, 500 draws — a collision here would mean a broken generator.
    expect(seen.size).toBeGreaterThan(495)
  })
})

describe('shortPreview', () => {
  test('empty input yields no preview line', () => {
    expect(shortPreview('{}')).toBe('')
    expect(shortPreview('')).toBe('')
  })

  test('collapses whitespace and clips long arguments', () => {
    const long = JSON.stringify({ note: 'x'.repeat(400) })
    const out = shortPreview(long)
    expect(out.length).toBeLessThanOrEqual(161)
    expect(out.endsWith('…')).toBe(true)
  })

  test('the first card shows what is being changed, not just the tool', () => {
    const c = renderConfirmCard('mcp__crm__delete_deal', DESTROY, '{"deal_id":84512}')
    expect(c.text).toContain('84512')
  })

  test('a call with no arguments has no empty аргументы line', () => {
    const c = renderConfirmCard('mcp__crm__purge_all', DESTROY, '{}')
    expect(c.text).not.toContain('аргументы')
  })
})
