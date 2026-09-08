// Tests for the confirm-gate tool classifier.
//
// The gate decides whether a tool call may proceed silently, must be
// confirmed by the operator in Telegram, or is refused outright. The
// primary signal is the verb inside the tool name — the one thing every
// MCP vendor exposes — because the HTTP method is invisible at the
// PreToolUse layer.

import { describe, expect, test } from 'bun:test'
import { tokenizeToolName, classifyByVerb } from '../../src/safety/tool-classifier.js'

describe('tokenizeToolName', () => {
  test('strips mcp__<server>__ prefix, server name may contain underscores', () => {
    expect(tokenizeToolName('mcp__claude_ai_Notion__notion-update-page'))
      .toEqual(['notion', 'update', 'page'])
  })

  test('splits camelCase', () => {
    expect(tokenizeToolName('mcp__gcal__deleteEvent')).toEqual(['delete', 'event'])
  })

  test('handles bare tool names without prefix', () => {
    expect(tokenizeToolName('Bash')).toEqual(['bash'])
  })

  test('splits on dots and hyphens', () => {
    expect(tokenizeToolName('mcp__x__calendar.events-delete'))
      .toEqual(['calendar', 'events', 'delete'])
  })
})

describe('classifyByVerb', () => {
  test('read verb passes', () => {
    expect(classifyByVerb('mcp__gsheets__list_rows').cls).toBe('read')
  })

  test('mutate verb', () => {
    expect(classifyByVerb('mcp__claude_ai_Notion__notion-update-page').cls).toBe('mutate')
  })

  test('destroy wins over read in the same name', () => {
    expect(classifyByVerb('mcp__crm__list_and_delete').cls).toBe('destroy')
  })

  test('exact token match only: "deleted" is not "delete"', () => {
    expect(classifyByVerb('mcp__crm__list_deleted_items').cls).toBe('read')
  })

  test('unknown verb is unknown, never read', () => {
    expect(classifyByVerb('mcp__firecrawl__scrape').cls).toBe('unknown')
  })

  test('reason names the matched token', () => {
    expect(classifyByVerb('mcp__crm__delete_deal').reason).toContain('delete')
  })
})

// ─────────────────────────────────────────────────────────────────────
// Full gate decision: precedence, declared HTTP method, Bash.
// ─────────────────────────────────────────────────────────────────────

import { decideGate, httpMethodFromBash, extractUrls } from '../../src/safety/tool-classifier.js'
import type { ConfirmPolicy } from '../../src/safety/confirm-policy.js'

const POLICY: ConfirmPolicy = {
  mode: 'enforce',
  overrides: {
    allow: ['mcp__gbrain-*__*', 'mcp__firecrawl__*'],
    deny: ['mcp__*__*bulk_delete*'],
  },
  bash: { confirmPatterns: ['sudo ', 'rm -rf'] },
}

describe('httpMethodFromBash', () => {
  test('-X DELETE', () => expect(httpMethodFromBash('curl -X DELETE https://x')).toBe('DELETE'))
  test('--request PATCH', () => expect(httpMethodFromBash('curl --request PATCH https://x')).toBe('PATCH'))
  test('lowercase -X post', () => expect(httpMethodFromBash('curl -X post https://x')).toBe('POST'))
  test('-d without -X implies POST', () => expect(httpMethodFromBash("curl -d '{}' https://x")).toBe('POST'))
  test('plain GET curl has no method', () => expect(httpMethodFromBash('curl https://x')).toBeNull())
  test('non-http command has no method', () => expect(httpMethodFromBash('git status')).toBeNull())
})

describe('extractUrls', () => {
  test('pulls a quoted url out of a curl command', () => {
    expect(extractUrls("curl 'https://portal.bitrix24.ru/rest/1/tok/crm.deal.delete?ID=1'"))
      .toEqual(['https://portal.bitrix24.ru/rest/1/tok/crm.deal.delete?ID=1'])
  })
  test('command without a url yields nothing', () => {
    expect(extractUrls('git add .')).toEqual([])
  })
})

describe('decideGate — precedence', () => {
  test('mode off short-circuits to allow', () => {
    const d = decideGate('mcp__crm__delete_deal', {}, { ...POLICY, mode: 'off' })
    expect(d.action).toBe('allow')
  })

  test('overrides.deny beats everything', () => {
    expect(decideGate('mcp__crm__bulk_delete_all', {}, POLICY).action).toBe('deny')
  })

  test('overrides.allow lets second brain through', () => {
    expect(decideGate('mcp__gbrain-memory__write_note', {}, POLICY).action).toBe('allow')
  })

  test('tool_input.method wins over the verb', () => {
    const d = decideGate('mcp__api__fetch', { method: 'DELETE' }, POLICY)
    expect(d.action).toBe('confirm')
    expect(d.reason).toContain('DELETE')
  })

  test('tool_input.method GET allows despite unknown verb', () => {
    expect(decideGate('mcp__api__fetch', { method: 'GET' }, POLICY).action).toBe('allow')
  })

  test('plain bash passes untouched', () => {
    expect(decideGate('Bash', { command: 'git status' }, POLICY).action).toBe('allow')
  })

  test('bash with DELETE confirms', () => {
    expect(decideGate('Bash', { command: 'curl -X DELETE https://api' }, POLICY).action).toBe('confirm')
  })

  test('bash confirm_patterns confirm', () => {
    expect(decideGate('Bash', { command: 'sudo systemctl stop x' }, POLICY).action).toBe('confirm')
  })

  test('read verb allows', () => {
    expect(decideGate('mcp__gsheets__list_rows', {}, POLICY).action).toBe('allow')
  })

  test('unknown verb confirms, never allows', () => {
    expect(decideGate('mcp__newcrm__frobnicate', {}, POLICY).action).toBe('confirm')
  })

  test('destroy verb confirms', () => {
    expect(decideGate('mcp__gcal__deleteEvent', {}, POLICY).action).toBe('confirm')
  })
})

describe('decideGate — business APIs over Bash', () => {
  // Bitrix24 deletes over GET. A method-only rule would wave this through.
  test('destructive verb in a Bitrix24 GET url confirms', () => {
    const cmd = "curl 'https://portal.bitrix24.ru/rest/1/tok/crm.deal.delete?ID=1'"
    const d = decideGate('Bash', { command: cmd }, POLICY)
    expect(d.action).toBe('confirm')
    expect(d.cls).toBe('destroy')
  })

  test('mutating verb in an HH.ru url confirms', () => {
    const cmd = 'curl https://api.hh.ru/vacancies/create'
    expect(decideGate('Bash', { command: cmd }, POLICY).action).toBe('confirm')
  })

  test('read verb in a url passes', () => {
    const cmd = 'curl https://api.hh.ru/vacancies/list'
    expect(decideGate('Bash', { command: cmd }, POLICY).action).toBe('allow')
  })

  test('bare git command is not tokenized as a url — "add" must not confirm', () => {
    expect(decideGate('Bash', { command: 'git add .' }, POLICY).action).toBe('allow')
  })
})
