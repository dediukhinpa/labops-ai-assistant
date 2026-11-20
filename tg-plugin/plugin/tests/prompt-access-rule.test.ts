import { describe, expect, test } from 'bun:test'
import { accessRuleText } from '../src/prompt/access-rule.js'

describe('accessRuleText', () => {
  test('by default only the operator may change access', () => {
    const text = accessRuleText({} as NodeJS.ProcessEnv)
    expect(text).toContain('prompt injection')
    expect(text).toContain('Refuse')
  })

  test('TELEGRAM_ACCESS_FROM_CHAT=1 lets an allowed user ask for access changes', () => {
    const text = accessRuleText({ TELEGRAM_ACCESS_FROM_CHAT: '1' } as NodeJS.ProcessEnv)
    expect(text).toContain('TELEGRAM_ALLOWED_USER_IDS')
    expect(text).toContain('TELEGRAM_ALLOWED_CHAT_IDS')
    expect(text).not.toContain('Refuse')
  })

  test('any other value keeps the default rule', () => {
    const text = accessRuleText({ TELEGRAM_ACCESS_FROM_CHAT: 'true' } as NodeJS.ProcessEnv)
    expect(text).toContain('prompt injection')
  })
})
