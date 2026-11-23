// Режим status.show_activity=false — плашка только «Печатает…».
//
// Зачем: поток правок плашки (мысли, инструменты, анимация точек) упирался
// в 429 от Telegram. В этом режиме события хуков (Claude и Codex приходят
// в StatusManager одинаково — через recordActivityByChatId) не должны
// порождать ни одного вызова Bot API, кроме пульса sendChatAction и
// удаления плашки по завершении. По умолчанию поведение прежнее.

import { describe, expect, test } from 'bun:test'

import { AppConfigSchema, type AppConfig } from '../../src/config.js'
import type { ActivityStatusEvent } from '../../src/hooks/claude-events.js'
import { createLogger } from '../../src/log.js'
import { StatusManager, type TelegramApiForStatus } from '../../src/status/status-manager.js'

const silentLog = createLogger('test', {
  stream: { write: () => true } as unknown as NodeJS.WritableStream,
})

const BOT_TOKEN = '1234567890:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
const CHAT_ID = '100000001'
const INBOUND_MESSAGE_ID = 7
// Дольше и пульса sendChatAction (4 с), и троттлинга инструментов (5 с).
const LONG_RUN_MS = 20_000

/** Набор событий хука: всё, что в обычном режиме переписывает плашку. */
const ACTIVITY_EVENTS: readonly ActivityStatusEvent[] = [
  { kind: 'session_start' },
  { kind: 'reasoning' },
  { kind: 'tool_start', toolName: 'Bash', toolInput: { command: 'bun test' }, toolUseId: 'u1' },
  { kind: 'tool_end', toolName: 'Bash', toolInput: {}, toolUseId: 'u1' },
  { kind: 'tool_start', toolName: 'Agent', toolInput: { description: 'x' }, toolUseId: 'u2' },
  {
    kind: 'tool_end',
    toolName: 'Agent',
    toolInput: {},
    toolUseId: 'u2',
    toolResult: 'готово',
  },
]

interface ApiCall {
  readonly kind: 'send' | 'edit' | 'delete' | 'chat_action'
  readonly text?: string
  readonly messageId?: number
}

interface FakeTimer {
  readonly deadline: number
  readonly cb: () => void
  fired: boolean
}

/** Поддельные часы: таймеры срабатывают только по advance(). */
class FakeClock {
  now = 0
  private readonly timers: FakeTimer[] = []
  readonly setTimer = (cb: () => void, ms: number): NodeJS.Timeout => {
    const t: FakeTimer = { deadline: this.now + ms, cb, fired: false }
    this.timers.push(t)
    return t as unknown as NodeJS.Timeout
  }
  readonly clearTimer = (handle: NodeJS.Timeout): void => {
    ;(handle as unknown as FakeTimer).fired = true
  }
  advance(ms: number): void {
    const end = this.now + ms
    for (;;) {
      const due = this.timers
        .filter((t) => !t.fired && t.deadline <= end)
        .sort((a, b) => a.deadline - b.deadline)[0]
      if (!due) break
      this.now = due.deadline
      due.fired = true
      due.cb()
    }
    this.now = end
  }
}

interface Harness {
  readonly mgr: StatusManager
  readonly clock: FakeClock
  readonly calls: ApiCall[]
}

/**
 * Менеджер на поддельных часах и записывающем Bot API.
 *
 * @param status Переопределения блока status поверх дефолтов схемы.
 * @returns Менеджер, часы и журнал вызовов.
 */
function makeHarness(status: Partial<AppConfig['status']>): Harness {
  const config = AppConfigSchema.parse({ bot_token: BOT_TOKEN, status })
  const clock = new FakeClock()
  const calls: ApiCall[] = []
  let nextId = 100
  const api: TelegramApiForStatus = {
    sendMessage: async (_chatId: string, text: string) => {
      const id = nextId++
      calls.push({ kind: 'send', text, messageId: id })
      return { message_id: id }
    },
    editMessageText: async (_chatId: string, messageId: number, text: string) => {
      calls.push({ kind: 'edit', text, messageId })
    },
    deleteMessage: async (_chatId: string, messageId: number) => {
      calls.push({ kind: 'delete', messageId })
    },
    sendChatAction: async () => {
      calls.push({ kind: 'chat_action' })
    },
  } as unknown as TelegramApiForStatus
  const mgr = new StatusManager({
    telegramApi: api,
    config,
    log: silentLog,
    policy: null,
    now: () => clock.now,
    setTimer: clock.setTimer,
    clearTimer: clock.clearTimer,
  })
  return { mgr, clock, calls }
}

/**
 * Прогнать полный ход: события хука, обновления через MCP-инструмент status
 * и долгую паузу, чтобы отработали все таймеры.
 *
 * @param h Тестовый стенд.
 */
async function runTurn(h: Harness): Promise<void> {
  for (const ev of ACTIVITY_EVENTS) {
    await h.mgr.recordActivityByChatId(CHAT_ID, ev)
  }
  await h.mgr.updateByChatId(CHAT_ID, { kind: 'thinking' })
  await h.mgr.updateByChatId(CHAT_ID, { kind: 'tool', toolName: 'Read' })
  h.clock.advance(LONG_RUN_MS)
}

/**
 * Число вызовов заданного вида.
 *
 * @param calls Журнал вызовов.
 * @param kind Вид вызова.
 * @returns Сколько раз он встретился.
 */
function count(calls: readonly ApiCall[], kind: ApiCall['kind']): number {
  return calls.filter((c) => c.kind === kind).length
}

describe('status.show_activity', () => {
  test('по умолчанию true — ход работы правит плашку, как раньше', async () => {
    const h = makeHarness({ suppress_typing_bubble: false })
    await h.mgr.start(CHAT_ID, INBOUND_MESSAGE_ID)
    await runTurn(h)

    expect(count(h.calls, 'send')).toBe(1)
    expect(count(h.calls, 'edit')).toBeGreaterThan(0)
    expect(h.calls.some((c) => c.kind === 'edit' && (c.text ?? '').includes('Думает'))).toBe(true)
  })

  test('по умолчанию true — подавленный бабл создаётся лениво из-за инструмента', async () => {
    const h = makeHarness({})
    await h.mgr.start(CHAT_ID, INBOUND_MESSAGE_ID)
    expect(count(h.calls, 'send')).toBe(0)
    await runTurn(h)
    expect(count(h.calls, 'send')).toBe(1)
  })

  test('false: плашка «Печатает…» без единой правки, пульс есть, удаляется по Stop', async () => {
    const h = makeHarness({ show_activity: false, suppress_typing_bubble: false })
    await h.mgr.start(CHAT_ID, INBOUND_MESSAGE_ID)
    await runTurn(h)

    const sends = h.calls.filter((c) => c.kind === 'send')
    expect(sends.length).toBe(1)
    expect(sends[0]?.text).toBe('<i>Печатает…</i>')
    expect(count(h.calls, 'edit')).toBe(0)
    // Начальный пульс + перевзводы каждые 4 с за 20 с.
    expect(count(h.calls, 'chat_action')).toBeGreaterThanOrEqual(5)

    await h.mgr.recordActivityByChatId(CHAT_ID, { kind: 'session_stop' })
    expect(h.mgr.isActive(CHAT_ID)).toBe(false)
    const deletes = h.calls.filter((c) => c.kind === 'delete')
    expect(deletes.length).toBe(1)
    expect(deletes[0]?.messageId).toBe(sends[0]?.messageId)
    expect(count(h.calls, 'edit')).toBe(0)
  })

  test('false + suppress_typing_bubble: бабла нет, только пульс', async () => {
    const h = makeHarness({ show_activity: false, suppress_typing_bubble: true })
    await h.mgr.start(CHAT_ID, INBOUND_MESSAGE_ID)
    await runTurn(h)
    await h.mgr.complete(CHAT_ID)

    expect(count(h.calls, 'chat_action')).toBeGreaterThan(0)
    expect(h.calls.every((c) => c.kind === 'chat_action')).toBe(true)
  })

  test('false: хук без плашки открывает «Печатает…», не блок активности', async () => {
    const h = makeHarness({ show_activity: false, suppress_typing_bubble: false })
    await runTurn(h)

    const sends = h.calls.filter((c) => c.kind === 'send')
    expect(sends.length).toBe(1)
    expect(sends[0]?.text).toBe('<i>Печатает…</i>')
    expect(count(h.calls, 'edit')).toBe(0)
    expect(h.mgr.isActive(CHAT_ID)).toBe(true)
  })

  test('false: «Остановлено» по команде оператора по-прежнему пишется', async () => {
    const h = makeHarness({ show_activity: false, suppress_typing_bubble: false })
    await h.mgr.start(CHAT_ID, INBOUND_MESSAGE_ID)
    await h.mgr.cancel(CHAT_ID, 'user stop')

    const edits = h.calls.filter((c) => c.kind === 'edit')
    expect(edits.length).toBe(1)
    expect(edits[0]?.text).toContain('Остановлено')
  })
})
