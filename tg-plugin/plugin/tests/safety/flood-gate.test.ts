// Тесты FloodGate: единый учёт flood-бана Telegram с сохранением на диск.

import { afterEach, describe, expect, test } from 'bun:test'
import { existsSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

import {
  FloodGate,
  formatDuration,
  parseFlood429,
  TelegramFloodError,
} from '../../src/safety/flood-gate.js'

const MS = 1000
const BAN_S = 41_698
const dirs: string[] = []

function tmpDir(): string {
  const d = mkdtempSync(join(tmpdir(), 'flood-gate-'))
  dirs.push(d)
  return d
}

afterEach(() => {
  for (const d of dirs.splice(0)) rmSync(d, { recursive: true, force: true })
})

describe('FloodGate', () => {
  test('no ban by default', () => {
    const gate = new FloodGate({ now: () => 0 })
    expect(gate.isBanned('message')).toBe(false)
    expect(gate.remainingMs('message')).toBe(0)
  })

  test('recordBan blocks the group until now+retry_after, then expires', () => {
    let t = 1_000_000
    const gate = new FloodGate({ now: () => t })
    const until = gate.recordBan('message', 100)
    expect(until).toBe(1_000_000 + 100 * MS)
    expect(gate.remainingMs('message')).toBe(100 * MS)
    t += 99 * MS
    expect(gate.isBanned('message')).toBe(true)
    t += 1 * MS
    expect(gate.isBanned('message')).toBe(false)
  })

  test('message ban does not block reactions', () => {
    const gate = new FloodGate({ now: () => 0 })
    gate.recordBan('message', BAN_S)
    expect(gate.isBanned('message')).toBe(true)
    expect(gate.isBanned('reaction')).toBe(false)
  })

  test('a shorter retry_after never shortens a longer ban', () => {
    const gate = new FloodGate({ now: () => 0 })
    gate.recordBan('message', BAN_S)
    gate.recordBan('message', 5)
    expect(gate.remainingMs('message')).toBe(BAN_S * MS)
  })

  test('errorFor carries 429 shape, unban time and remaining seconds', () => {
    const gate = new FloodGate({ now: () => Date.UTC(2026, 10, 15, 19, 0, 0) })
    gate.recordBan('message', 39_600)
    const err = gate.errorFor('message')
    expect(err).toBeInstanceOf(TelegramFloodError)
    expect(err.error_code).toBe(429)
    expect(err.parameters.retry_after).toBe(39_600)
    expect(err.message).toContain('2026-11-16T06:00:00.000Z')
    expect(err.message).toContain('11h 0m')
  })

  test('ban is persisted and restored by a new instance (plugin restart)', () => {
    const path = join(tmpDir(), 'state', 'flood-ban.json')
    let t = 5_000_000
    const first = new FloodGate({ persistPath: path, now: () => t })
    first.recordBan('message', 3600)
    expect(existsSync(path)).toBe(true)
    expect(statSync(path).mode & 0o777).toBe(0o600)
    t += 60 * MS
    const second = new FloodGate({ persistPath: path, now: () => t })
    expect(second.remainingMs('message')).toBe((3600 - 60) * MS)
  })

  test('expired or garbage state file is ignored', () => {
    const dir = tmpDir()
    const path = join(dir, 'flood-ban.json')
    writeFileSync(path, JSON.stringify({ message: 10, reaction: 'x' }))
    expect(new FloodGate({ persistPath: path, now: () => 1_000 }).isBanned('message')).toBe(false)
    writeFileSync(path, '{not json')
    expect(new FloodGate({ persistPath: path, now: () => 1_000 }).isBanned('message')).toBe(false)
    expect(readFileSync(path, 'utf8')).toBe('{not json')
  })
})

describe('parseFlood429', () => {
  test('non-429 and non-objects give null', () => {
    expect(parseFlood429(null)).toBeNull()
    expect(parseFlood429('429')).toBeNull()
    expect(parseFlood429({ error_code: 400 })).toBeNull()
  })

  test('retry_after is read without clamping; missing/invalid falls back to 1s', () => {
    expect(parseFlood429({ error_code: 429, parameters: { retry_after: 41_698 } })).toEqual({
      retryAfterSec: 41_698,
    })
    expect(parseFlood429({ error_code: 429 })).toEqual({ retryAfterSec: 1 })
    expect(parseFlood429({ error_code: 429, parameters: { retry_after: 0 } })).toEqual({
      retryAfterSec: 1,
    })
  })
})

describe('formatDuration', () => {
  test('formats seconds, minutes and hours', () => {
    expect(formatDuration(15)).toBe('15s')
    expect(formatDuration(260)).toBe('4m 20s')
    expect(formatDuration(39_548)).toBe('10h 59m')
  })
})
