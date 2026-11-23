// Обработчик аварий не зацикливается на мёртвом stderr (EPIPE у Claude Code, EIO у Codex).
import { describe, expect, test } from 'bun:test'

import { createCrashHandler, guardSink, isBrokenSink } from '../../src/safety/crash-guard.js'

function errWithCode(code: string): Error {
  return Object.assign(new Error(code), { code })
}

interface Harness {
  writes: string[]
  exits: number[]
  stops: number
  handler: (kind: string, err: unknown) => void
  sink: ReturnType<typeof guardSink>
}

function harness(opts: { graceful: boolean; throwOnWrite?: unknown }): Harness {
  const h: Harness = {
    writes: [],
    exits: [],
    stops: 0,
    handler: () => undefined,
    sink: guardSink({ write: () => true }),
  }
  h.sink = guardSink({
    write: (chunk: string): boolean => {
      if (opts.throwOnWrite !== undefined) throw opts.throwOnWrite
      h.writes.push(chunk)
      return true
    },
  })
  h.handler = createCrashHandler({
    sink: h.sink,
    redact: line => line,
    exit: code => {
      h.exits.push(code)
    },
    gracefulStop: () => (opts.graceful ? () => { h.stops += 1 } : undefined),
  })
  return h
}

describe('isBrokenSink', () => {
  test('EPIPE, EIO и закрытый поток — приёмника нет', () => {
    for (const code of ['EPIPE', 'EIO', 'ERR_STREAM_DESTROYED', 'ERR_STREAM_WRITE_AFTER_END']) {
      expect(isBrokenSink(errWithCode(code))).toBe(true)
    }
  })
  test('обычные ошибки и не-объекты — нет', () => {
    expect(isBrokenSink(new Error('boom'))).toBe(false)
    expect(isBrokenSink(errWithCode('ENOENT'))).toBe(false)
    expect(isBrokenSink('EIO')).toBe(false)
    expect(isBrokenSink(null)).toBe(false)
  })
})

describe('createCrashHandler', () => {
  test('обычная ошибка пишется в лог, процесс живёт', () => {
    const h = harness({ graceful: false })
    h.handler('uncaught exception', new Error('boom'))
    expect(h.writes).toEqual(['telegram channel: uncaught exception: Error: boom\n'])
    expect(h.exits).toEqual([])
  })

  test('EIO без штатной остановки (Claude Code) — выход без записи', () => {
    const h = harness({ graceful: false })
    h.handler('uncaught exception', errWithCode('EIO'))
    expect(h.exits).toEqual([1])
    expect(h.writes).toEqual([])
    expect(h.sink.dead).toBe(true)
  })

  test('EIO у Codex — штатная остановка, stderr больше не трогаем', () => {
    const h = harness({ graceful: true })
    h.handler('stderr', errWithCode('EIO'))
    // Повторные ошибки той же природы не порождают записей (нет цикла).
    h.handler('stderr', errWithCode('EIO'))
    h.handler('uncaught exception', new Error('later'))
    expect(h.stops).toBe(2)
    expect(h.exits).toEqual([])
    expect(h.writes).toEqual([])
  })

  test('синхронный сбой записи — выход, а не повторный вход', () => {
    const h = harness({ graceful: true, throwOnWrite: new Error('weird') })
    h.handler('uncaught exception', new Error('boom'))
    expect(h.exits).toEqual([1])
  })

  test('guardSink: синхронный EIO помечает приёмник мёртвым', () => {
    const sink = guardSink({ write: () => { throw errWithCode('EIO') } })
    expect(() => sink.write('x')).toThrow()
    expect(sink.dead).toBe(true)
    expect(sink.write('y')).toBe(false)
  })
})
