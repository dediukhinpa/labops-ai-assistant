// Multichat на харнесе Codex закрыт: только личка операторов, чужая личка и группы — мимо.

import { describe, expect, test } from 'bun:test'
import { existsSync, mkdtempSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'
import { Writable } from 'stream'

import type { AppConfig } from '../../src/config.js'
import { createLogger } from '../../src/log.js'
import {
  codexMultichatVerdict,
  createCodexMultichatGuard,
  OPERATOR_NOTICE_INTERVAL_MS,
  warnOperatorsCodexMultichat,
  type GuardContext,
} from '../../src/harness/codex/multichat-guard.js'

const OPERATOR = 111
const OTHER = 222

function config(over: Partial<{ operator_user_ids: number[]; allowed_user_ids: number[] }> = {}): AppConfig {
  return {
    allowed_user_ids: over.allowed_user_ids ?? [OPERATOR, OTHER],
    ...(over.operator_user_ids !== undefined ? { operator_user_ids: over.operator_user_ids } : {}),
  } as unknown as AppConfig
}

function recordingLog(): { log: ReturnType<typeof createLogger>; lines: () => string[] } {
  const chunks: string[] = []
  const log = createLogger('test', {
    stream: new Writable({
      write: (c, _e, cb) => {
        chunks.push(String(c))
        cb()
      },
    }),
  })
  return { log, lines: () => chunks.join('').split('\n').filter(Boolean) }
}

function dm(from: number): GuardContext {
  return { message: { chat: { id: from, type: 'private' }, from: { id: from } } }
}

describe('codexMultichatVerdict', () => {
  const cfg = config({ operator_user_ids: [OPERATOR] })
  test('личка оператора проходит', () => {
    expect(codexMultichatVerdict(cfg, { chatType: 'private', chatId: '111', senderId: '111' })).toBe('pass')
  })
  test('личка разрешённого не-оператора отбрасывается', () => {
    expect(codexMultichatVerdict(cfg, { chatType: 'private', chatId: '222', senderId: '222' })).toBe('drop_dm')
  })
  test('группа отбрасывается, даже от оператора', () => {
    expect(codexMultichatVerdict(cfg, { chatType: 'supergroup', chatId: '-100', senderId: '111' })).toBe('drop_group')
  })
  test('чужак не из allowlist — дальше в gate (он и так отбросит)', () => {
    expect(codexMultichatVerdict(cfg, { chatType: 'private', chatId: '9', senderId: '9' })).toBe('pass')
  })
  test('без operator_user_ids операторы — allowed_user_ids (как resolveCodexOperatorUserIds)', () => {
    expect(codexMultichatVerdict(config(), { chatType: 'private', chatId: '222', senderId: '222' })).toBe('pass')
  })
})

describe('middleware', () => {
  test('оператор доходит до обработчиков; чужая личка и группа — нет, с log.error', async () => {
    const { log, lines } = recordingLog()
    const guard = createCodexMultichatGuard(config({ operator_user_ids: [OPERATOR] }), log)
    let passed = 0
    const next = async (): Promise<void> => void (passed += 1)
    await guard(dm(OPERATOR), next)
    await guard(dm(OTHER), next)
    await guard({ message: { chat: { id: -100, type: 'group' }, from: { id: OPERATOR } } }, next)
    await guard({}, next)
    expect(passed).toBe(2)
    const errors = lines().filter(l => l.includes('codex.multichat_refused'))
    expect(errors).toHaveLength(2)
    expect(errors.every(l => l.includes('[error]'))).toBe(true)
  })

  test('одна и та же группа не засоряет журнал', async () => {
    const { log, lines } = recordingLog()
    let clock = 0
    const guard = createCodexMultichatGuard(config(), log, () => clock)
    const group: GuardContext = { message: { chat: { id: -5, type: 'group' }, from: { id: OTHER } } }
    for (let i = 0; i < 5; i++) await guard(group, async () => undefined)
    expect(lines().filter(l => l.includes('multichat_refused'))).toHaveLength(1)
  })
})

describe('предупреждение операторам', () => {
  test('уходит каждому оператору, повтор в пределах суток подавлен', async () => {
    const { log } = recordingLog()
    const markerPath = join(mkdtempSync(join(tmpdir(), 'codex-mc-')), 'notice')
    const sent: string[] = []
    let clock = 1_000
    const opts = {
      config: config({ operator_user_ids: [OPERATOR, 333] }),
      send: async (chatId: string) => void sent.push(chatId),
      log,
      markerPath,
      now: () => clock,
    }
    expect(await warnOperatorsCodexMultichat(opts)).toBe(2)
    expect(sent).toEqual(['111', '333'])
    expect(existsSync(markerPath)).toBe(true)
    expect(await warnOperatorsCodexMultichat(opts)).toBe(0)
    clock += OPERATOR_NOTICE_INTERVAL_MS
    expect(await warnOperatorsCodexMultichat(opts)).toBe(2)
  })
})
