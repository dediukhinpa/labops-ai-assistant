// Тесты фоновой обёртки: схлопывание правок, лимит на чат, typing, flood-бан.

import { describe, expect, test } from 'bun:test'
import type { EditOpts, TelegramApi } from '../../src/channel/tools.js'
import type { Logger } from '../../src/log.js'
import { createBackgroundTelegramApi } from '../../src/safety/background-telegram-api.js'
import { FloodGate, TelegramFloodError } from '../../src/safety/flood-gate.js'

const EDIT_INTERVAL_MS = 5_000
const CHAT_GAP_MS = 3_000
const TYPING_INTERVAL_MS = 4_000
const BAN_SECONDS = 39_548

const quietLog: Logger = { debug() {}, info() {}, warn() {}, error() {} }

interface Recorded {
  method: string
  chatId: string
  messageId?: number
  text?: string
}

type TimerHandle = ReturnType<typeof setTimeout>

// Виртуальные часы + таймеры: tick(ms) двигает время и запускает созревшие таймеры.
class FakeTimers {
  t = 0
  private seq = 0
  private timers = new Map<number, { at: number; cb: () => void }>()
  now = (): number => this.t
  setTimer = (cb: () => void, ms: number): TimerHandle => {
    this.seq += 1
    this.timers.set(this.seq, { at: this.t + ms, cb })
    return this.seq as unknown as TimerHandle
  }
  clearTimer = (h: TimerHandle): void => {
    this.timers.delete(h as unknown as number)
  }
  get pending(): number {
    return this.timers.size
  }
  async tick(ms: number): Promise<void> {
    this.t += ms
    for (;;) {
      const due = [...this.timers.entries()]
        .filter(([, v]) => v.at <= this.t)
        .sort((a, b) => a[1].at - b[1].at)[0]
      if (due === undefined) break
      this.timers.delete(due[0])
      due[1].cb()
      await Promise.resolve()
    }
    await new Promise((r) => setImmediate(r))
  }
}

function makeBase(): { api: TelegramApi; calls: Recorded[] } {
  const calls: Recorded[] = []
  const api: TelegramApi = {
    async sendMessage(chatId, text) {
      calls.push({ method: 'sendMessage', chatId, text })
      return { message_id: calls.length }
    },
    async editMessageText(chatId, messageId, text) {
      calls.push({ method: 'editMessageText', chatId, messageId, text })
    },
    async setMessageReaction(chatId, messageId) {
      calls.push({ method: 'setMessageReaction', chatId, messageId })
    },
    async sendChatAction(chatId) {
      calls.push({ method: 'sendChatAction', chatId })
    },
    async sendDocument(chatId) {
      calls.push({ method: 'sendDocument', chatId })
      return { message_id: 1 }
    },
    async sendPhoto(chatId) {
      calls.push({ method: 'sendPhoto', chatId })
      return { message_id: 1 }
    },
    async downloadFile() {
      return { path: '/tmp/x', size: 0 }
    },
    async deleteMessage(chatId, messageId) {
      calls.push({ method: 'deleteMessage', chatId, messageId })
    },
  }
  return { api, calls }
}

function setup(): {
  clock: FakeTimers
  gate: FloodGate
  calls: Recorded[]
  api: TelegramApi
} {
  const clock = new FakeTimers()
  const gate = new FloodGate({ now: clock.now })
  const base = makeBase()
  const api = createBackgroundTelegramApi(base.api, gate, quietLog, {
    minEditIntervalMs: EDIT_INTERVAL_MS,
    chatEditGapMs: CHAT_GAP_MS,
    typingMinIntervalMs: TYPING_INTERVAL_MS,
    now: clock.now,
    setTimer: clock.setTimer,
    clearTimer: clock.clearTimer,
  })
  return { clock, gate, calls: base.calls, api }
}

const HTML: EditOpts = { parse_mode: 'HTML' }

describe('createBackgroundTelegramApi - edit coalescing', () => {
  test('first edit goes out at once', async () => {
    const { api, calls } = setup()
    await api.editMessageText('100', 1, 'a', HTML)
    expect(calls.map((c) => c.text)).toEqual(['a'])
  })

  test('a burst inside the interval collapses to one trailing edit, last text wins', async () => {
    const { api, calls, clock } = setup()
    await api.editMessageText('100', 1, 'v1', HTML)
    await api.editMessageText('100', 1, 'v2', HTML)
    await api.editMessageText('100', 1, 'v3', HTML)
    await api.editMessageText('100', 1, 'v4', HTML)
    expect(calls.length).toBe(1)
    await clock.tick(EDIT_INTERVAL_MS - 1)
    expect(calls.length).toBe(1)
    await clock.tick(1)
    expect(calls.map((c) => c.text)).toEqual(['v1', 'v4'])
  })

  test('100 hook-driven edits in 60 seconds produce at most one edit per interval', async () => {
    const { api, calls, clock } = setup()
    const STEP_MS = 600
    for (let i = 0; i < 100; i++) {
      await api.editMessageText('100', 1, `step ${i}`, HTML)
      await clock.tick(STEP_MS)
    }
    await clock.tick(EDIT_INTERVAL_MS)
    const edits = calls.filter((c) => c.method === 'editMessageText')
    // 60 s / 5 s = 12 intervals (+ first immediate + final trailing).
    expect(edits.length).toBeLessThanOrEqual(14)
    expect(edits[edits.length - 1]?.text).toBe('step 99')
  })

  test('different messages in one chat respect the per-chat gap', async () => {
    const { api, calls, clock } = setup()
    await api.editMessageText('100', 1, 'status', HTML)
    await api.editMessageText('100', 2, 'progress', HTML)
    await api.editMessageText('100', 3, 'tasks', HTML)
    expect(calls.length).toBe(1)
    await clock.tick(CHAT_GAP_MS)
    expect(calls.length).toBe(2)
    await clock.tick(CHAT_GAP_MS)
    expect(calls.length).toBe(3)
  })

  test('different chats do not delay each other', async () => {
    const { api, calls } = setup()
    await api.editMessageText('100', 1, 'a', HTML)
    await api.editMessageText('200', 1, 'b', HTML)
    expect(calls.length).toBe(2)
  })

  test('deleteMessage cancels the pending edit of that message', async () => {
    const { api, calls, clock } = setup()
    await api.editMessageText('100', 1, 'v1', HTML)
    await api.editMessageText('100', 1, 'v2', HTML)
    await api.deleteMessage('100', 1)
    await clock.tick(EDIT_INTERVAL_MS * 2)
    expect(calls.map((c) => c.method)).toEqual(['editMessageText', 'deleteMessage'])
    expect(clock.pending).toBe(0)
  })
})

describe('createBackgroundTelegramApi - typing', () => {
  test('sendChatAction is deduplicated inside the interval', async () => {
    const { api, calls, clock } = setup()
    await api.sendChatAction('100', 'typing')
    await api.sendChatAction('100', 'typing')
    expect(calls.length).toBe(1)
    await clock.tick(TYPING_INTERVAL_MS)
    await api.sendChatAction('100', 'typing')
    expect(calls.length).toBe(2)
  })
})

describe('createBackgroundTelegramApi - flood ban', () => {
  test('during a ban edits, typing and queued edits make no request', async () => {
    const { api, calls, clock, gate } = setup()
    await api.editMessageText('100', 1, 'v1', HTML)
    await api.editMessageText('100', 1, 'v2', HTML) // queued
    gate.recordBan('message', BAN_SECONDS)
    const edit = await api.editMessageText('100', 1, 'v3', HTML).catch((e: unknown) => e)
    const typing = await api.sendChatAction('100', 'typing').catch((e: unknown) => e)
    expect(edit).toBeInstanceOf(TelegramFloodError)
    expect(typing).toBeInstanceOf(TelegramFloodError)
    await clock.tick(EDIT_INTERVAL_MS * 2) // the queued edit would fire now
    expect(calls.map((c) => c.text)).toEqual(['v1'])
  })

  test('errors look like 429 so the status manager pauses its ticks', async () => {
    const { api, gate } = setup()
    gate.recordBan('message', BAN_SECONDS)
    const err = (await api.sendChatAction('100', 'typing').catch((e: unknown) => e)) as {
      error_code?: number
      parameters?: { retry_after?: number }
    }
    expect(err.error_code).toBe(429)
    expect(err.parameters?.retry_after).toBe(BAN_SECONDS)
  })

  test('after the ban expires background edits resume', async () => {
    const { api, calls, clock, gate } = setup()
    gate.recordBan('message', 10)
    await clock.tick(10_000)
    await api.editMessageText('100', 1, 'back', HTML)
    expect(calls.map((c) => c.text)).toEqual(['back'])
  })
})
