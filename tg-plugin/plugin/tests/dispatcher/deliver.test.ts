// Доставка входящего в приёмник агента (POST /hooks/agent).
//
// Транспорт уже боевой — им пользуется веб-приложение. Здесь фиксируем
// контракт: bearer в заголовке, реальный chat_id в теле (иначе ответ
// агента уйдёт не в тот чат) и внятная классификация отказов.

import { describe, expect, test } from 'bun:test'

import { deliverToAgent } from '../../src/dispatcher/deliver.js'

const ENDPOINT = { url: 'http://127.0.0.1:6002/hooks/agent', token: 'bearer-value' }

describe('deliverToAgent', () => {
  test('posts message and chatId with the agent bearer', async () => {
    let seen: { url: string; init: RequestInit } | undefined
    const res = await deliverToAgent(
      ENDPOINT,
      { message: 'привет', chatId: 308749463 },
      {
        fetchImpl: async (url, init) => {
          seen = { url: String(url), init: init ?? {} }
          return new Response(JSON.stringify({ status: 'accepted' }), { status: 200 })
        },
      },
    )
    expect(res.ok).toBe(true)
    expect(seen?.url).toBe(ENDPOINT.url)
    const headers = new Headers(seen?.init.headers)
    expect(headers.get('authorization')).toBe('Bearer bearer-value')
    expect(JSON.parse(String(seen?.init.body))).toEqual({
      message: 'привет',
      chatId: 308749463,
    })
  })

  test('reports a rejected delivery with its status', async () => {
    const res = await deliverToAgent(
      ENDPOINT,
      { message: 'привет', chatId: 1 },
      { fetchImpl: async () => new Response('{"error":"unauthorized"}', { status: 401 }) },
    )
    expect(res.ok).toBe(false)
    if (!res.ok) expect(res.status).toBe(401)
  })

  test('reports a dead agent instead of throwing', async () => {
    const res = await deliverToAgent(
      ENDPOINT,
      { message: 'привет', chatId: 1 },
      {
        fetchImpl: async () => {
          throw new Error('ECONNREFUSED')
        },
      },
    )
    expect(res.ok).toBe(false)
    if (!res.ok) expect(res.reason).toContain('ECONNREFUSED')
  })

  test('never leaks the bearer into the failure reason', async () => {
    const res = await deliverToAgent(
      ENDPOINT,
      { message: 'привет', chatId: 1 },
      {
        fetchImpl: async () => {
          throw new Error('connect failed to bearer-value')
        },
      },
    )
    expect(res.ok).toBe(false)
    if (!res.ok) expect(res.reason).not.toContain('bearer-value')
  })

  test('gives up on a hung agent rather than stalling the whole bot', async () => {
    const res = await deliverToAgent(
      ENDPOINT,
      { message: 'привет', chatId: 1 },
      {
        timeoutMs: 20,
        fetchImpl: (_url, init) =>
          new Promise((_resolve, reject) => {
            init?.signal?.addEventListener('abort', () => reject(new Error('aborted')))
          }),
      },
    )
    expect(res.ok).toBe(false)
  })
})
