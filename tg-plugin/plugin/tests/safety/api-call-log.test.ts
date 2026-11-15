// Тесты журнала вызовов Bot API: запись, отсутствие текста и токена, схлопывание
// пропусков, ротация по размеру и устойчивость к сбоям записи.

import { afterEach, beforeEach, describe, expect, test } from 'bun:test'
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import type { TelegramApi } from '../../src/channel/tools.js'
import type { Logger } from '../../src/log.js'
import { createApiCallLog } from '../../src/safety/api-call-log.js'
import { createLoggedTelegramApi } from '../../src/safety/logged-telegram-api.js'

const MS_PER_MINUTE = 60_000
const FAKE_TOKEN = '123456789:AAH-fake_test_token_with_at_least_thirty_chars'
const SECRET_TEXT = 'сверхсекретный текст сообщения 4111-1111-1111-1111'
const CHAT = '-1001234567890'

let dir: string
let path: string

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'labops-bot-api-log-'))
  path = join(dir, 'logs', 'bot-api.jsonl')
})

afterEach(() => {
  rmSync(dir, { recursive: true, force: true })
})

function lines(file: string = path): Array<Record<string, unknown>> {
  return readFileSync(file, 'utf8')
    .split('\n')
    .filter((l) => l !== '')
    .map((l) => JSON.parse(l) as Record<string, unknown>)
}

class Clock {
  t = Date.UTC(2026, 10, 15, 12, 0, 5)
  now = (): number => this.t
}

const warnings: string[] = []
const spyLog: Logger = {
  debug() {},
  info() {},
  warn(msg) {
    warnings.push(msg)
  },
  error() {},
}

describe('createApiCallLog - запись', () => {
  test('пишет строку JSON с нужными полями и создаёт каталог', () => {
    const clock = new Clock()
    const journal = createApiCallLog({ path, now: clock.now })
    journal.record({
      method: 'sendMessage',
      chatId: CHAT,
      category: 'critical',
      result: 'ok',
      durationMs: 123.6,
    })
    journal.record({
      method: 'editMessageText',
      chatId: CHAT,
      category: 'background',
      result: 'http_429',
      durationMs: 40,
      retryAfterSec: 41698,
    })
    const rows = lines()
    expect(rows).toEqual([
      {
        ts: '2026-11-15T12:00:05.000Z',
        method: 'sendMessage',
        chat_id: CHAT,
        category: 'critical',
        result: 'ok',
        duration_ms: 124,
      },
      {
        ts: '2026-11-15T12:00:05.000Z',
        method: 'editMessageText',
        chat_id: CHAT,
        category: 'background',
        result: 'http_429',
        duration_ms: 40,
        retry_after: 41698,
      },
    ])
    expect(statSync(path).mode & 0o777).toBe(0o600)
  })

  test('chat_id с посторонним текстом заменяется заглушкой', () => {
    const journal = createApiCallLog({ path })
    journal.record({
      method: 'sendMessage',
      chatId: SECRET_TEXT,
      category: 'critical',
      result: 'ok',
      durationMs: 1,
    })
    expect(lines()[0]?.chat_id).toBe('<invalid>')
    expect(readFileSync(path, 'utf8')).not.toContain('сверхсекретный')
  })
})

describe('createApiCallLog - пропуски схлопываются раз в минуту', () => {
  test('счётчик на ключ, строка появляется после смены минуты', () => {
    const clock = new Clock()
    const journal = createApiCallLog({ path, now: clock.now })
    for (let i = 0; i < 50; i += 1) {
      journal.recordSkip('sendChatAction', CHAT, 'background', 'skipped_throttled')
    }
    journal.recordSkip('editMessageText', CHAT, 'background', 'skipped_banned')
    // Минута ещё не закончилась: в файле пусто.
    expect(existsSync(path)).toBe(false)

    clock.t += MS_PER_MINUTE
    journal.record({
      method: 'sendMessage',
      chatId: CHAT,
      category: 'critical',
      result: 'ok',
      durationMs: 1,
    })
    const rows = lines()
    const typing = rows.find((r) => r.method === 'sendChatAction')
    expect(typing).toMatchObject({
      ts: '2026-11-15T12:00:00.000Z',
      chat_id: CHAT,
      category: 'background',
      result: 'skipped_throttled',
      count: 50,
      duration_ms: 0,
    })
    expect(rows.find((r) => r.method === 'editMessageText')).toMatchObject({
      result: 'skipped_banned',
      count: 1,
    })
    expect(rows.length).toBe(3)
  })

  test('flush() сбрасывает текущие счётчики немедленно', () => {
    const journal = createApiCallLog({ path, now: new Clock().now })
    journal.recordSkip('sendChatAction', CHAT, 'background', 'skipped_throttled')
    journal.recordSkip('sendChatAction', CHAT, 'background', 'skipped_throttled')
    journal.flush()
    expect(lines()).toHaveLength(1)
    expect(lines()[0]).toMatchObject({ count: 2 })
    journal.flush()
    expect(lines()).toHaveLength(1)
  })
})

describe('createApiCallLog - ротация', () => {
  test('по размеру: основной + .1 + .2, старше удаляется', () => {
    const journal = createApiCallLog({ path, maxBytes: 600, maxFiles: 3, now: new Clock().now })
    for (let i = 0; i < 40; i += 1) {
      journal.record({
        method: 'sendMessage',
        chatId: CHAT,
        category: 'critical',
        result: 'ok',
        durationMs: i,
      })
    }
    const files = readdirSync(join(dir, 'logs')).sort()
    expect(files).toEqual(['bot-api.jsonl', 'bot-api.jsonl.1', 'bot-api.jsonl.2'])
    for (const f of files) {
      expect(statSync(join(dir, 'logs', f)).size).toBeLessThanOrEqual(600)
    }
    // Последняя запись в основном файле, порядок между файлами сохраняется.
    const newest = lines()
    expect(newest[newest.length - 1]?.duration_ms).toBe(39)
    const older = lines(`${path}.1`)
    expect(older[older.length - 1]?.duration_ms as number).toBeLessThan(
      newest[0]?.duration_ms as number,
    )
  })

  test('продолжает с учётом размера существующего файла после рестарта', () => {
    mkdirSync(join(dir, 'logs'), { recursive: true })
    writeFileSync(path, `${'x'.repeat(590)}\n`)
    const journal = createApiCallLog({ path, maxBytes: 600, maxFiles: 2, now: new Clock().now })
    journal.record({
      method: 'sendMessage',
      chatId: CHAT,
      category: 'critical',
      result: 'ok',
      durationMs: 1,
    })
    expect(existsSync(`${path}.1`)).toBe(true)
    expect(lines()).toHaveLength(1)
  })
})

describe('createApiCallLog - сбой записи не ломает вызов', () => {
  test('путь занят каталогом: record/recordSkip/flush не бросают', () => {
    mkdirSync(path, { recursive: true }) // bot-api.jsonl - каталог, appendFileSync упадёт
    warnings.length = 0
    const journal = createApiCallLog({ path, log: spyLog, now: new Clock().now })
    expect(() =>
      journal.record({
        method: 'sendMessage',
        chatId: CHAT,
        category: 'critical',
        result: 'ok',
        durationMs: 1,
      }),
    ).not.toThrow()
    journal.recordSkip('sendChatAction', CHAT, 'background', 'skipped_banned')
    expect(() => journal.flush()).not.toThrow()
    expect(warnings.length).toBeGreaterThan(0)
  })

  test('каталог журнала - обычный файл: записи теряются, вызов Telegram идёт', async () => {
    writeFileSync(join(dir, 'logs'), 'не каталог')
    const journal = createApiCallLog({ path, log: spyLog, now: new Clock().now })
    const api = createLoggedTelegramApi(stubApi(), journal, 'critical')
    const sent = await api.sendMessage(CHAT, SECRET_TEXT, {})
    expect(sent.message_id).toBe(7)
  })

  test('нечитаемый каталог (0o500): отправка проходит', async () => {
    if (process.getuid?.() === 0) return // root игнорирует права
    mkdirSync(join(dir, 'logs'), { recursive: true })
    chmodSync(join(dir, 'logs'), 0o500)
    const journal = createApiCallLog({ path, log: spyLog, now: new Clock().now })
    const api = createLoggedTelegramApi(stubApi(), journal, 'critical')
    await expect(api.sendMessage(CHAT, 'x', {})).resolves.toEqual({ message_id: 7 })
    chmodSync(join(dir, 'logs'), 0o700)
  })
})

function stubApi(overrides: Partial<TelegramApi> = {}): TelegramApi {
  return {
    async sendMessage() {
      return { message_id: 7 }
    },
    async editMessageText() {},
    async setMessageReaction() {},
    async sendChatAction() {},
    async sendDocument() {
      return { message_id: 8 }
    },
    async sendPhoto() {
      return { message_id: 9 }
    },
    async downloadFile() {
      return { path: '/tmp/file', size: 1 }
    },
    async deleteMessage() {},
    ...overrides,
  }
}

describe('createLoggedTelegramApi', () => {
  test('успех: category по пути, реакции отдельной категорией, без текста и токена', async () => {
    const journal = createApiCallLog({ path, now: new Clock().now })
    const crit = createLoggedTelegramApi(stubApi(), journal, 'critical')
    const bg = createLoggedTelegramApi(stubApi(), journal, 'background')
    await crit.sendMessage(CHAT, SECRET_TEXT, { parse_mode: 'HTML' })
    await bg.editMessageText(CHAT, 5, SECRET_TEXT, { parse_mode: 'HTML' })
    await bg.setMessageReaction(CHAT, 5, '👀')
    await crit.sendDocument(CHAT, `/secret/${FAKE_TOKEN}/file.pdf`, { caption: SECRET_TEXT })
    await crit.downloadFile('FILE_ID_SECRET', '/tmp/dest')

    const rows = lines()
    expect(rows.map((r) => [r.method, r.category, r.result])).toEqual([
      ['sendMessage', 'critical', 'ok'],
      ['editMessageText', 'background', 'ok'],
      ['setMessageReaction', 'reaction', 'ok'],
      ['sendDocument', 'critical', 'ok'],
      ['downloadFile', 'critical', 'ok'],
    ])
    expect(rows[4]?.chat_id).toBeNull()
    const raw = readFileSync(path, 'utf8')
    for (const forbidden of ['сверхсекретный', '4111', FAKE_TOKEN, '/secret/', 'FILE_ID_SECRET', 'HTML']) {
      expect(raw).not.toContain(forbidden)
    }
  })

  test('429: result http_429 и retry_after; ошибка пробрасывается как есть', async () => {
    const journal = createApiCallLog({ path, now: new Clock().now })
    const err = Object.assign(new Error(`Too Many Requests ${SECRET_TEXT} ${FAKE_TOKEN}`), {
      error_code: 429,
      description: SECRET_TEXT,
      parameters: { retry_after: 39548 },
    })
    const api = createLoggedTelegramApi(
      stubApi({
        async editMessageText() {
          throw err
        },
      }),
      journal,
      'background',
    )
    await expect(api.editMessageText(CHAT, 1, 'x', {})).rejects.toBe(err)
    expect(lines()[0]).toMatchObject({
      method: 'editMessageText',
      category: 'background',
      result: 'http_429',
      retry_after: 39548,
    })
    const raw = readFileSync(path, 'utf8')
    expect(raw).not.toContain('сверхсекретный')
    expect(raw).not.toContain(FAKE_TOKEN)
  })

  test('прочие http-коды, сетевой сбой и неизвестная ошибка', async () => {
    const journal = createApiCallLog({ path, now: new Clock().now })
    const failing = (e: unknown): TelegramApi =>
      stubApi({
        async sendMessage() {
          throw e
        },
      })
    const http400 = Object.assign(new Error('Bad Request'), { error_code: 400 })
    const net = Object.assign(new Error(`failed ${FAKE_TOKEN}`), { name: 'HttpError' })
    for (const e of [http400, net, new Error('boom')]) {
      const api = createLoggedTelegramApi(failing(e), journal, 'critical')
      await expect(api.sendMessage(CHAT, 'x', {})).rejects.toBe(e)
    }
    expect(lines().map((r) => r.result)).toEqual(['http_400', 'network_error', 'error'])
    expect(readFileSync(path, 'utf8')).not.toContain(FAKE_TOKEN)
  })

  test('длительность считается по часам', async () => {
    const clock = new Clock()
    const journal = createApiCallLog({ path, now: clock.now })
    const api = createLoggedTelegramApi(
      stubApi({
        async sendMessage() {
          clock.t += 250
          return { message_id: 1 }
        },
      }),
      journal,
      'critical',
      clock.now,
    )
    await api.sendMessage(CHAT, 'x', {})
    expect(lines()[0]?.duration_ms).toBe(250)
  })
})
