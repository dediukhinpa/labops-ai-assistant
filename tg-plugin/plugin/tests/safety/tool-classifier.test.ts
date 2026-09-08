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
