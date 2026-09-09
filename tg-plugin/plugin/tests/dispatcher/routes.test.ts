// Таблица маршрутов telegram_id → агент.
//
// Это единственное место, где решается, чей агент увидит сообщение.
// Ошибка здесь = чужая переписка, поэтому таблица валидируется строго,
// а не «как получится»: битый файл должен ломаться громко.

import { afterEach, beforeEach, describe, expect, test } from 'bun:test'
import { mkdtempSync, rmSync, writeFileSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'

import { RouteTable } from '../../src/dispatcher/routes.js'

let dir: string
let routesPath: string

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'labops-routes-'))
  routesPath = join(dir, 'routes.json')
})

afterEach(() => {
  rmSync(dir, { recursive: true, force: true })
})

function write(content: unknown): void {
  writeFileSync(routesPath, JSON.stringify(content))
}

describe('RouteTable', () => {
  test('resolves a known telegram id to its agent', () => {
    write({ routes: { '308749463': 'labops-app' } })
    expect(new RouteTable(routesPath).lookup(308749463)).toBe('labops-app')
  })

  test('returns undefined for an unknown sender', () => {
    write({ routes: { '308749463': 'labops-app' } })
    expect(new RouteTable(routesPath).lookup(999)).toBeUndefined()
  })

  test('missing file means nobody is routed, not a crash', () => {
    expect(new RouteTable(join(dir, 'absent.json')).lookup(1)).toBeUndefined()
  })

  test('picks up a user added while the dispatcher runs', () => {
    write({ routes: {} })
    const table = new RouteTable(routesPath)
    expect(table.lookup(308749463)).toBeUndefined()
    write({ routes: { '308749463': 'labops-app' } })
    expect(table.lookup(308749463)).toBe('labops-app')
  })

  test('keeps the last good table when the file turns into garbage', () => {
    write({ routes: { '308749463': 'labops-app' } })
    const table = new RouteTable(routesPath)
    expect(table.lookup(308749463)).toBe('labops-app')
    writeFileSync(routesPath, '{ not json')
    // Полуоткрытая дверь хуже закрытой: половина пользователей молча
    // потеряла бы агента. Держим последнюю валидную таблицу.
    expect(table.lookup(308749463)).toBe('labops-app')
  })

  test('rejects a non-numeric telegram id', () => {
    write({ routes: { 'not-an-id': 'labops-app' } })
    expect(new RouteTable(routesPath).lookup(308749463)).toBeUndefined()
  })

  test('rejects an agent id that could escape the state dir', () => {
    write({ routes: { '308749463': '../developer' } })
    expect(new RouteTable(routesPath).lookup(308749463)).toBeUndefined()
  })
})
