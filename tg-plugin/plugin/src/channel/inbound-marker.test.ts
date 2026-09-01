import { describe, expect, test } from 'bun:test'
import { mkdtempSync, readFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

import { INBOUND_MARKER_FILE, recordInboundDelivery } from './inbound-marker.js'

const noopLog = {
  info: () => {},
  warn: () => {},
  error: () => {},
  debug: () => {},
} as unknown as Parameters<typeof recordInboundDelivery>[1]

describe('recordInboundDelivery', () => {
  test('пишет метку: время первой строкой, текст следом', () => {
    const dir = mkdtempSync(join(tmpdir(), 'inbound-marker-'))
    const before = Math.floor(Date.now() / 1000)

    const written = recordInboundDelivery('проверь статус', noopLog, {
      TELEGRAM_STATE_DIR: dir,
    })

    expect(written).toBe(true)
    const [ts, ...rest] = readFileSync(join(dir, INBOUND_MARKER_FILE), 'utf8').split('\n')
    expect(Number(ts)).toBeGreaterThanOrEqual(before)
    expect(rest.join('\n')).toBe('проверь статус')
  })

  test('многострочный текст сохраняется целиком', () => {
    const dir = mkdtempSync(join(tmpdir(), 'inbound-marker-'))

    recordInboundDelivery('первая\nвторая\nтретья', noopLog, { TELEGRAM_STATE_DIR: dir })

    const body = readFileSync(join(dir, INBOUND_MARKER_FILE), 'utf8').split('\n').slice(1)
    expect(body).toEqual(['первая', 'вторая', 'третья'])
  })

  test('без TELEGRAM_STATE_DIR молча ничего не пишет', () => {
    expect(recordInboundDelivery('текст', noopLog, {})).toBe(false)
  })

  // Доставка не должна зависеть от записи метки: несуществующий каталог —
  // не повод уронить обработку входящего.
  test('неписуемый каталог не бросает исключение', () => {
    expect(
      recordInboundDelivery('текст', noopLog, { TELEGRAM_STATE_DIR: '/nonexistent/dir' }),
    ).toBe(false)
  })
})
