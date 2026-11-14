// Разрешение владельца на оригинал вложения: запрос, код, проверка отправителя.
// Синтетика: настоящих ПДн и токенов нет, id владельца и чужого - выдуманные числа.

import { afterEach, beforeEach, describe, expect, test } from 'bun:test'
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'
import type { Context } from 'grammy'

import { AppConfigSchema, type AppConfig } from '../../src/config.js'
import { createLogger } from '../../src/log.js'
import {
  CONSENT_CODE_TTL_MS, CONSENT_TTL_MS, MediaConsent, resolveConsentApprovers,
} from '../../src/channel/media-consent.js'
import { callTool, listTools, type ToolDeps } from '../../src/channel/tools.js'
import { handleInboundText, type HandlerDeps } from '../../src/telegram/handlers.js'

const OWNER = 700100
const STRANGER = 700200
const AGENT = 'agent-a'
const SHA = 'ab'.repeat(32)
const MEDIA_ID = `m${SHA.slice(0, 11)}`
const T0 = Date.parse('2026-11-14T12:00:00.000Z')
const CODE = '123456'

const silent = createLogger('test', {
  stream: { write: () => true } as unknown as NodeJS.WritableStream,
})

function makeConfig(consent: object = { enabled: true, approver_user_ids: [OWNER] }): AppConfig {
  return AppConfigSchema.parse({
    allowed_user_ids: [OWNER, STRANGER],
    allowed_chat_ids: [OWNER, STRANGER, -100500],
    media_consent: consent,
  })
}

interface Harness {
  consent: MediaConsent
  dir: string
  sent: Array<{ chatId: string; text: string }>
  notified: string[]
  warns: string[]
  setNow(ms: number): void
}

let dir: string
let now: number

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'consent-plugin-'))
  now = T0
})
afterEach(() => rmSync(dir, { recursive: true, force: true }))

function writeOffer(over: Record<string, unknown> = {}): void {
  mkdirSync(join(dir, 'offers'), { recursive: true })
  const offer = { sha256: SHA, kinds: ['PERSON', 'PHONE'], agent: AGENT, created_at: new Date(T0).toISOString(), ...over }
  writeFileSync(join(dir, 'offers', `${MEDIA_ID}.json`), JSON.stringify(offer))
}

function harness(config: AppConfig = makeConfig(), codes: string[] = [CODE]): Harness {
  const sent: Harness['sent'] = []
  const notified: string[] = []
  const warns: string[] = []
  let i = 0
  const log = {
    ...silent,
    warn: (msg: string) => { warns.push(msg) },
  } as unknown as typeof silent
  const consent = new MediaConsent({
    config,
    telegramApi: {
      sendMessage: async (chatId, text) => { sent.push({ chatId, text }); return { message_id: 1 } },
    },
    log,
    agentId: AGENT,
    dir,
    now: () => now,
    randomCode: () => codes[Math.min(i++, codes.length - 1)] as string,
    notifyAgent: async (content) => { notified.push(content) },
  })
  return { consent, dir, sent, notified, warns, setNow: (ms) => { now = ms } }
}

const approvalFile = (): string => join(dir, `${SHA}.json`)

describe('request_media_consent: запрос владельцу', () => {
  test('неизвестный media_id и неверный формат - ошибка, сообщений нет', async () => {
    const h = harness()
    expect((await h.consent.request({ media_id: MEDIA_ID })).ok).toBe(false)
    expect((await h.consent.request({ media_id: '123456789012' })).ok).toBe(false)
    expect(h.sent).toHaveLength(0)
  })

  test('владельцу уходит код, типы берутся из записи прокси, агенту код не возвращается', async () => {
    writeOffer()
    const h = harness()
    const out = await h.consent.request({ media_id: MEDIA_ID, kinds: ['FAKE'], reason: 'нужно\nпрочитать   договор' })
    expect(out.ok).toBe(true)
    expect(out.message).not.toContain(CODE)
    expect(h.sent).toHaveLength(1)
    const msg = h.sent[0] as { chatId: string; text: string }
    expect(msg.chatId).toBe(String(OWNER))
    expect(msg.text).toContain(AGENT)
    expect(msg.text).toContain('PERSON, PHONE')
    expect(msg.text).not.toContain('FAKE')
    expect(msg.text).toContain('Anthropic')
    expect(msg.text).toContain(CODE)
    expect(msg.text).toContain('нужно прочитать договор')
    expect(h.consent.pendingCount).toBe(1)
  })

  test('предложение другого агента отклоняется', async () => {
    writeOffer({ agent: 'agent-b' })
    const h = harness()
    expect((await h.consent.request({ media_id: MEDIA_ID })).ok).toBe(false)
    expect(h.sent).toHaveLength(0)
  })

  test('id не соответствует отпечатку в записи - запись отвергается', async () => {
    writeOffer({ sha256: 'cd'.repeat(32) })
    const h = harness()
    expect((await h.consent.request({ media_id: MEDIA_ID })).ok).toBe(false)
  })

  test('повторный запрос в течение минуты не шлёт второе сообщение', async () => {
    writeOffer()
    const h = harness()
    await h.consent.request({ media_id: MEDIA_ID })
    const again = await h.consent.request({ media_id: MEDIA_ID })
    expect(again.ok).toBe(false)
    expect(h.sent).toHaveLength(1)
  })

  test('повтор после паузы заменяет прежний код новым', async () => {
    writeOffer()
    const h = harness(makeConfig(), ['111111', '222222'])
    await h.consent.request({ media_id: MEDIA_ID })
    h.setNow(T0 + 120_000)
    await h.consent.request({ media_id: MEDIA_ID })
    expect(h.consent.pendingCount).toBe(1)
    expect(await h.consent.tryHandleText({ fromUserId: OWNER, chatId: String(OWNER), text: '111111' })).toBe(false)
    expect(existsSync(approvalFile())).toBe(false)
    expect(await h.consent.tryHandleText({ fromUserId: OWNER, chatId: String(OWNER), text: '222222' })).toBe(true)
    expect(existsSync(approvalFile())).toBe(true)
  })
})

describe('код владельца: разрешение только от подтверждающего', () => {
  async function requested(config?: AppConfig): Promise<Harness> {
    writeOffer()
    const h = harness(config)
    await h.consent.request({ media_id: MEDIA_ID })
    h.sent.length = 0
    return h
  }

  test('код от владельца: файл разрешения, ответ, уведомление агенту, код потреблён', async () => {
    const h = await requested()
    const consumed = await h.consent.tryHandleText({ fromUserId: OWNER, chatId: String(OWNER), text: `  ${CODE}\n` })
    expect(consumed).toBe(true)
    const rec = JSON.parse(readFileSync(approvalFile(), 'utf8')) as Record<string, unknown>
    expect(rec.sha256).toBe(SHA)
    expect(rec.agent).toBe(AGENT)
    expect(rec.approved_by).toBe(OWNER)
    expect(rec.kinds).toEqual(['PERSON', 'PHONE'])
    expect(Date.parse(rec.expires_at as string) - Date.parse(rec.approved_at as string)).toBe(CONSENT_TTL_MS)
    expect(statSync(approvalFile()).mode & 0o777).toBe(0o600)
    expect(statSync(dir).mode & 0o777).toBe(0o700)
    expect(h.sent).toHaveLength(1)
    expect((h.sent[0] as { text: string }).text).toContain('Разрешено')
    expect(h.notified).toHaveLength(1)
    expect(h.notified[0]).toContain(MEDIA_ID)
    expect(h.consent.pendingCount).toBe(0)
  })

  test('повтор того же кода не даёт разрешения и доходит как обычный текст', async () => {
    const h = await requested()
    await h.consent.tryHandleText({ fromUserId: OWNER, chatId: String(OWNER), text: CODE })
    rmSync(approvalFile())
    const again = await h.consent.tryHandleText({ fromUserId: OWNER, chatId: String(OWNER), text: CODE })
    expect(again).toBe(false)
    expect(existsSync(approvalFile())).toBe(false)
  })

  test('код от другого from.id: разрешения нет, предупреждение в журнале, код не потреблён', async () => {
    const h = await requested()
    const consumed = await h.consent.tryHandleText({ fromUserId: STRANGER, chatId: String(STRANGER), text: CODE })
    expect(consumed).toBe(false)
    expect(existsSync(approvalFile())).toBe(false)
    expect(h.warns).toContain('media_consent.code_wrong_sender')
    expect(h.consent.pendingCount).toBe(1)
    expect(h.notified).toHaveLength(0)
  })

  test('проверяется отправитель, а не чат: чужой в чате владельца - нет, владелец в группе - да', async () => {
    const h = await requested()
    // в чате владельца пишет чужой from.id
    expect(await h.consent.tryHandleText({ fromUserId: STRANGER, chatId: String(OWNER), text: CODE })).toBe(false)
    expect(existsSync(approvalFile())).toBe(false)
    // владелец пишет код в группе
    expect(await h.consent.tryHandleText({ fromUserId: OWNER, chatId: '-100500', text: CODE })).toBe(true)
    expect(existsSync(approvalFile())).toBe(true)
    expect((h.sent[0] as { chatId: string }).chatId).toBe('-100500')
  })

  test('сообщение без отправителя не подтверждает', async () => {
    const h = await requested()
    expect(await h.consent.tryHandleText({ fromUserId: undefined, chatId: String(OWNER), text: CODE })).toBe(false)
    expect(existsSync(approvalFile())).toBe(false)
  })

  test('неверный код: разрешения нет, ожидающий запрос остаётся', async () => {
    const h = await requested()
    expect(await h.consent.tryHandleText({ fromUserId: OWNER, chatId: String(OWNER), text: '654321' })).toBe(false)
    expect(existsSync(approvalFile())).toBe(false)
    expect(h.consent.pendingCount).toBe(1)
  })

  test('просроченный код: разрешения нет, владельцу ответ, запрос снят', async () => {
    const h = await requested()
    h.setNow(T0 + CONSENT_CODE_TTL_MS + 1)
    expect(await h.consent.tryHandleText({ fromUserId: OWNER, chatId: String(OWNER), text: CODE })).toBe(true)
    expect(existsSync(approvalFile())).toBe(false)
    expect((h.sent[0] as { text: string }).text).toContain('просрочен')
    expect(h.consent.pendingCount).toBe(0)
  })

  test('обычный текст и числа другой длины не трогаются', async () => {
    const h = await requested()
    for (const text of ['привет', '12345', '1234567', 'код 123456']) {
      expect(await h.consent.tryHandleText({ fromUserId: OWNER, chatId: String(OWNER), text })).toBe(false)
    }
    expect(h.consent.pendingCount).toBe(1)
  })

  test('существующее разрешение: повторный запрос не шлёт код', async () => {
    const h = await requested()
    await h.consent.tryHandleText({ fromUserId: OWNER, chatId: String(OWNER), text: CODE })
    h.sent.length = 0
    h.setNow(T0 + 120_000)
    const out = await h.consent.request({ media_id: MEDIA_ID })
    expect(out.ok).toBe(true)
    expect(h.sent).toHaveLength(0)
  })
})

describe('подтверждающие и набор инструментов', () => {
  test('по умолчанию: operator_user_ids, иначе allowed_user_ids', () => {
    expect(resolveConsentApprovers(makeConfig({ enabled: true }))).toEqual([OWNER, STRANGER])
    const withOperator = AppConfigSchema.parse({
      allowed_user_ids: [OWNER, STRANGER], operator_user_ids: [OWNER], media_consent: { enabled: true },
    })
    expect(resolveConsentApprovers(withOperator)).toEqual([OWNER])
  })

  test('инструмент есть в списке только при включённой функции', () => {
    expect(listTools().map(t => t.name)).not.toContain('request_media_consent')
    expect(listTools(undefined, { mediaConsent: true }).map(t => t.name)).toContain('request_media_consent')
  })

  test('нет инструмента записи разрешения: ни один инструмент не принимает код или sha256', () => {
    const names = listTools(undefined, { mediaConsent: true }).map(t => t.name)
    expect(names.filter(n => /consent|approve|allow/i.test(n))).toEqual(['request_media_consent'])
    const props = Object.keys(
      (listTools(undefined, { mediaConsent: true }).find(t => t.name === 'request_media_consent') as {
        inputSchema: { properties: Record<string, unknown> }
      }).inputSchema.properties,
    )
    expect(props).toEqual(['media_id', 'kinds', 'reason'])
  })

  test('callTool без включённой функции: неизвестный инструмент', async () => {
    const out = await callTool(
      { params: { name: 'request_media_consent', arguments: { media_id: MEDIA_ID } } },
      { config: makeConfig(), log: silent } as unknown as ToolDeps,
    )
    expect(out.isError).toBe(true)
  })

  test('callTool с включённой функцией доходит до запроса', async () => {
    writeOffer()
    const h = harness()
    const out = await callTool(
      { params: { name: 'request_media_consent', arguments: { media_id: MEDIA_ID } } },
      { config: makeConfig(), log: silent, mediaConsent: h.consent } as unknown as ToolDeps,
    )
    expect(out.isError).toBeUndefined()
    expect(h.sent).toHaveLength(1)
  })
})

describe('handleInboundText: код владельца не доставляется агенту', () => {
  function ctxOf(text: string, fromId: number, chatId: number, chatType: 'private' | 'group'): Context {
    const from = { id: fromId, is_bot: false, first_name: 'x' }
    return {
      chat: { id: chatId, type: chatType },
      from,
      message: { message_id: 7, date: 1700000000, text, chat: { id: chatId, type: chatType }, from },
    } as unknown as Context
  }

  async function run(fromId: number, chatId: number, chatType: 'private' | 'group'): Promise<{
    notifications: number
    approved: boolean
  }> {
    writeOffer()
    const h = harness()
    await h.consent.request({ media_id: MEDIA_ID })
    const notifications: unknown[] = []
    const deps = {
      server: { notification: async (m: unknown) => { notifications.push(m) } },
      config: makeConfig(),
      statePaths: { root: dir, inbox: dir, logs: {} },
      telegramApi: { setMessageReaction: async () => undefined, sendChatAction: async () => undefined },
      log: silent,
      bot: { id: 1, username: 'b' },
      botApi: { api: {} },
      botToken: 'fake',
      env: {},
      mediaConsent: h.consent,
    } as unknown as HandlerDeps
    await handleInboundText(ctxOf(CODE, fromId, chatId, chatType), deps)
    return { notifications: notifications.length, approved: existsSync(approvalFile()) }
  }

  test('код владельца: разрешение есть, сообщение агенту не ушло', async () => {
    expect(await run(OWNER, OWNER, 'private')).toEqual({ notifications: 0, approved: true })
  })

  test('код владельца в группе: проверяется from.id, разрешение есть', async () => {
    expect((await run(OWNER, -100500, 'group')).approved).toBe(true)
  })

  test('код от другого пользователя: разрешения нет', async () => {
    expect((await run(STRANGER, STRANGER, 'private')).approved).toBe(false)
  })
})
