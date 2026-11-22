// Драйвер Codex против поддельного app-server: старт и восстановление нити, очередь входящих,
// доставка вдогонку, финальный ответ без дубля reply, события статуса, запросы сервера.

import { describe, expect, test } from 'bun:test'
import { mkdtempSync, readFileSync, writeFileSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'
import { Writable } from 'stream'

import { createLogger } from '../../src/log.js'
import { CodexDriver, type DriverEffects, type MemoryHook } from '../../src/harness/codex/driver.js'
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
  failResume = false
  failSteer = false

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
        return this.failResume ? fail('no such thread') : reply({ thread: { id: String(msg.params?.threadId) } })
      case 'turn/start':
        this.turnSeq += 1
        return reply({ turn: { id: `turn-${this.turnSeq}`, items: [], status: 'inProgress' } })
      case 'turn/steer':
        return this.failSteer ? fail('no active turn') : reply({ turnId: msg.params?.expectedTurnId })
      case 'turn/interrupt':
        return reply({})
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
  rebuilds: number
  asks: number
}

function setup(opts: { saved?: string; sessionContext?: string } = {}) {
  const dir = mkdtempSync(join(tmpdir(), 'codex-driver-'))
  const stateFile = join(dir, 'state', 'codex-thread.json')
  if (opts.saved !== undefined) {
    require('fs').mkdirSync(join(dir, 'state'), { recursive: true })
    writeFileSync(stateFile, JSON.stringify({ threadId: opts.saved }))
  }
  const server = new FakeServer()
  const rec: Recorded = { status: [], finals: [], memory: [], reads: [], rebuilds: 0, asks: 0 }
  const effects: DriverEffects = {
    status: async p => {
      rec.status.push(p)
    },
    deliverFinal: async (chatId, text) => {
      rec.finals.push({ chatId, text })
    },
    askUser: async (_chat, questions) => {
      rec.asks += 1
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
  }
  const driver = new CodexDriver({ connect: () => server, workspace: dir, stateFile, effects, log: silent })
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

  test('нить не восстановилась — новая', async () => {
    const { driver, server } = setup({ saved: 'thr-gone' })
    server.failResume = true
    await driver.start()
    expect(server.requests('thread/start')).toHaveLength(1)
    expect(driver.thread).toBe('thr-new')
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
