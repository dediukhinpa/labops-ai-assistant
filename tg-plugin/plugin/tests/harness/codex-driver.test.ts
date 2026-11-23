// Драйвер Codex против поддельного app-server: старт и восстановление нити, очередь входящих,
// доставка вдогонку, финальный ответ без дубля reply, события статуса, запросы сервера.

import { describe, expect, test } from 'bun:test'
import { existsSync, mkdtempSync, readFileSync, writeFileSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'
import { Writable } from 'stream'

import { createLogger } from '../../src/log.js'
import {
  CodexDriver,
  type DeliveryHandle,
  type DriverEffects,
  type MemoryHook,
  type PiiMode,
} from '../../src/harness/codex/driver.js'
import type { LineTransport } from '../../src/harness/codex/rpc.js'

const silent = createLogger('test', { stream: new Writable({ write: (_c, _e, cb) => cb() }) })

interface Sent {
  id?: number | string
  method?: string
  params?: Record<string, unknown>
  result?: unknown
  error?: { code: number; message: string }
}

/** Поддельный app-server: отвечает на запросы по таблице, умеет слать события. */
class FakeServer implements LineTransport {
  readonly sent: Sent[] = []
  private lineCb: (line: string) => void = () => undefined
  private closeCb: (code: number | null) => void = () => undefined
  turnSeq = 0
  /** Как отказать в thread/resume: missing — «нити нет», other — прочая ошибка. */
  failResume: false | 'missing' | 'other' = false
  failTurnStart = false
  failSteer = false
  /** Чем закончить ход на turn/interrupt (как настоящий app-server); не задано — молчать. */
  interruptStatus: string | undefined

  write(line: string): void {
    const msg = JSON.parse(line) as Sent
    this.sent.push(msg)
    if (msg.method !== undefined && msg.id !== undefined) queueMicrotask(() => this.answer(msg))
  }
  onLine(cb: (line: string) => void): void {
    this.lineCb = cb
  }
  onClose(cb: (code: number | null) => void): void {
    this.closeCb = cb
  }
  kill(): void {
    this.closeCb(0)
  }

  emit(obj: Record<string, unknown>): void {
    this.lineCb(JSON.stringify({ jsonrpc: '2.0', ...obj }))
  }
  notify(method: string, params: Record<string, unknown>): void {
    this.emit({ method, params })
  }
  crash(): void {
    this.closeCb(1)
  }
  requests(method: string): Sent[] {
    return this.sent.filter(m => m.method === method && m.id !== undefined)
  }
  responseTo(id: number | string): Sent | undefined {
    return this.sent.find(m => m.id === id && m.method === undefined)
  }

  private answer(msg: Sent): void {
    const reply = (result: unknown): void => this.emit({ id: msg.id, result })
    const fail = (message: string): void => this.emit({ id: msg.id, error: { code: -32000, message } })
    switch (msg.method) {
      case 'initialize':
        return reply({ userAgent: 'fake' })
      case 'thread/start':
        return reply({ thread: { id: 'thr-new', path: '/tmp/rollout-new.jsonl' } })
      case 'thread/resume':
        if (this.failResume === 'missing') return fail(`no rollout found for thread id ${String(msg.params?.threadId)}`)
        if (this.failResume === 'other') return fail('mcp startup timed out')
        return reply({ thread: { id: String(msg.params?.threadId) } })
      case 'turn/start':
        if (this.failTurnStart) return fail('turn rejected')
        this.turnSeq += 1
        return reply({ turn: { id: `turn-${this.turnSeq}`, items: [], status: 'inProgress' } })
      case 'turn/steer':
        return this.failSteer ? fail('no active turn') : reply({ turnId: msg.params?.expectedTurnId })
      case 'turn/interrupt': {
        reply({})
        const status = this.interruptStatus
        if (status === undefined) return
        const turnId = String(msg.params?.turnId)
        return this.notify('turn/completed', {
          threadId: String(msg.params?.threadId),
          turn: { id: turnId, status, items: [] },
        })
      }
      default:
        return fail(`unexpected ${String(msg.method)}`)
    }
  }
}

interface Recorded {
  status: Array<Record<string, unknown>>
  finals: Array<{ chatId: string; text: string }>
  memory: Array<{ hook: MemoryHook; payload: Record<string, unknown> }>
  reads: Array<{ chatId: string; messageId: number }>
  dones: Array<{ chatId: string; messageId: number }>
  rebuilds: number
  asks: number
  notices: string[]
}

function setup(
  opts: {
    saved?: string
    sessionContext?: string
    piiMode?: () => PiiMode
    servers?: Array<{ mode: PiiMode; server: FakeServer }>
    /** Следующие запуски app-server не восстанавливают нить. */
    laterFailResume?: boolean
    /** Сохранённое состояние целиком (вместо saved). */
    savedState?: Record<string, unknown>
    /** Рабочая папка прошлого запуска (перезапуск драйвера). */
    dir?: string
    identityHash?: () => string
    now?: () => number
    turnStallMs?: number
    turnWatchMs?: number
    stallGraceMs?: number
    /** Задержка ответа человека на вопрос. */
    askDelayMs?: number
  } = {},
) {
  const dir = opts.dir ?? mkdtempSync(join(tmpdir(), 'codex-driver-'))
  const stateFile = join(dir, 'state', 'codex-thread.json')
  if (opts.saved !== undefined || opts.savedState !== undefined) {
    require('fs').mkdirSync(join(dir, 'state'), { recursive: true })
    writeFileSync(stateFile, JSON.stringify(opts.savedState ?? { threadId: opts.saved }))
  }
  const server = new FakeServer()
  const rec: Recorded = {
    status: [],
    finals: [],
    memory: [],
    reads: [],
    dones: [],
    rebuilds: 0,
    asks: 0,
    notices: [],
  }
  const effects: DriverEffects = {
    status: async p => {
      rec.status.push(p)
    },
    deliverFinal: async (chatId, text) => {
      rec.finals.push({ chatId, text })
    },
    askUser: async (_chat, questions) => {
      rec.asks += 1
      if (opts.askDelayMs !== undefined) await new Promise(r => setTimeout(r, opts.askDelayMs))
      return { answers: { [questions[0]!.id]: { answers: ['Да'] } } }
    },
    memory: async (hook, payload) => {
      rec.memory.push({ hook, payload })
      return hook === 'session-start' ? (opts.sessionContext ?? '') : ''
    },
    rebuildIdentity: async () => {
      rec.rebuilds += 1
    },
    markRead: async (chatId, messageId) => {
      rec.reads.push({ chatId, messageId })
    },
    markDone: async (chatId, messageId) => {
      rec.dones.push({ chatId, messageId })
    },
    notifyOperator: async text => {
      rec.notices.push(text)
    },
  }
  // С opts.servers каждый запуск app-server — новый поддельный сервер (смена режима pii-proxy).
  const connect = (mode: PiiMode): LineTransport => {
    if (opts.servers === undefined) return server
    const fresh = opts.servers.length === 0 ? server : new FakeServer()
    if (fresh !== server && opts.laterFailResume === true) fresh.failResume = 'other'
    opts.servers.push({ mode, server: fresh })
    return fresh
  }
  const driver = new CodexDriver({
    connect,
    workspace: dir,
    stateFile,
    effects,
    log: silent,
    ...(opts.piiMode !== undefined ? { piiMode: opts.piiMode, piiModePollMs: 5 } : {}),
    ...(opts.identityHash !== undefined ? { identityHash: opts.identityHash } : {}),
    ...(opts.now !== undefined ? { now: opts.now } : {}),
    ...(opts.turnStallMs !== undefined ? { turnStallMs: opts.turnStallMs } : {}),
    ...(opts.turnWatchMs !== undefined ? { turnWatchMs: opts.turnWatchMs } : {}),
    ...(opts.stallGraceMs !== undefined ? { stallGraceMs: opts.stallGraceMs } : {}),
  })
  return { driver, server, rec, stateFile, dir }
}

const tick = (): Promise<void> => new Promise(r => setTimeout(r, 5))

function msg(chatId: string, text: string, messageId?: number, extra: Record<string, string> = {}) {
  return {
    content: text,
    meta: {
      source: 'telegram',
      chat_id: chatId,
      ...(messageId !== undefined ? { message_id: String(messageId) } : {}),
      ...extra,
    },
  }
}

describe('старт нити', () => {
  test('новая нить: initialize → initialized → AGENTS.md → thread/start, id сохранён', async () => {
    const { driver, server, rec, stateFile } = setup()
    await driver.start()
    const methods = server.sent.map(m => m.method).filter(Boolean)
    expect(methods.slice(0, 3)).toEqual(['initialize', 'initialized', 'thread/start'])
    expect(rec.rebuilds).toBe(1)
    expect(server.requests('thread/start')[0]!.params).toMatchObject({ approvalPolicy: 'never' })
    expect(JSON.parse(readFileSync(stateFile, 'utf8')).threadId).toBe('thr-new')
    expect(rec.memory.some(m => m.hook === 'session-start')).toBe(true)
  })

  test('сохранённая нить восстанавливается, session-start не зовётся', async () => {
    const { driver, server, rec } = setup({ saved: 'thr-old' })
    await driver.start()
    expect(server.requests('thread/resume')[0]!.params).toMatchObject({ threadId: 'thr-old' })
    expect(server.requests('thread/start')).toHaveLength(0)
    expect(driver.thread).toBe('thr-old')
    expect(rec.memory.some(m => m.hook === 'session-start')).toBe(false)
  })

  test('нити нет (no rollout found) — новая, старый id в бэкапе', async () => {
    const { driver, server, dir } = setup({ saved: 'thr-gone' })
    server.failResume = 'missing'
    await driver.start()
    expect(server.requests('thread/start')).toHaveLength(1)
    expect(driver.thread).toBe('thr-new')
    const backup = readFileSync(join(dir, 'state', 'codex-thread.backup.jsonl'), 'utf8')
    expect(JSON.parse(backup.trim())).toMatchObject({ threadId: 'thr-gone', reason: 'not-found' })
  })
})

describe('входящие', () => {
  test('свободная нить: ход с контекстом session-start и текстом канала, 👀 на сообщение', async () => {
    const { driver, server, rec } = setup({ sessionContext: '## Журнал' })
    await driver.start()
    expect(await driver.deliver(msg('42', 'Привет', 7))).toBe(true)
    await tick()
    const start = server.requests('turn/start')[0]!
    const input = start.params!.input as Array<{ text: string }>
    expect(input[0]!.text).toBe('## Журнал')
    expect(input[1]!.text).toContain('chat_id="42"')
    expect(input[1]!.text).toContain('Привет')
    expect(rec.reads).toEqual([{ chatId: '42', messageId: 7 }])
  })

  test('тот же чат во время хода — turn/steer с expectedTurnId', async () => {
    const { driver, server, rec } = setup()
    await driver.start()
    await driver.deliver(msg('42', 'Первое', 1))
    await tick()
    await driver.deliver(msg('42', 'Дописка', 2))
    await tick()
    const steer = server.requests('turn/steer')[0]!
    expect(steer.params).toMatchObject({ threadId: 'thr-new', expectedTurnId: 'turn-1' })
    expect(server.requests('turn/start')).toHaveLength(1)
    expect(rec.reads.map(r => r.messageId)).toEqual([1, 2])
  })

  test('конец хода — 👌 на все его сообщения (как Stop-хук у Claude), до конца — нет', async () => {
    const { driver, server, rec } = setup()
    await driver.start()
    await driver.deliver(msg('42', 'Первое', 1))
    await tick()
    await driver.deliver(msg('42', 'Дописка', 2))
    await tick()
    expect(rec.dones).toEqual([])
    server.notify('turn/completed', {
      threadId: 'thr-new',
      turn: { id: 'turn-1', status: 'completed', items: [{ type: 'agentMessage', id: 'a', text: 'Ок' }] },
    })
    await tick()
    expect(rec.dones).toEqual([
      { chatId: '42', messageId: 1 },
      { chatId: '42', messageId: 2 },
    ])
  })

  test('ход с ошибкой тоже закрывается 👌; задача без message_id — без реакции', async () => {
    const { driver, server, rec } = setup()
    await driver.start()
    await driver.deliver(msg('42', 'Сломай', 5))
    await tick()
    server.notify('turn/completed', {
      threadId: 'thr-new',
      turn: { id: 'turn-1', status: 'failed', error: { message: 'boom' }, items: [] },
    })
    await tick()
    expect(rec.dones).toEqual([{ chatId: '42', messageId: 5 }])
    await driver.deliver(msg('42', 'задача'))
    await tick()
    server.notify('turn/completed', { threadId: 'thr-new', turn: { id: 'turn-2', status: 'completed', items: [] } })
    await tick()
    expect(rec.dones).toHaveLength(1)
  })

  test('другой чат во время хода ждёт конца хода', async () => {
    const { driver, server, rec } = setup()
    await driver.start()
    await driver.deliver(msg('42', 'Первое'))
    await tick()
    await driver.deliver(msg('99', 'Из группы'))
    await tick()
    expect(server.requests('turn/start')).toHaveLength(1)
    server.notify('turn/completed', {
      threadId: 'thr-new',
      turn: { id: 'turn-1', status: 'completed', items: [{ type: 'agentMessage', id: 'a', text: 'Ответ' }] },
    })
    await tick()
    expect(rec.finals).toEqual([{ chatId: '42', text: 'Ответ' }])
    const second = server.requests('turn/start')[1]!
    expect(JSON.stringify(second.params)).toContain('chat_id=\\"99\\"')
  })

  test('steer отклонён (ход закончился) — сообщение начинает следующий ход', async () => {
    const { driver, server } = setup()
    await driver.start()
    await driver.deliver(msg('42', 'Первое'))
    await tick()
    server.failSteer = true
    await driver.deliver(msg('42', 'Опоздавшее'))
    await tick()
    server.notify('turn/completed', { threadId: 'thr-new', turn: { id: 'turn-1', status: 'completed', items: [] } })
    await tick()
    expect(server.requests('turn/start')).toHaveLength(2)
  })

  test('без chat_id сообщение отклоняется', async () => {
    const { driver } = setup()
    await driver.start()
    expect(await driver.deliver({ content: 'x', meta: {} })).toBe(false)
  })

  test('/stop прерывает текущий ход', async () => {
    const { driver, server } = setup()
    await driver.start()
    await driver.deliver(msg('42', 'Долгая задача'))
    await tick()
    await driver.deliver(msg('42', '/stop', undefined, { command: 'stop' }))
    await tick()
    expect(server.requests('turn/interrupt')[0]!.params).toMatchObject({ turnId: 'turn-1' })
    expect(server.requests('turn/steer')).toHaveLength(0)
  })
})

describe('конец хода', () => {
  test('финальный ответ, уже отправленный reply, не дублируется', async () => {
    const { driver, server, rec } = setup()
    await driver.start()
    await driver.deliver(msg('42', 'Вопрос'))
    await tick()
    server.notify('item/completed', {
      threadId: 'thr-new',
      turnId: 'turn-1',
      item: {
        type: 'mcpToolCall',
        id: 'm1',
        server: 'labops-channel',
        tool: 'reply',
        status: 'completed',
        arguments: { chat_id: '42', text: 'Готово:  всё сделал' },
      },
    })
    server.notify('turn/completed', {
      threadId: 'thr-new',
      turn: { id: 'turn-1', status: 'completed', items: [{ type: 'agentMessage', id: 'a', text: 'Готово: всё сделал' }] },
    })
    await tick()
    expect(rec.finals).toHaveLength(0)
  })

  test('ошибка хода — оператору сообщение об ошибке; stop-хук получает запрос и ответ', async () => {
    const { driver, server, rec } = setup()
    await driver.start()
    await driver.deliver(msg('42', 'Сделай'))
    await tick()
    server.notify('turn/completed', {
      threadId: 'thr-new',
      turn: { id: 'turn-1', status: 'failed', error: { message: 'usage limit' }, items: [] },
    })
    await tick()
    expect(rec.finals[0]!.text).toContain('usage limit')
    const stop = rec.memory.find(m => m.hook === 'stop')!
    expect(String(stop.payload.last_user_message)).toContain('Сделай')
    expect(rec.status.at(-1)).toMatchObject({ hook_event_name: 'Stop', chatId: '42' })
  })

  test('прерванный ход — без сообщения оператору', async () => {
    const { driver, server, rec } = setup()
    await driver.start()
    await driver.deliver(msg('42', 'x'))
    await tick()
    server.notify('turn/completed', { threadId: 'thr-new', turn: { id: 'turn-1', status: 'interrupted', items: [] } })
    await tick()
    expect(rec.finals).toHaveLength(0)
  })
})

describe('события статуса', () => {
  test('команда и план идут в статус как хуки Claude', async () => {
    const { driver, server, rec } = setup()
    await driver.start()
    await driver.deliver(msg('42', 'x'))
    await tick()
    server.notify('item/started', {
      threadId: 'thr-new',
      turnId: 'turn-1',
      item: { type: 'commandExecution', id: 'c1', command: 'ls -la', status: 'inProgress' },
    })
    server.notify('turn/plan/updated', {
      threadId: 'thr-new',
      turnId: 'turn-1',
      plan: [{ step: 'Прочитать', status: 'inProgress' }],
    })
    await tick()
    expect(rec.status).toContainEqual(
      expect.objectContaining({ hook_event_name: 'PreToolUse', tool_name: 'Bash', tool_input: { command: 'ls -la' } }),
    )
    expect(rec.status).toContainEqual(
      expect.objectContaining({
        tool_name: 'TodoWrite',
        tool_input: { todos: [{ content: 'Прочитать', status: 'in_progress' }] },
      }),
    )
  })

  test('сжатие контекста вызывает precompact-хук', async () => {
    const { driver, server, rec } = setup()
    await driver.start()
    server.notify('item/started', { threadId: 'thr-new', turnId: 't', item: { type: 'contextCompaction', id: 'k' } })
    await tick()
    expect(rec.memory.some(m => m.hook === 'precompact')).toBe(true)
  })

  test('события чужой нити игнорируются', async () => {
    const { driver, server, rec } = setup()
    await driver.start()
    await driver.deliver(msg('42', 'x'))
    await tick()
    server.notify('turn/completed', {
      threadId: 'other',
      turn: { id: 'turn-1', status: 'completed', items: [{ type: 'agentMessage', id: 'a', text: 'чужое' }] },
    })
    await tick()
    expect(rec.finals).toHaveLength(0)
    expect(driver.busy).toBe(true)
  })
})

describe('запросы сервера', () => {
  test('подтверждение команды отклоняется, неизвестный метод — ошибка', async () => {
    const { driver, server } = setup()
    await driver.start()
    server.emit({ id: 'r1', method: 'item/commandExecution/requestApproval', params: {} })
    server.emit({ id: 'r2', method: 'attestation/generate', params: {} })
    await tick()
    expect(server.responseTo('r1')!.result).toEqual({ decision: 'decline' })
    expect(server.responseTo('r2')!.error!.code).toBe(-32601)
  })

  test('вопрос пользователю уходит кнопками в чат хода', async () => {
    const { driver, server, rec } = setup()
    await driver.start()
    await driver.deliver(msg('42', 'x'))
    await tick()
    server.emit({
      id: 'q1',
      method: 'item/tool/requestUserInput',
      params: {
        threadId: 'thr-new',
        turnId: 'turn-1',
        itemId: 'i1',
        questions: [{ id: 'q', header: 'H', question: 'Удалить?', isOther: false, isSecret: false, options: null }],
      },
    })
    await tick()
    expect(rec.asks).toBe(1)
    expect(server.responseTo('q1')!.result).toEqual({ answers: { q: { answers: ['Да'] } } })
  })
})

describe('жизненный цикл', () => {
  test('resetThread: session-end, новая нить с контекстом, id сохранён; во время хода — отказ', async () => {
    const { driver, server, rec, stateFile } = setup({ saved: 'thr-old', sessionContext: 'ctx' })
    await driver.start()
    await driver.deliver(msg('42', 'x'))
    await tick()
    await expect(driver.resetThread()).rejects.toThrow('busy')
    server.notify('turn/completed', { threadId: 'thr-old', turn: { id: 'turn-1', status: 'completed', items: [] } })
    await tick()
    await driver.resetThread()
    expect(driver.thread).toBe('thr-new')
    expect(JSON.parse(readFileSync(stateFile, 'utf8')).threadId).toBe('thr-new')
    const hooks = rec.memory.map(m => m.hook)
    expect(hooks.indexOf('session-end')).toBeLessThan(hooks.lastIndexOf('session-start'))
    await driver.deliver(msg('42', 'после сброса'))
    await tick()
    const input = server.requests('turn/start').at(-1)!.params!.input as Array<{ text: string }>
    expect(input[0]!.text).toBe('ctx')
  })

  test('смерть app-server сообщается подписчику', async () => {
    const { driver, server } = setup()
    await driver.start()
    let code: number | null | undefined
    driver.onExit(c => {
      code = c
    })
    server.crash()
    expect(code).toBe(1)
  })

  test('stop: session-end хук, затем app-server закрыт; новые сообщения не принимаются', async () => {
    const { driver, rec } = setup()
    await driver.start()
    await driver.stop()
    expect(rec.memory.at(-1)!.hook).toBe('session-end')
    expect(await driver.deliver(msg('42', 'x'))).toBe(false)
  })
})

describe('режим pii-proxy', () => {
  test('без файла режима — всегда через прокси, app-server один', async () => {
    const servers: Array<{ mode: PiiMode; server: FakeServer }> = []
    const { driver } = setup({ servers })
    await driver.start()
    await tick()
    expect(servers.map(s => s.mode)).toEqual(['proxy'])
    expect(driver.piiMode).toBe('proxy')
  })

  test('старт напрямую, если так записано', async () => {
    const servers: Array<{ mode: PiiMode; server: FakeServer }> = []
    const { driver } = setup({ servers, piiMode: () => 'direct' })
    await driver.start()
    expect(servers.map(s => s.mode)).toEqual(['direct'])
    expect(driver.piiMode).toBe('direct')
  })

  test('смена режима в простое: новый app-server, та же нить, драйвер жив', async () => {
    let mode: PiiMode = 'proxy'
    const servers: Array<{ mode: PiiMode; server: FakeServer }> = []
    const { driver } = setup({ saved: 'thr-old', servers, piiMode: () => mode })
    let exited = false
    driver.onExit(() => {
      exited = true
    })
    await driver.start()
    mode = 'direct'
    for (let i = 0; i < 20 && driver.piiMode !== 'direct'; i++) await tick()
    await tick()
    expect(servers.map(s => s.mode)).toEqual(['proxy', 'direct'])
    expect(driver.thread).toBe('thr-old')
    const resumed = servers[1]!.server.requests('thread/resume')
    expect(resumed.map(r => r.params!.threadId)).toEqual(['thr-old'])
    expect(exited).toBe(false)
    // Сообщение после смены идёт в новый app-server.
    await driver.deliver(msg('42', 'после смены'))
    await tick()
    expect(servers[1]!.server.requests('turn/start')).toHaveLength(1)
    expect(servers[0]!.server.requests('turn/start')).toHaveLength(0)
  })

  test('прокси упал посреди хода: turn/interrupt и повтор того же входа в той же нити', async () => {
    let mode: PiiMode = 'proxy'
    const servers: Array<{ mode: PiiMode; server: FakeServer }> = []
    const { driver, rec } = setup({ saved: 'thr-old', servers, piiMode: () => mode })
    await driver.start()
    servers[0]!.server.interruptStatus = 'interrupted'
    await driver.deliver(msg('42', 'длинная работа', 7))
    await tick()
    mode = 'direct'
    for (let i = 0; i < 40 && servers.length < 2; i++) await tick()
    for (let i = 0; i < 10; i++) await tick()
    const old = servers[0]!.server
    expect(old.requests('turn/interrupt').map(r => r.params!.turnId)).toEqual(['turn-1'])
    expect(servers.map(s => s.mode)).toEqual(['proxy', 'direct'])
    const fresh = servers[1]!.server
    expect(fresh.requests('thread/resume').map(r => r.params!.threadId)).toEqual(['thr-old'])
    const replay = fresh.requests('turn/start')
    expect(replay).toHaveLength(1)
    // Повторяется ровно тот вход, что ушёл в прерванный ход.
    const first = old.requests('turn/start')[0]!.params!
    expect(replay[0]!.params).toEqual({ ...first, threadId: 'thr-old' })
    expect(JSON.stringify(replay[0]!.params!.input)).toContain('длинная работа')
    // Прерванный ход — не ответ и не ошибка: пользователю ничего не уходит, «прочитано» — раз.
    expect(rec.finals).toHaveLength(0)
    expect(rec.reads).toEqual([{ chatId: '42', messageId: 7 }])
    // 👌 — не на прерванном ходе, а на конце повтора.
    expect(rec.dones).toEqual([])
    fresh.notify('turn/completed', { threadId: 'thr-old', turn: { id: 'turn-1', status: 'completed', items: [] } })
    await tick()
    expect(rec.dones).toEqual([{ chatId: '42', messageId: 7 }])
  })

  test('ход успел закончиться сам до прерывания — ответ один, повтора нет', async () => {
    let mode: PiiMode = 'proxy'
    const servers: Array<{ mode: PiiMode; server: FakeServer }> = []
    const { driver, rec } = setup({ saved: 'thr-old', servers, piiMode: () => mode })
    await driver.start()
    await driver.deliver(msg('42', 'короткий вопрос'))
    await tick()
    const old = servers[0]!.server
    old.interruptStatus = 'completed'
    old.notify('item/completed', {
      threadId: 'thr-old',
      item: { type: 'agentMessage', id: 'a1', text: 'готово' },
    })
    mode = 'direct'
    for (let i = 0; i < 40 && driver.piiMode !== 'direct'; i++) await tick()
    for (let i = 0; i < 10; i++) await tick()
    expect(servers.map(s => s.mode)).toEqual(['proxy', 'direct'])
    expect(servers[1]!.server.requests('turn/start')).toHaveLength(0)
    expect(rec.finals).toEqual([{ chatId: '42', text: 'готово' }])
  })

  test('ход упал на мёртвом прокси — без ошибки пользователю, повтор напрямую', async () => {
    let mode: PiiMode = 'proxy'
    const servers: Array<{ mode: PiiMode; server: FakeServer }> = []
    const { driver, rec } = setup({ saved: 'thr-old', servers, piiMode: () => mode })
    await driver.start()
    await driver.deliver(msg('42', 'посчитай'))
    await tick()
    mode = 'direct'
    servers[0]!.server.notify('turn/completed', {
      threadId: 'thr-old',
      turn: { id: 'turn-1', status: 'failed', items: [], error: { message: 'proxy down' } },
    })
    for (let i = 0; i < 40 && servers.length < 2; i++) await tick()
    for (let i = 0; i < 10; i++) await tick()
    expect(rec.finals).toHaveLength(0)
    expect(servers[1]!.server.requests('turn/start')).toHaveLength(1)
  })

  test('возврат через прокси не рвёт ход: смена ждёт его конца', async () => {
    let mode: PiiMode = 'direct'
    const servers: Array<{ mode: PiiMode; server: FakeServer }> = []
    const { driver } = setup({ saved: 'thr-old', servers, piiMode: () => mode })
    await driver.start()
    await driver.deliver(msg('42', 'длинная работа'))
    await tick()
    mode = 'proxy'
    for (let i = 0; i < 10; i++) await tick()
    expect(servers).toHaveLength(1)
    expect(servers[0]!.server.requests('turn/interrupt')).toHaveLength(0)
    expect(driver.busy).toBe(true)
    servers[0]!.server.notify('turn/completed', {
      threadId: 'thr-old',
      turn: { id: 'turn-1', status: 'completed', items: [] },
    })
    for (let i = 0; i < 20 && driver.piiMode !== 'proxy'; i++) await tick()
    expect(servers.map(s => s.mode)).toEqual(['direct', 'proxy'])
  })

  test('нить не восстановилась после смены — драйвер выходит для чистого рестарта', async () => {
    let mode: PiiMode = 'proxy'
    const servers: Array<{ mode: PiiMode; server: FakeServer }> = []
    const piiMode = (): PiiMode => mode
    const { driver } = setup({ saved: 'thr-old', servers, piiMode, laterFailResume: true })
    let code: number | null | undefined
    driver.onExit(c => {
      code = c
    })
    await driver.start()
    mode = 'direct'
    for (let i = 0; i < 20 && code === undefined; i++) await tick()
    expect(code).toBeNull()
  })
})

const waitFor = async (cond: () => boolean, tries = 100): Promise<void> => {
  for (let i = 0; i < tries && !cond(); i++) await tick()
}

describe('живучесть хода', () => {
  test('heartbeat: в простое по таймеру, во время хода — только по уведомлениям нити', async () => {
    let clock = 1_000_000
    const { driver, server, rec } = setup({ now: () => clock, turnWatchMs: 5 })
    await driver.start()
    const beats = (): number => rec.memory.filter(m => m.hook === 'heartbeat').length
    const startBeats = beats()
    clock += 61_000
    await waitFor(() => beats() > startBeats)
    expect(beats()).toBe(startBeats + 1)
    await driver.deliver(msg('42', 'долго'))
    await tick()
    const inTurn = beats()
    clock += 120_000
    for (let i = 0; i < 5; i++) await tick()
    // Ход молчит — таймер heartbeat не пишет, watchdog увидит зависание.
    expect(beats()).toBe(inTurn)
    // Глобальное уведомление (без threadId) — не признак жизни хода.
    server.notify('account/rateLimits/updated', { rateLimits: {} })
    await tick()
    expect(beats()).toBe(inTurn)
    server.notify('item/started', {
      threadId: 'thr-new',
      turnId: 'turn-1',
      item: { type: 'commandExecution', id: 'c1', command: 'ls', status: 'inProgress' },
    })
    await tick()
    expect(beats()).toBe(inTurn + 1)
  })

  test('нить молчит дольше предела — предупреждение в чат хода и turn/interrupt', async () => {
    const { driver, server, rec } = setup({ turnStallMs: 40, turnWatchMs: 5, stallGraceMs: 200 })
    let exited = false
    driver.onExit(() => {
      exited = true
    })
    await driver.start()
    server.interruptStatus = 'interrupted'
    await driver.deliver(msg('42', 'зависни'))
    await waitFor(() => server.requests('turn/interrupt').length > 0)
    await waitFor(() => !driver.busy)
    expect(server.requests('turn/interrupt')[0]!.params).toMatchObject({ turnId: 'turn-1' })
    expect(rec.finals[0]).toMatchObject({ chatId: '42' })
    expect(rec.finals[0]!.text).toContain('прерываю')
    expect(driver.busy).toBe(false)
    expect(exited).toBe(false)
  })

  test('прерывание не помогло — выход драйвера для перезапуска', async () => {
    const { driver, server, rec } = setup({ turnStallMs: 40, turnWatchMs: 5, stallGraceMs: 60 })
    let code: number | null | undefined
    driver.onExit(c => {
      code = c
    })
    await driver.start()
    await driver.deliver(msg('42', 'зависни намертво'))
    await waitFor(() => code !== undefined, 200)
    expect(server.requests('turn/interrupt')).toHaveLength(1)
    expect(code).toBeNull()
    expect(rec.finals.map(f => f.text).join('\n')).toContain('перезапускаю')
  })

  test('пока человек отвечает на вопрос, ход не считается зависшим', async () => {
    const { driver, server, rec } = setup({ turnStallMs: 40, turnWatchMs: 5, askDelayMs: 150 })
    await driver.start()
    await driver.deliver(msg('42', 'спроси меня'))
    await tick()
    server.emit({
      id: 'q1',
      method: 'item/tool/requestUserInput',
      params: {
        threadId: 'thr-new',
        turnId: 'turn-1',
        itemId: 'i1',
        questions: [{ id: 'q', header: 'H', question: '?', isOther: false, isSecret: false, options: null }],
      },
    })
    await waitFor(() => server.responseTo('q1') !== undefined, 100)
    expect(rec.asks).toBe(1)
    expect(server.requests('turn/interrupt')).toHaveLength(0)
  })
})

describe('доставка хотя бы раз', () => {
  function handle(): DeliveryHandle & { acks: number; releases: number } {
    const h = {
      acks: 0,
      releases: 0,
      ack: () => void (h.acks += 1),
      release: () => void (h.releases += 1),
    }
    return h
  }

  test('задача подтверждается только после конца хода, взявшего её', async () => {
    const { driver, server } = setup()
    await driver.start()
    const h = handle()
    await driver.deliver(msg('7', 'задача'), h)
    await tick()
    expect(h.acks).toBe(0)
    server.notify('turn/completed', { threadId: 'thr-new', turn: { id: 'turn-1', status: 'completed', items: [] } })
    await tick()
    expect(h.acks).toBe(1)
  })

  test('задача вдогонку (steer) подтверждается концом того же хода', async () => {
    const { driver, server } = setup()
    await driver.start()
    await driver.deliver(msg('7', 'первая'))
    await tick()
    const h = handle()
    await driver.deliver(msg('7', 'вдогонку'), h)
    await tick()
    expect(server.requests('turn/steer')).toHaveLength(1)
    expect(h.acks).toBe(0)
    server.notify('turn/completed', { threadId: 'thr-new', turn: { id: 'turn-1', status: 'completed', items: [] } })
    await tick()
    expect(h.acks).toBe(1)
  })

  test('app-server упал посреди хода — задача не подтверждена', async () => {
    const { driver, server } = setup()
    driver.onExit(() => undefined)
    await driver.start()
    const h = handle()
    await driver.deliver(msg('7', 'задача'), h)
    await tick()
    server.crash()
    await tick()
    expect(h.acks).toBe(0)
  })

  test('turn/start отклонён — задача отдаётся папке обратно (release)', async () => {
    const { driver, server } = setup()
    await driver.start()
    server.failTurnStart = true
    const h = handle()
    await driver.deliver(msg('7', 'задача'), h)
    await tick()
    expect(h.acks).toBe(0)
    expect(h.releases).toBe(1)
  })

  test('сообщения в очереди переживают перезапуск драйвера', async () => {
    const first = setup()
    await first.driver.start()
    await first.driver.deliver(msg('42', 'идёт ход', 1))
    await tick()
    await first.driver.deliver(msg('99', 'ждёт в очереди', 2))
    // Задача с подтверждением в файл очереди не пишется: её копия — файл задачи.
    await first.driver.deliver(msg('7', 'задача'), handle())
    await tick()
    const queueFile = join(first.dir, 'state', 'codex-queue.json')
    expect(readFileSync(queueFile, 'utf8')).toContain('ждёт в очереди')
    expect(readFileSync(queueFile, 'utf8')).not.toContain('задача')
    first.server.crash()

    const second = setup({ dir: first.dir, saved: 'thr-new' })
    await second.driver.start()
    await tick()
    const starts = second.server.requests('turn/start')
    expect(starts).toHaveLength(1)
    expect(JSON.stringify(starts[0]!.params)).toContain('ждёт в очереди')
    expect(second.rec.reads).toEqual([{ chatId: '99', messageId: 2 }])
    // Взят ходом — из файла очереди ушёл.
    expect(existsSync(queueFile)).toBe(false)
  })
})

describe('восстановление нити', () => {
  test('прочая ошибка resume — выход с ошибкой, сохранённый id не тронут, счётчик +1', async () => {
    const { driver, server, stateFile } = setup({ saved: 'thr-old' })
    server.failResume = 'other'
    await expect(driver.start()).rejects.toThrow('mcp startup timed out')
    expect(server.requests('thread/start')).toHaveLength(0)
    const state = JSON.parse(readFileSync(stateFile, 'utf8'))
    expect(state).toMatchObject({ threadId: 'thr-old', resumeFailures: 1 })
  })

  test('resume не удаётся раз за разом — после предела новая нить, бэкап и предупреждение', async () => {
    const { driver, server, stateFile, rec, dir } = setup({
      savedState: { threadId: 'thr-old', resumeFailures: 2 },
    })
    server.failResume = 'other'
    await driver.start()
    expect(driver.thread).toBe('thr-new')
    const state = JSON.parse(readFileSync(stateFile, 'utf8'))
    expect(state.threadId).toBe('thr-new')
    expect(state.resumeFailures).toBeUndefined()
    expect(readFileSync(join(dir, 'state', 'codex-thread.backup.jsonl'), 'utf8')).toContain('thr-old')
    expect(rec.notices).toHaveLength(1)
  })

  test('удачный resume обнуляет счётчик', async () => {
    const { driver, stateFile } = setup({ savedState: { threadId: 'thr-old', resumeFailures: 2 } })
    await driver.start()
    expect(JSON.parse(readFileSync(stateFile, 'utf8')).resumeFailures).toBeUndefined()
  })
})

describe('инструкции (AGENTS.md) и новая нить', () => {
  test('отпечаток изменился — brain-flush, новая нить с session-start, новый отпечаток', async () => {
    const { driver, server, rec, stateFile } = setup({
      savedState: { threadId: 'thr-old', identityHash: 'aaa' },
      identityHash: () => 'bbb',
      sessionContext: 'recap',
    })
    await driver.start()
    expect(server.requests('thread/resume')).toHaveLength(1)
    expect(server.requests('thread/start')).toHaveLength(1)
    expect(driver.thread).toBe('thr-new')
    const hooks = rec.memory.map(m => m.hook)
    expect(hooks.indexOf('session-end')).toBeGreaterThanOrEqual(0)
    expect(hooks.indexOf('session-end')).toBeLessThan(hooks.indexOf('session-start'))
    // Сброс — от имени старой нити.
    expect(rec.memory.find(m => m.hook === 'session-end')!.payload.session_id).toBe('thr-old')
    expect(JSON.parse(readFileSync(stateFile, 'utf8'))).toMatchObject({ threadId: 'thr-new', identityHash: 'bbb' })
    await driver.deliver(msg('42', 'x'))
    await tick()
    const input = server.requests('turn/start')[0]!.params!.input as Array<{ text: string }>
    expect(input[0]!.text).toBe('recap')
  })

  test('отпечаток тот же — нить продолжается', async () => {
    const { driver, server } = setup({
      savedState: { threadId: 'thr-old', identityHash: 'aaa' },
      identityHash: () => 'aaa',
    })
    await driver.start()
    expect(server.requests('thread/start')).toHaveLength(0)
    expect(driver.thread).toBe('thr-old')
  })

  test('отпечатка в состоянии нет (старая версия) — нить продолжается, отпечаток запоминается', async () => {
    const { driver, server, stateFile } = setup({ saved: 'thr-old', identityHash: () => 'ccc' })
    await driver.start()
    expect(server.requests('thread/start')).toHaveLength(0)
    expect(JSON.parse(readFileSync(stateFile, 'utf8')).identityHash).toBe('ccc')
  })

  test('отпечаток изменился, но resume упал — ошибка не маскируется новой нитью', async () => {
    const { driver, server, stateFile } = setup({
      savedState: { threadId: 'thr-old', identityHash: 'aaa' },
      identityHash: () => 'bbb',
    })
    server.failResume = 'other'
    await expect(driver.start()).rejects.toThrow()
    expect(server.requests('thread/start')).toHaveLength(0)
    expect(JSON.parse(readFileSync(stateFile, 'utf8'))).toMatchObject({ threadId: 'thr-old', identityHash: 'aaa' })
  })
})
