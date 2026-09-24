// Тесты релея клиентов поддержки (src/telegram/client-relay.ts).
import { describe, expect, test } from 'bun:test'

import {
  classifyClientText,
  CLIENT_RELAY_MAX_TEXT_CHARS,
  CLIENT_START_HINT_TEXT,
  CLIENT_TOO_LONG_TEXT,
  CLIENT_UNAVAILABLE_TEXT,
  createClientRelay,
  createClientRelayFromEnv,
  type FetchLike,
} from '../../src/telegram/client-relay.js'
import { createLogger } from '../../src/log.js'

const logLines: string[] = []
const log = createLogger('test', {
  stream: { write: (chunk: string) => { logLines.push(chunk); return true } } as unknown as NodeJS.WritableStream,
})

const TOKEN = 'secret-relay-token'
const SECRET_TEXT = 'мой секретный вопрос про оплату'

interface Harness {
  sent: Array<{ chatId: string; text: string }>
  requests: Array<{ url: string; init: RequestInit | undefined }>
  relay: ReturnType<typeof createClientRelay>
}

function makeHarness(fetchImpl: FetchLike, timeoutMs?: number): Harness {
  const sent: Harness['sent'] = []
  const requests: Harness['requests'] = []
  const wrapped: FetchLike = (url, init) => {
    requests.push({ url, init })
    return fetchImpl(url, init)
  }
  const relay = createClientRelay({
    url: 'http://127.0.0.1:18080/tg-edge/support-followup',
    token: TOKEN,
    telegramApi: {
      sendMessage: async (chatId, text) => {
        sent.push({ chatId, text })
        return { message_id: 1 }
      },
    },
    log,
    fetchImpl: wrapped,
    ...(timeoutMs !== undefined ? { timeoutMs } : {}),
  })
  return { sent, requests, relay }
}

const jsonOk = (body: unknown): FetchLike => async () =>
  new Response(JSON.stringify(body), { status: 200, headers: { 'content-type': 'application/json' } })

describe('classifyClientText', () => {
  const base = { telegramUserId: 7, chatId: 7 }

  test('/start t_<8hex> -> start с shortId в нижнем регистре', () => {
    const r = classifyClientText({ ...base, text: '/start t_ABCDEF12' })
    expect(r).toEqual({ relay: { kind: 'start', telegramUserId: 7, chatId: 7, shortId: 'abcdef12' } })
  })

  test('/start@бот t_<8hex> тоже start', () => {
    const r = classifyClientText({ ...base, text: '/start@some_bot t_f87003dd' })
    expect('relay' in r && r.relay.kind).toBe('start')
  })

  test('/start без payload и с чужим payload -> фиксированный ответ без форварда', () => {
    for (const text of ['/start', '/start ', '/start hello', '/start t_zz', '/start t_abcdef123']) {
      expect(classifyClientText({ ...base, text })).toEqual({ fixedReply: CLIENT_START_HINT_TEXT })
    }
  })

  test('обычный текст -> message', () => {
    const r = classifyClientText({ ...base, text: '  привет  ' })
    expect(r).toEqual({ relay: { kind: 'message', telegramUserId: 7, chatId: 7, text: 'привет' } })
  })

  test('слишком длинный текст не форвардится', () => {
    const r = classifyClientText({ ...base, text: 'а'.repeat(CLIENT_RELAY_MAX_TEXT_CHARS + 1) })
    expect(r).toEqual({ fixedReply: CLIENT_TOO_LONG_TEXT })
  })
})

describe('createClientRelay.handle', () => {
  test('message: POST с bearer и телом контракта, ответ эндпоинта уходит клиенту', async () => {
    const h = makeHarness(jsonOk({ ok: true, reply: 'Приняли, ответим здесь.' }))
    await h.relay.handle({ telegramUserId: 7, chatId: 7, text: SECRET_TEXT })

    expect(h.requests).toHaveLength(1)
    const init = h.requests[0]?.init
    expect(init?.method).toBe('POST')
    expect((init?.headers as Record<string, string>)['authorization']).toBe(`Bearer ${TOKEN}`)
    expect(JSON.parse(String(init?.body))).toEqual({
      kind: 'message', telegramUserId: 7, chatId: 7, text: SECRET_TEXT,
    })
    expect(h.sent).toEqual([{ chatId: '7', text: 'Приняли, ответим здесь.' }])
  })

  test('start: в теле shortId и нет text', async () => {
    const h = makeHarness(jsonOk({ ok: true, reply: 'Чат открыт.' }))
    await h.relay.handle({ telegramUserId: 7, chatId: 7, text: '/start t_f87003dd' })
    expect(JSON.parse(String(h.requests[0]?.init?.body))).toEqual({
      kind: 'start', telegramUserId: 7, chatId: 7, shortId: 'f87003dd',
    })
    expect(h.sent).toEqual([{ chatId: '7', text: 'Чат открыт.' }])
  })

  test('пустой reply -> клиенту ничего не шлём', async () => {
    const h = makeHarness(jsonOk({ ok: true, reply: '' }))
    await h.relay.handle({ telegramUserId: 7, chatId: 7, text: 'привет' })
    expect(h.sent).toEqual([])
  })

  test('/start без payload: эндпоинт не вызывается, клиент получает подсказку', async () => {
    const h = makeHarness(jsonOk({ ok: true, reply: 'x' }))
    await h.relay.handle({ telegramUserId: 7, chatId: 7, text: '/start' })
    expect(h.requests).toHaveLength(0)
    expect(h.sent).toEqual([{ chatId: '7', text: CLIENT_START_HINT_TEXT }])
  })

  test('ok:false, HTTP 500 и не-JSON -> фиксированный ответ «позже»', async () => {
    const cases: FetchLike[] = [
      jsonOk({ ok: false, error: 'boom' }),
      async () => new Response('err', { status: 500 }),
      async () => new Response('not json', { status: 200 }),
    ]
    for (const fetchImpl of cases) {
      const h = makeHarness(fetchImpl)
      await h.relay.handle({ telegramUserId: 7, chatId: 7, text: 'привет' })
      expect(h.sent).toEqual([{ chatId: '7', text: CLIENT_UNAVAILABLE_TEXT }])
    }
  })

  test('таймаут вызова -> фиксированный ответ «позже»', async () => {
    const hanging: FetchLike = (_url, init) =>
      new Promise((_resolve, reject) => {
        init?.signal?.addEventListener('abort', () => reject(new Error('aborted')))
      })
    const h = makeHarness(hanging, 30)
    await h.relay.handle({ telegramUserId: 7, chatId: 7, text: 'привет' })
    expect(h.sent).toEqual([{ chatId: '7', text: CLIENT_UNAVAILABLE_TEXT }])
  })

  test('сбой sendMessage не бросает наружу', async () => {
    const relay = createClientRelay({
      url: 'http://127.0.0.1:1/x',
      token: TOKEN,
      telegramApi: { sendMessage: async () => { throw new Error('blocked by user') } },
      log,
      fetchImpl: jsonOk({ ok: true, reply: 'ok' }),
    })
    await relay.handle({ telegramUserId: 7, chatId: 7, text: 'привет' })
  })

  test('токен и текст сообщения не попадают в журнал', () => {
    const joined = logLines.join('\n')
    expect(joined).not.toContain(TOKEN)
    expect(joined).not.toContain(SECRET_TEXT)
  })
})

describe('createClientRelayFromEnv', () => {
  const deps = { telegramApi: { sendMessage: async () => ({ message_id: 1 }) }, log }

  test('выключена без любой из двух переменных', () => {
    expect(createClientRelayFromEnv({}, deps)).toBeUndefined()
    expect(createClientRelayFromEnv({ SUPPORT_FOLLOWUP_URL: 'http://x' }, deps)).toBeUndefined()
    expect(createClientRelayFromEnv({ SUPPORT_FOLLOWUP_TOKEN: 't' }, deps)).toBeUndefined()
  })

  test('выключена при некорректном URL', () => {
    const env = { SUPPORT_FOLLOWUP_URL: 'ftp://x/y', SUPPORT_FOLLOWUP_TOKEN: 't' }
    expect(createClientRelayFromEnv(env, deps)).toBeUndefined()
    expect(createClientRelayFromEnv({ ...env, SUPPORT_FOLLOWUP_URL: 'не url' }, deps)).toBeUndefined()
  })

  test('включена при корректной паре', () => {
    const env = { SUPPORT_FOLLOWUP_URL: 'http://127.0.0.1:18080/tg-edge/support-followup', SUPPORT_FOLLOWUP_TOKEN: 't' }
    expect(createClientRelayFromEnv(env, deps)).toBeDefined()
  })
})
