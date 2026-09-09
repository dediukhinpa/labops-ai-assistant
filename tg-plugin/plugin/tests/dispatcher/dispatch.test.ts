// Разбор входящего апдейта: кому он адресован и что с ним делать.
//
// Главный инвариант — сообщение уходит ТОЛЬКО агенту своего отправителя.
// Всё остальное (чужой id, нетекстовое вложение, мёртвый агент) обязано
// заканчиваться внятным ответом человеку, а не тишиной.

import { describe, expect, test } from 'bun:test'
import type { Update } from 'grammy/types'

import { dispatchUpdate, type DispatchDeps } from '../../src/dispatcher/dispatch.js'

function textUpdate(fromId: number, text: string, chatId = fromId): Update {
  return {
    update_id: 1,
    message: {
      message_id: 10,
      date: 0,
      chat: { id: chatId, type: 'private' },
      from: { id: fromId, is_bot: false, first_name: 'Тест' },
      text,
    },
  } as Update
}

function deps(overrides: Partial<DispatchDeps> = {}): DispatchDeps {
  return {
    lookupAgent: () => 'labops-app',
    resolveEndpoint: () => ({ url: 'http://127.0.0.1:6002/hooks/agent', token: 't' }),
    deliver: async () => ({ ok: true }),
    replyToUser: async () => {},
    log: { info: () => {}, warn: () => {}, error: () => {} },
    ...overrides,
  }
}

describe('dispatchUpdate', () => {
  test('delivers text to the sender own agent with the real chat id', async () => {
    const seen: Array<{ agent: string; message: string; chatId: number | string }> = []
    const res = await dispatchUpdate(
      textUpdate(308749463, 'привет'),
      deps({
        resolveEndpoint: (agentId) => {
          seen.push({ agent: agentId, message: '', chatId: 0 })
          return { url: 'http://127.0.0.1:6002/hooks/agent', token: 't' }
        },
        deliver: async (_target, payload) => {
          seen.push({ agent: 'x', message: payload.message, chatId: payload.chatId })
          return { ok: true }
        },
      }),
    )
    expect(res.outcome).toBe('delivered')
    expect(seen[0]?.agent).toBe('labops-app')
    expect(seen[1]?.message).toBe('привет')
    expect(seen[1]?.chatId).toBe(308749463)
  })

  test('routes by sender, not by chat — a shared chat cannot borrow an agent', async () => {
    let askedFor: number | string | undefined
    await dispatchUpdate(
      textUpdate(308749463, 'привет', -100500),
      deps({
        lookupAgent: (id) => {
          askedFor = id
          return 'labops-app'
        },
      }),
    )
    expect(askedFor).toBe(308749463)
  })

  test('tells an unknown sender they are not connected and delivers nothing', async () => {
    let delivered = false
    const replies: string[] = []
    const res = await dispatchUpdate(
      textUpdate(777, 'привет'),
      deps({
        lookupAgent: () => undefined,
        deliver: async () => {
          delivered = true
          return { ok: true }
        },
        replyToUser: async (_chatId, text) => {
          replies.push(text)
        },
      }),
    )
    expect(res.outcome).toBe('no_route')
    expect(delivered).toBe(false)
    expect(replies).toHaveLength(1)
  })

  test('says attachments are not supported yet instead of dropping them', async () => {
    const update = {
      update_id: 2,
      message: {
        message_id: 11,
        date: 0,
        chat: { id: 308749463, type: 'private' },
        from: { id: 308749463, is_bot: false, first_name: 'Тест' },
        voice: { file_id: 'f', file_unique_id: 'u', duration: 1 },
      },
    } as Update
    const replies: string[] = []
    const res = await dispatchUpdate(
      update,
      deps({ replyToUser: async (_c, t) => void replies.push(t) }),
    )
    expect(res.outcome).toBe('unsupported')
    expect(replies).toHaveLength(1)
  })

  test('reports a dead agent to the sender rather than swallowing the message', async () => {
    const replies: string[] = []
    const res = await dispatchUpdate(
      textUpdate(308749463, 'привет'),
      deps({
        deliver: async () => ({ ok: false, reason: 'ECONNREFUSED' }),
        replyToUser: async (_c, t) => void replies.push(t) ,
      }),
    )
    expect(res.outcome).toBe('failed')
    expect(replies).toHaveLength(1)
  })

  test('a broken route does not take the dispatcher down', async () => {
    const res = await dispatchUpdate(
      textUpdate(308749463, 'привет'),
      deps({
        resolveEndpoint: () => {
          throw new Error('agent has no port')
        },
      }),
    )
    expect(res.outcome).toBe('failed')
  })

  test('ignores updates that carry no message at all', async () => {
    const res = await dispatchUpdate({ update_id: 3 } as Update, deps())
    expect(res.outcome).toBe('ignored')
  })

  test('ignores messages from bots', async () => {
    const update = textUpdate(308749463, 'привет')
    // eslint-disable-next-line @typescript-eslint/no-non-null-assertion
    ;(update.message as { from: { is_bot: boolean } }).from.is_bot = true
    expect((await dispatchUpdate(update, deps())).outcome).toBe('ignored')
  })
})
