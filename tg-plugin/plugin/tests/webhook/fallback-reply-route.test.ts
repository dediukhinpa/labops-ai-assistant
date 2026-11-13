// Роут POST /hooks/fallback-reply: токен, флаг, исходы, дедуп, валидация.

import { afterEach, beforeEach, describe, expect, test } from 'bun:test'
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'

import { runFallbackHook } from '../../scripts/fallback-reply-hook.js'
import { FallbackReplyService } from '../../src/channel/fallback-reply.js'
import { getStatePaths, loadConfig, type AppConfig, type StatePaths } from '../../src/config.js'
import { createLogger } from '../../src/log.js'
import { ensureStateDirs } from '../../src/state/store.js'
import { startWebhookServer, type WebhookServerHandle } from '../../src/webhook/server.js'

const FAKE_TOKEN = '123456789:AAH-fake_test_token_with_at_least_thirty_chars'
const WEBHOOK_TOKEN = 'wh_test_token_32_chars__________'
const OPERATOR_ID = '100000001'

let stateDir: string
let projects: string
let paths: StatePaths
let baseConfig: AppConfig
let handle: WebhookServerHandle | null
let sent: Array<{ chatId: string; text: string; replyTo: number | undefined }>

beforeEach(() => {
  stateDir = mkdtempSync(join(tmpdir(), 'labops-channel-fallback-'))
  projects = join(stateDir, 'claude-projects', 'slug')
  mkdirSync(projects, { recursive: true })
  delete process.env.TELEGRAM_WEBHOOK_TOKEN
  baseConfig = loadConfig({
    TELEGRAM_BOT_TOKEN: FAKE_TOKEN,
    TELEGRAM_STATE_DIR: stateDir,
    TELEGRAM_ALLOWED_CHAT_IDS: OPERATOR_ID,
  })
  paths = getStatePaths(baseConfig, { TELEGRAM_BOT_TOKEN: FAKE_TOKEN, TELEGRAM_STATE_DIR: stateDir })
  ensureStateDirs(paths)
  handle = null
  sent = []
})

afterEach(async () => {
  if (handle) await handle.close()
  handle = null
  delete process.env.TELEGRAM_WEBHOOK_TOKEN
  rmSync(stateDir, { recursive: true, force: true })
})

async function start(opts: { enabled: boolean; wired?: boolean } = { enabled: true }): Promise<WebhookServerHandle> {
  const config: AppConfig = { ...baseConfig, webhook: { enabled: true, host: '127.0.0.1', port: 0 } }
  const fallbackReply = new FallbackReplyService({
    enabled: opts.enabled,
    transcriptRoots: [join(stateDir, 'claude-projects')],
    statePath: join(stateDir, 'fallback-reply', 'state.json'),
    prefix: '⚠ ответ без reply:',
    log: createLogger('test-fallback-route'),
    sendMessage: async (chatId, text, o) => {
      sent.push({ chatId, text, replyTo: o.reply_to_message_id })
      return { message_id: 1 }
    },
    isChatAllowed: (c) => c === OPERATOR_ID,
  })
  const h = await startWebhookServer(config, {
    mcpServer: { notification: async () => undefined } as never,
    config,
    statePaths: paths,
    log: createLogger('test-fallback-route'),
    ...(opts.wired === false ? {} : { fallbackReply }),
  })
  if (!h) throw new Error('expected handle')
  handle = h
  return h
}

function post(h: WebhookServerHandle, body: unknown, token: string | null = WEBHOOK_TOKEN): Promise<Response> {
  const headers: Record<string, string> = { 'Content-Type': 'application/json' }
  if (token) headers.Authorization = `Bearer ${token}`
  return fetch(`http://${h.host}:${h.port}/hooks/fallback-reply`, {
    method: 'POST',
    headers,
    body: typeof body === 'string' ? body : JSON.stringify(body),
  })
}

function transcript(name: string, lines: unknown[]): string {
  const p = join(projects, name)
  writeFileSync(p, lines.map((l) => JSON.stringify(l)).join('\n') + '\n')
  return p
}
const prompt = (content: string): unknown => ({ type: 'user', message: { role: 'user', content } })
const text = (t: string): unknown => ({ type: 'assistant', message: { role: 'assistant', content: [{ type: 'text', text: t }] } })
const tool = (name: string): unknown => ({
  type: 'assistant',
  message: { role: 'assistant', content: [{ type: 'tool_use', id: 'x', name, input: {} }] },
})
const tgPrompt = (id: number): unknown =>
  prompt(`<channel source="labops-channel" source="telegram" chat_id="${OPERATOR_ID}" user_id="1" ts="t" message_id="${id}">\nпривет\n</channel>`)

describe('POST /hooks/fallback-reply', () => {
  test('неверный токен → 401, ничего не отправлено', async () => {
    process.env.TELEGRAM_WEBHOOK_TOKEN = WEBHOOK_TOKEN
    const h = await start()
    const p = transcript('s.jsonl', [tgPrompt(1), text('итог')])
    const resp = await post(h, { transcript_path: p }, 'wrong-token')
    expect(resp.status).toBe(401)
    expect(sent).toHaveLength(0)
  })

  test('без токена → 401', async () => {
    process.env.TELEGRAM_WEBHOOK_TOKEN = WEBHOOK_TOKEN
    const h = await start()
    expect((await post(h, { transcript_path: '/x.jsonl' }, null)).status).toBe(401)
  })

  test('неверный токен при выключенном флаге всё равно 401', async () => {
    process.env.TELEGRAM_WEBHOOK_TOKEN = WEBHOOK_TOKEN
    const h = await start({ enabled: false })
    expect((await post(h, { transcript_path: '/x.jsonl' }, 'wrong')).status).toBe(401)
  })

  test('флаг выключен → 503 и тишина', async () => {
    process.env.TELEGRAM_WEBHOOK_TOKEN = WEBHOOK_TOKEN
    const h = await start({ enabled: false })
    const p = transcript('s.jsonl', [tgPrompt(1), text('итог')])
    const resp = await post(h, { transcript_path: p })
    expect(resp.status).toBe(503)
    expect(await resp.json()).toEqual({ status: 'fallback_reply_disabled' })
    expect(sent).toHaveLength(0)
  })

  test('сервис не подключён → 503', async () => {
    process.env.TELEGRAM_WEBHOOK_TOKEN = WEBHOOK_TOKEN
    const h = await start({ enabled: true, wired: false })
    expect((await post(h, { transcript_path: '/x.jsonl' })).status).toBe(503)
  })

  test('ответа не было → sent, текст ушёл reply на входящее', async () => {
    process.env.TELEGRAM_WEBHOOK_TOKEN = WEBHOOK_TOKEN
    const h = await start()
    const p = transcript('s.jsonl', [tgPrompt(77), text('итог хода')])
    const resp = await post(h, { transcript_path: p, session_id: 's' })
    expect(resp.status).toBe(200)
    expect(await resp.json()).toEqual({ status: 'sent' })
    expect(sent).toHaveLength(1)
    expect(sent[0]?.chatId).toBe(OPERATOR_ID)
    expect(sent[0]?.replyTo).toBe(77)
    expect(sent[0]?.text).toContain('итог хода')
  })

  test('был reply → replied, тишина', async () => {
    process.env.TELEGRAM_WEBHOOK_TOKEN = WEBHOOK_TOKEN
    const h = await start()
    const p = transcript('s.jsonl', [tgPrompt(1), tool('mcp__labops-channel__reply'), text('готово')])
    expect(await (await post(h, { transcript_path: p })).json()).toEqual({ status: 'replied' })
    expect(sent).toHaveLength(0)
  })

  test('повторный Stop того же хода → duplicate, одна отправка', async () => {
    process.env.TELEGRAM_WEBHOOK_TOKEN = WEBHOOK_TOKEN
    const h = await start()
    const p = transcript('s.jsonl', [tgPrompt(5), text('итог')])
    expect(await (await post(h, { transcript_path: p, session_id: 's' })).json()).toEqual({ status: 'sent' })
    expect(await (await post(h, { transcript_path: p, session_id: 's' })).json()).toEqual({ status: 'duplicate' })
    expect(sent).toHaveLength(1)
  })

  test('ход не из Telegram → not_telegram, тишина', async () => {
    process.env.TELEGRAM_WEBHOOK_TOKEN = WEBHOOK_TOKEN
    const h = await start()
    const p = transcript('s.jsonl', [prompt('Новая задача из task-poller'), text('ответ')])
    expect(await (await post(h, { transcript_path: p })).json()).toEqual({ status: 'not_telegram' })
    expect(sent).toHaveLength(0)
  })

  test('путь вне корня → bad_path', async () => {
    process.env.TELEGRAM_WEBHOOK_TOKEN = WEBHOOK_TOKEN
    const h = await start()
    const outside = join(stateDir, 'outside.jsonl')
    writeFileSync(outside, JSON.stringify(tgPrompt(1)) + '\n' + JSON.stringify(text('x')) + '\n')
    expect(await (await post(h, { transcript_path: outside })).json()).toEqual({ status: 'bad_path' })
    expect(sent).toHaveLength(0)
  })

  test('некорректное тело → 400', async () => {
    process.env.TELEGRAM_WEBHOOK_TOKEN = WEBHOOK_TOKEN
    const h = await start()
    expect((await post(h, { session_id: 's' })).status).toBe(400)
    expect((await post(h, '{not json')).status).toBe(400)
  })

  test('сквозной: хук (реальный fetch) → роут → отправка, второй Stop — дубль', async () => {
    process.env.TELEGRAM_WEBHOOK_TOKEN = WEBHOOK_TOKEN
    const h = await start()
    const p = transcript('e2e.jsonl', [tgPrompt(9), text('сквозной итог')])
    const env = {
      TELEGRAM_FALLBACK_REPLY: '1',
      TELEGRAM_WEBHOOK_TOKEN: WEBHOOK_TOKEN,
      TELEGRAM_WEBHOOK_PORT: String(h.port),
    }
    const stdin = JSON.stringify({ transcript_path: p, session_id: 'e2e' })
    expect(await runFallbackHook(stdin, env)).toBe('sent')
    expect(await runFallbackHook(stdin, env)).toBe('duplicate')
    expect(sent).toHaveLength(1)
    expect(sent[0]?.replyTo).toBe(9)
  })
})
