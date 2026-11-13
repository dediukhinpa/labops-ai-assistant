// TELEGRAM_API_ROOT / TELEGRAM_API_LOCAL_DIR: валидация и неизменность поведения по умолчанию.

import { afterEach, beforeEach, describe, expect, test } from 'bun:test'
import { mkdtempSync, rmSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'

import { RuntimeEnvSchema, loadConfig } from '../src/config.js'

const FAKE_TOKEN = '123456789:AAH-fake_test_token_with_at_least_thirty_chars'
let stateDir: string

beforeEach(() => {
  stateDir = mkdtempSync(join(tmpdir(), 'labops-channel-localapi-'))
})
afterEach(() => {
  rmSync(stateDir, { recursive: true, force: true })
})

function env(overrides: Record<string, string> = {}): NodeJS.ProcessEnv {
  return { TELEGRAM_BOT_TOKEN: FAKE_TOKEN, TELEGRAM_STATE_DIR: stateDir, ...overrides }
}

describe('local_api в loadConfig', () => {
  test('по умолчанию ключа local_api нет вообще (облачный режим)', () => {
    const cfg = loadConfig(env())
    expect(cfg.local_api).toBeUndefined()
    expect('local_api' in cfg).toBe(false)
  })

  test('пустые значения = не задано', () => {
    const cfg = loadConfig(env({ TELEGRAM_API_ROOT: '', TELEGRAM_API_LOCAL_DIR: '  ' }))
    expect(cfg.local_api).toBeUndefined()
  })

  test('корень без каталога данных', () => {
    const cfg = loadConfig(env({ TELEGRAM_API_ROOT: 'http://127.0.0.1:8081/' }))
    expect(cfg.local_api).toEqual({ api_root: 'http://127.0.0.1:8081' })
  })

  test('корень и каталог данных', () => {
    const cfg = loadConfig(env({
      TELEGRAM_API_ROOT: 'http://localhost:8081',
      TELEGRAM_API_LOCAL_DIR: '/var/lib/telegram-bot-api',
    }))
    expect(cfg.local_api).toEqual({
      api_root: 'http://localhost:8081',
      local_dir: '/var/lib/telegram-bot-api',
    })
  })

  test('каталог без корня ничего не включает', () => {
    const cfg = loadConfig(env({ TELEGRAM_API_LOCAL_DIR: '/var/lib/telegram-bot-api' }))
    expect(cfg.local_api).toBeUndefined()
  })

  test('невалидный корень роняет загрузку, токен в сообщение не попадает', () => {
    for (const bad of ['http://10.0.0.5:8081', 'https://api.telegram.org', 'ftp://x', 'garbage']) {
      let message = ''
      try {
        loadConfig(env({ TELEGRAM_API_ROOT: bad }))
      } catch (err) {
        message = err instanceof Error ? err.message : String(err)
      }
      expect(message).toContain('TELEGRAM_API_ROOT')
      expect(message).not.toContain(FAKE_TOKEN)
    }
  })

  test('относительный каталог данных отвергается', () => {
    expect(() =>
      loadConfig(env({ TELEGRAM_API_ROOT: 'http://127.0.0.1:8081', TELEGRAM_API_LOCAL_DIR: 'data' })),
    ).toThrow(/absolute/)
  })
})

describe('RuntimeEnvSchema', () => {
  test('нормализует корень и пропускает отсутствие значений', () => {
    const parsed = RuntimeEnvSchema.parse({
      TELEGRAM_BOT_TOKEN: FAKE_TOKEN,
      TELEGRAM_API_ROOT: ' http://127.0.0.1:8081/ ',
    })
    expect(parsed.TELEGRAM_API_ROOT).toBe('http://127.0.0.1:8081')
    expect(RuntimeEnvSchema.parse({ TELEGRAM_BOT_TOKEN: FAKE_TOKEN }).TELEGRAM_API_ROOT).toBeUndefined()
  })
})
