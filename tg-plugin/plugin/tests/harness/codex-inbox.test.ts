// Папка-очередь задач и заявка /reset для агента на Codex.

import { describe, expect, test } from 'bun:test'
import { existsSync, mkdirSync, mkdtempSync, readdirSync, utimesSync, writeFileSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'
import { Writable } from 'stream'

import { createLogger } from '../../src/log.js'
import type { ChannelEvent } from '../../src/channel/notify.js'
import { drainInbox, INBOX_DIR, serveResetRequest, RESET_MAX_WAIT_MS } from '../../src/harness/codex/inbox.js'

const silent = createLogger('test', { stream: new Writable({ write: (_c, _e, cb) => cb() }) })

function inbox(): { ws: string; dir: string } {
  const ws = mkdtempSync(join(tmpdir(), 'codex-inbox-'))
  const dir = join(ws, INBOX_DIR)
  mkdirSync(dir, { recursive: true })
  return { ws, dir }
}

describe('папка-очередь задач', () => {
  test('задачи доставляются по порядку имён в чат оператора и удаляются', async () => {
    const { ws, dir } = inbox()
    writeFileSync(join(dir, '002-b.json'), JSON.stringify({ text: 'вторая', source: 'task_board' }))
    writeFileSync(join(dir, '001-a.json'), JSON.stringify({ text: 'первая' }))
    writeFileSync(join(dir, '.003-tmp.json'), JSON.stringify({ text: 'ещё пишется' }))
    const got: ChannelEvent[] = []
    const n = await drainInbox({ workspace: ws, chatId: '7', log: silent, deliver: async e => (got.push(e), true) })
    expect(n).toBe(2)
    expect(got.map(e => e.content)).toEqual(['первая', 'вторая'])
    expect(got[0]!.meta).toMatchObject({ chat_id: '7', source: 'agent_router' })
    expect(got[1]!.meta.source).toBe('task_board')
    expect(readdirSync(dir)).toEqual(['.003-tmp.json'])
  })

  test('драйвер не принял — файл остаётся для повтора', async () => {
    const { ws, dir } = inbox()
    writeFileSync(join(dir, '001.json'), JSON.stringify({ text: 'x' }))
    const n = await drainInbox({ workspace: ws, chatId: '7', log: silent, deliver: async () => false })
    expect(n).toBe(0)
    expect(existsSync(join(dir, '001.json'))).toBe(true)
  })

  test('битый файл выбрасывается, остальные идут', async () => {
    const { ws, dir } = inbox()
    writeFileSync(join(dir, '001.json'), 'not json')
    writeFileSync(join(dir, '002.json'), JSON.stringify({ text: 'ok' }))
    const got: string[] = []
    await drainInbox({ workspace: ws, chatId: '7', log: silent, deliver: async e => (got.push(e.content), true) })
    expect(got).toEqual(['ok'])
    expect(readdirSync(dir)).toEqual([])
  })
})

describe('заявка /reset', () => {
  function request(chat = '42'): string {
    const dir = mkdtempSync(join(tmpdir(), 'codex-reset-'))
    const path = join(dir, 'reset.request')
    writeFileSync(path, chat)
    return path
  }

  test('нить свободна — сброс и ответ в чат заявки', async () => {
    const path = request()
    let resets = 0
    const sent: string[] = []
    const served = await serveResetRequest({
      requestPath: path,
      busy: () => false,
      reset: async () => void (resets += 1),
      notify: async (chat, text) => void sent.push(`${chat}:${text}`),
      log: silent,
    })
    expect(served).toBe(true)
    expect(resets).toBe(1)
    expect(sent[0]).toStartWith('42:✅')
    expect(existsSync(path)).toBe(false)
  })

  test('идёт ход — заявка ждёт', async () => {
    const path = request()
    const served = await serveResetRequest({
      requestPath: path,
      busy: () => true,
      reset: async () => undefined,
      notify: async () => undefined,
      log: silent,
    })
    expect(served).toBe(false)
    expect(existsSync(path)).toBe(true)
  })

  test('ход не закончился за предел ожидания — заявка отменяется с объяснением', async () => {
    const path = request()
    const old = (Date.now() - RESET_MAX_WAIT_MS - 1000) / 1000
    utimesSync(path, old, old)
    let resets = 0
    const sent: string[] = []
    await serveResetRequest({
      requestPath: path,
      busy: () => true,
      reset: async () => void (resets += 1),
      notify: async (_c, text) => void sent.push(text),
      log: silent,
    })
    expect(resets).toBe(0)
    expect(sent[0]).toContain('отменён')
    expect(existsSync(path)).toBe(false)
  })

  test('нет заявки — ничего', async () => {
    const served = await serveResetRequest({
      requestPath: '/nonexistent/reset.request',
      busy: () => false,
      reset: async () => undefined,
      notify: async () => undefined,
      log: silent,
    })
    expect(served).toBe(false)
  })
})
