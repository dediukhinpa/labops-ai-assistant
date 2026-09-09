// Резолв «агент → куда и с каким bearer доставлять».
//
// Порт и токен живут в состоянии агента (channel.env + webhook-token) —
// диспетчер читает их оттуда, а не хранит свою копию: копия разъедется
// после первой же переустановки агента.

import { afterEach, beforeEach, describe, expect, test } from 'bun:test'
import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'

import { resolveAgentEndpoint } from '../../src/dispatcher/endpoints.js'

let stateRoot: string

function makeAgent(agentId: string, env: string, token: string | null): void {
  const dir = join(stateRoot, agentId, 'telegram')
  mkdirSync(dir, { recursive: true })
  writeFileSync(join(dir, 'channel.env'), env)
  if (token !== null) {
    const tokenPath = join(dir, 'webhook-token')
    writeFileSync(tokenPath, token)
    chmodSync(tokenPath, 0o600)
  }
}

beforeEach(() => {
  stateRoot = mkdtempSync(join(tmpdir(), 'labops-endpoints-'))
})

afterEach(() => {
  rmSync(stateRoot, { recursive: true, force: true })
})

describe('resolveAgentEndpoint', () => {
  test('builds a loopback url from the agent port and reads its bearer', () => {
    makeAgent('labops-app', 'TELEGRAM_BOT_TOKEN=x\nTELEGRAM_WEBHOOK_PORT=6002\n', 'secret-value')
    const ep = resolveAgentEndpoint(stateRoot, 'labops-app')
    expect(ep.url).toBe('http://127.0.0.1:6002/hooks/agent')
    expect(ep.token).toBe('secret-value')
  })

  test('trims the trailing newline of the token file', () => {
    makeAgent('labops-app', 'TELEGRAM_WEBHOOK_PORT=6002\n', 'secret-value\n')
    expect(resolveAgentEndpoint(stateRoot, 'labops-app').token).toBe('secret-value')
  })

  test('ignores a commented-out port line', () => {
    makeAgent(
      'labops-app',
      '#TELEGRAM_WEBHOOK_PORT=9999\nTELEGRAM_WEBHOOK_PORT=6002\n',
      'secret-value',
    )
    expect(resolveAgentEndpoint(stateRoot, 'labops-app').url).toContain(':6002/')
  })

  test('throws when the agent has no port configured', () => {
    makeAgent('labops-app', 'TELEGRAM_BOT_TOKEN=x\n', 'secret-value')
    expect(() => resolveAgentEndpoint(stateRoot, 'labops-app')).toThrow(/port/i)
  })

  test('throws when the bearer file is missing', () => {
    makeAgent('labops-app', 'TELEGRAM_WEBHOOK_PORT=6002\n', null)
    expect(() => resolveAgentEndpoint(stateRoot, 'labops-app')).toThrow(/token/i)
  })

  test('refuses an agent id with a path separator', () => {
    expect(() => resolveAgentEndpoint(stateRoot, '../developer')).toThrow(/agent id/i)
  })

  test('never puts the bearer into the error text', () => {
    makeAgent('labops-app', 'TELEGRAM_BOT_TOKEN=x\n', 'secret-value')
    try {
      resolveAgentEndpoint(stateRoot, 'labops-app')
      throw new Error('expected a throw')
    } catch (err) {
      expect(String(err)).not.toContain('secret-value')
    }
  })
})
