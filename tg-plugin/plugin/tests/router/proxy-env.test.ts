// Сессии multichat получают ANTHROPIC_BASE_URL pii-proxy агента через chats/.claude/settings.json.

import { afterEach, beforeEach, describe, expect, test } from 'bun:test'
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

import {
  PII_MODE_FILE,
  TRANSCRIPT_KEEP_DAYS,
  chatsPiiMode,
  ensureChatsProxyEnv,
} from '../../src/router/proxy-env.js'

let root: string
let workspace: string
let chats: string
const target = (): string => join(chats, '.claude', 'settings.json')
const readTarget = (): Record<string, any> => JSON.parse(readFileSync(target(), 'utf8'))

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), 'proxy-env-'))
  workspace = join(root, 'ws')
  chats = join(workspace, 'chats')
  mkdirSync(workspace, { recursive: true })
})
afterEach(() => rmSync(root, { recursive: true, force: true }))

function agentSettings(env: Record<string, string>): void {
  writeFileSync(join(workspace, 'settings.json'), JSON.stringify({ model: 'x', env }))
}

describe('ensureChatsProxyEnv', () => {
  test('создаёт chats/.claude/settings.json с адресом прокси и телеметрией', () => {
    agentSettings({
      ANTHROPIC_BASE_URL: 'http://127.0.0.1:6311',
      DISABLE_ERROR_REPORTING: '1',
      DISABLE_TELEMETRY: '1',
      CLAUDE_CODE_AUTO_COMPACT_WINDOW: '400000',
    })
    expect(ensureChatsProxyEnv(workspace, chats)).toBe('proxy')
    const env = readTarget().env
    expect(env.ANTHROPIC_BASE_URL).toBe('http://127.0.0.1:6311')
    expect(env.DISABLE_ERROR_REPORTING).toBe('1')
    // ломает каналы в сессии собеседника - не наследуется
    expect(env.DISABLE_TELEMETRY).toBeUndefined()
    expect(env.CLAUDE_CODE_AUTO_COMPACT_WINDOW).toBeUndefined()
  })

  test('сохраняет хуки и прочие ключи существующего файла, повтор не меняет файл', () => {
    agentSettings({ ANTHROPIC_BASE_URL: 'http://127.0.0.1:6311' })
    mkdirSync(join(chats, '.claude'), { recursive: true })
    writeFileSync(target(), JSON.stringify({ hooks: { SessionStart: [] }, env: { FOO: 'bar' } }))
    ensureChatsProxyEnv(workspace, chats)
    const first = readFileSync(target(), 'utf8')
    const parsed = JSON.parse(first)
    expect(parsed.hooks).toEqual({ SessionStart: [] })
    expect(parsed.env.FOO).toBe('bar')
    expect(parsed.env.ANTHROPIC_BASE_URL).toBe('http://127.0.0.1:6311')
    ensureChatsProxyEnv(workspace, chats)
    expect(readFileSync(target(), 'utf8')).toBe(first)
  })

  test('обновляет адрес, если порт прокси у агента сменился', () => {
    agentSettings({ ANTHROPIC_BASE_URL: 'http://127.0.0.1:6311' })
    ensureChatsProxyEnv(workspace, chats)
    agentSettings({ ANTHROPIC_BASE_URL: 'http://127.0.0.1:6312' })
    ensureChatsProxyEnv(workspace, chats)
    expect(readTarget().env.ANTHROPIC_BASE_URL).toBe('http://127.0.0.1:6312')
  })

  test('у агента нет прокси - ничего не пишется', () => {
    agentSettings({ ANTHROPIC_BASE_URL: 'https://api.example.com' })
    expect(ensureChatsProxyEnv(workspace, chats)).toBe('none')
    rmSync(join(workspace, 'settings.json'))
    expect(ensureChatsProxyEnv(workspace, chats)).toBe('none')
  })

  test('битый chats/.claude/settings.json - ошибка, сессия не поднимается', () => {
    agentSettings({ ANTHROPIC_BASE_URL: 'http://127.0.0.1:6311' })
    mkdirSync(join(chats, '.claude'), { recursive: true })
    writeFileSync(target(), '{broken')
    expect(() => ensureChatsProxyEnv(workspace, chats)).toThrow()
  })
})

describe('cleanupPeriodDays сессий собеседников', () => {
  test('прописывается бессрочный срок, существующие ключи сохраняются', () => {
    agentSettings({ ANTHROPIC_BASE_URL: 'http://127.0.0.1:6311' })
    mkdirSync(join(chats, '.claude'), { recursive: true })
    writeFileSync(target(), JSON.stringify({ cleanupPeriodDays: 30, foo: 'bar' }))
    expect(ensureChatsProxyEnv(workspace, chats)).toBe('proxy')
    expect(readTarget().cleanupPeriodDays).toBe(TRANSCRIPT_KEEP_DAYS)
    expect(readTarget().foo).toBe('bar')
  })

  test('срок исправляется, даже когда прокси уже прописан', () => {
    agentSettings({ ANTHROPIC_BASE_URL: 'http://127.0.0.1:6311' })
    mkdirSync(join(chats, '.claude'), { recursive: true })
    writeFileSync(
      target(),
      JSON.stringify({ env: { ANTHROPIC_BASE_URL: 'http://127.0.0.1:6311' } }),
    )
    ensureChatsProxyEnv(workspace, chats)
    expect(readTarget().cleanupPeriodDays).toBe(TRANSCRIPT_KEEP_DAYS)
  })
})

describe('режим pii-proxy сессий собеседников', () => {
  const setMode = (mode: string): void => {
    mkdirSync(join(workspace, 'state'), { recursive: true })
    writeFileSync(join(workspace, PII_MODE_FILE), `${mode}\n`)
  }

  test('прокси упал (direct) - адрес прокси убран, остальное на месте', () => {
    agentSettings({ ANTHROPIC_BASE_URL: 'http://127.0.0.1:6311', DISABLE_ERROR_REPORTING: '1' })
    mkdirSync(join(chats, '.claude'), { recursive: true })
    writeFileSync(target(), JSON.stringify({ hooks: { Stop: [] }, env: { FOO: 'bar' } }))
    ensureChatsProxyEnv(workspace, chats)
    setMode('direct')
    expect(chatsPiiMode(workspace)).toBe('direct')
    expect(ensureChatsProxyEnv(workspace, chats)).toBe('direct')
    const t = readTarget()
    expect(t.env.ANTHROPIC_BASE_URL).toBeUndefined()
    expect(t.env.DISABLE_ERROR_REPORTING).toBe('1')
    expect(t.env.FOO).toBe('bar')
    expect(t.hooks).toEqual({ Stop: [] })
  })

  test('прокси поднялся - адрес возвращается', () => {
    agentSettings({ ANTHROPIC_BASE_URL: 'http://127.0.0.1:6311' })
    setMode('direct')
    ensureChatsProxyEnv(workspace, chats)
    setMode('proxy')
    expect(ensureChatsProxyEnv(workspace, chats)).toBe('proxy')
    expect(readTarget().env.ANTHROPIC_BASE_URL).toBe('http://127.0.0.1:6311')
  })

  test('нет файла режима или в нём мусор - через прокси; нет прокси у агента - none', () => {
    agentSettings({ ANTHROPIC_BASE_URL: 'http://127.0.0.1:6311' })
    expect(chatsPiiMode(workspace)).toBe('proxy')
    setMode('whatever')
    expect(chatsPiiMode(workspace)).toBe('proxy')
    agentSettings({})
    setMode('direct')
    expect(chatsPiiMode(workspace)).toBe('none')
  })
})
