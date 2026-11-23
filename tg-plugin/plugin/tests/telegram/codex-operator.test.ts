// Адресат ответов на задачи и кнопок вопросов у агента на Codex — оператор, не канарейка.
import { afterEach, beforeEach, describe, expect, test } from 'bun:test'
import { mkdtempSync, rmSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'

import { loadConfig, resolveAskUserQuestionAllowedUserIds } from '../../src/config.js'
import {
  resolveCodexOperatorUserIds,
  resolveOperatorUserIds,
  withCodexAskRecipients,
} from '../../src/telegram/dm-routing.js'

const CANARY = 100000001
const OPERATOR = 424242
const FAKE_TOKEN = '123456789:AAH-fake_test_token_with_at_least_thirty_chars'

let stateDir: string
beforeEach(() => {
  stateDir = mkdtempSync(join(tmpdir(), 'labops-codex-operator-'))
})
afterEach(() => {
  rmSync(stateDir, { recursive: true, force: true })
})

function env(overrides: Record<string, string>): NodeJS.ProcessEnv {
  return { TELEGRAM_BOT_TOKEN: FAKE_TOKEN, TELEGRAM_STATE_DIR: stateDir, ...overrides }
}

describe('resolveCodexOperatorUserIds', () => {
  test('установка задаёт только TELEGRAM_ALLOWED_USER_IDS — оператор из него', () => {
    const config = loadConfig(env({ TELEGRAM_ALLOWED_USER_IDS: `${OPERATOR},555` }))
    // Прежний источник давал канарейку — так ответы на задачи и уходили в никуда.
    expect(resolveAskUserQuestionAllowedUserIds(config)[0]).toBe(CANARY)
    expect(resolveCodexOperatorUserIds(config)[0]).toBe(OPERATOR)
  })

  test('явный operator_user_ids главнее allowed_user_ids', () => {
    const config = loadConfig(env({
      TELEGRAM_ALLOWED_USER_IDS: '555',
      TELEGRAM_OPERATOR_USER_IDS: String(OPERATOR),
    }))
    expect(resolveCodexOperatorUserIds(config)).toEqual([OPERATOR])
  })

  test('правила Claude Code не меняются', () => {
    const config = loadConfig(env({ TELEGRAM_ALLOWED_USER_IDS: String(OPERATOR) }))
    expect(resolveOperatorUserIds(config)).toEqual([CANARY])
  })
})

describe('withCodexAskRecipients', () => {
  test('без явного списка на вопросы отвечает оператор', () => {
    const config = loadConfig(env({ TELEGRAM_ALLOWED_USER_IDS: String(OPERATOR) }))
    expect(resolveAskUserQuestionAllowedUserIds(withCodexAskRecipients(config))).toEqual([OPERATOR])
    // Исходный конфиг не тронут.
    expect(resolveAskUserQuestionAllowedUserIds(config)).toEqual([CANARY])
  })

  test('явный ask_user_question.allowed_user_ids сохраняется', () => {
    const config = loadConfig(env({
      TELEGRAM_ALLOWED_USER_IDS: String(OPERATOR),
      TELEGRAM_ASK_USER_QUESTION_ALLOWED_USER_IDS: '777',
    }))
    expect(withCodexAskRecipients(config)).toBe(config)
  })
})
