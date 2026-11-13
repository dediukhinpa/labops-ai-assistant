// Хук fallback-reply (Stop): флаг, разбор stdin, адрес роута, повторы.

import { describe, expect, test } from 'bun:test'

import {
  isFallbackEnabled,
  parseStopInput,
  resolveFallbackHookConfig,
  runFallbackHook,
} from '../../scripts/fallback-reply-hook.js'

const STDIN = JSON.stringify({ transcript_path: '/h/.claude/projects/x/s.jsonl', session_id: 'sess-1', hook_event_name: 'Stop' })
const ENV = {
  TELEGRAM_FALLBACK_REPLY: '1',
  TELEGRAM_WEBHOOK_TOKEN: 'tok',
  TELEGRAM_WEBHOOK_PORT: '6000',
}

interface Call { url: string; auth: string | null; body: unknown }

function fakeFetch(statuses: string[], calls: Call[]): typeof fetch {
  let i = 0
  return (async (url: string | URL | Request, init?: RequestInit) => {
    const headers = new Headers(init?.headers)
    calls.push({ url: String(url), auth: headers.get('authorization'), body: JSON.parse(String(init?.body)) })
    const status = statuses[Math.min(i++, statuses.length - 1)] as string
    return new Response(JSON.stringify({ status }), { status: 200 })
  }) as typeof fetch
}

describe('isFallbackEnabled', () => {
  test('по умолчанию выключено', () => {
    expect(isFallbackEnabled({})).toBe(false)
    expect(isFallbackEnabled({ TELEGRAM_FALLBACK_REPLY: '0' })).toBe(false)
    expect(isFallbackEnabled({ TELEGRAM_FALLBACK_REPLY: 'maybe' })).toBe(false)
  })
  test.each(['1', 'true', 'YES', 'on'])('включено для %s', (v) => {
    expect(isFallbackEnabled({ TELEGRAM_FALLBACK_REPLY: v })).toBe(true)
  })
})

describe('parseStopInput', () => {
  test('берёт путь и session_id', () => {
    expect(parseStopInput(STDIN)).toEqual({ transcript_path: '/h/.claude/projects/x/s.jsonl', session_id: 'sess-1' })
  })
  test('без session_id', () => {
    expect(parseStopInput('{"transcript_path":"/a.jsonl"}')).toEqual({ transcript_path: '/a.jsonl' })
  })
  test('мусор и пустой путь → undefined', () => {
    expect(parseStopInput('nope')).toBeUndefined()
    expect(parseStopInput('{}')).toBeUndefined()
    expect(parseStopInput('{"transcript_path":""}')).toBeUndefined()
  })
})

describe('resolveFallbackHookConfig', () => {
  test('URL из хоста и порта, по умолчанию loopback', () => {
    expect(resolveFallbackHookConfig(ENV)).toEqual({ url: 'http://127.0.0.1:6000/hooks/fallback-reply', token: 'tok' })
  })
  test('явный URL главнее', () => {
    expect(resolveFallbackHookConfig({ ...ENV, TELEGRAM_FALLBACK_REPLY_URL: 'http://127.0.0.1:1/x' })).toEqual({
      url: 'http://127.0.0.1:1/x',
      token: 'tok',
    })
  })
  test('нет токена / порта → ошибка', () => {
    expect('kind' in resolveFallbackHookConfig({ TELEGRAM_WEBHOOK_PORT: '1' })).toBe(true)
    expect('kind' in resolveFallbackHookConfig({ TELEGRAM_WEBHOOK_TOKEN: 't' })).toBe(true)
  })
})

describe('runFallbackHook', () => {
  test('флаг выключен: запросов нет', async () => {
    const calls: Call[] = []
    const { TELEGRAM_FALLBACK_REPLY: _omit, ...off } = ENV
    expect(await runFallbackHook(STDIN, off, { fetchImpl: fakeFetch(['sent'], calls) })).toBeUndefined()
    expect(calls).toHaveLength(0)
  })

  test('флаг включён: один запрос с токеном, путь и сессия в теле', async () => {
    const calls: Call[] = []
    const status = await runFallbackHook(STDIN, ENV, { fetchImpl: fakeFetch(['sent'], calls) })
    expect(status).toBe('sent')
    expect(calls).toHaveLength(1)
    expect(calls[0]).toEqual({
      url: 'http://127.0.0.1:6000/hooks/fallback-reply',
      auth: 'Bearer tok',
      body: { transcript_path: '/h/.claude/projects/x/s.jsonl', session_id: 'sess-1' },
    })
  })

  test('no_text → повторы, затем успех', async () => {
    const calls: Call[] = []
    const sleeps: number[] = []
    const status = await runFallbackHook(STDIN, ENV, {
      fetchImpl: fakeFetch(['no_text', 'no_text', 'sent'], calls),
      sleepImpl: async (ms) => { sleeps.push(ms) },
    })
    expect(status).toBe('sent')
    expect(calls).toHaveLength(3)
    expect(sleeps).toHaveLength(2)
  })

  test('no_text навсегда: повторы ограничены', async () => {
    const calls: Call[] = []
    const status = await runFallbackHook(STDIN, { ...ENV, FALLBACK_REPLY_RETRY_ATTEMPTS: '3' }, {
      fetchImpl: fakeFetch(['no_text'], calls),
      sleepImpl: async () => undefined,
    })
    expect(status).toBe('no_text')
    expect(calls).toHaveLength(3)
  })

  test('replied / duplicate не повторяются', async () => {
    const calls: Call[] = []
    await runFallbackHook(STDIN, ENV, { fetchImpl: fakeFetch(['replied'], calls) })
    expect(calls).toHaveLength(1)
  })

  test('ошибка сети не бросает', async () => {
    const boom = (async () => { throw new Error('ECONNREFUSED') }) as unknown as typeof fetch
    expect(await runFallbackHook(STDIN, ENV, { fetchImpl: boom })).toBeUndefined()
  })

  test('не-200 (503 выключено) → undefined, без повторов', async () => {
    let n = 0
    const f = (async () => { n++; return new Response('{}', { status: 503 }) }) as unknown as typeof fetch
    expect(await runFallbackHook(STDIN, ENV, { fetchImpl: f })).toBeUndefined()
    expect(n).toBe(1)
  })

  test('мусор на stdin: запросов нет', async () => {
    const calls: Call[] = []
    expect(await runFallbackHook('garbage', ENV, { fetchImpl: fakeFetch(['sent'], calls) })).toBeUndefined()
    expect(calls).toHaveLength(0)
  })
})

describe('запуск как скрипт', () => {
  test('без флага: exit 0, пустой stdout, запросов нет', async () => {
    const proc = Bun.spawn(['bun', 'scripts/fallback-reply-hook.ts'], {
      stdin: new Blob([STDIN]),
      stdout: 'pipe',
      stderr: 'pipe',
      env: { PATH: process.env.PATH ?? '', HOME: process.env.HOME ?? '' },
    })
    expect(await proc.exited).toBe(0)
    expect(await new Response(proc.stdout).text()).toBe('')
  })
})
