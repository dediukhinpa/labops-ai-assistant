// Пул multichat обращается к tmux только по точным целям сессии.
//
// Зачем: id одного чата может быть началом id другого (12345 и 1234567). С голым
// `-t multichat-12345` tmux, не найдя мёртвую сессию, берёт multichat-1234567:
// has-session объявляет мёртвый чат живым, а kill-session убивает чужой.
// Здесь проверяем argv через поддельный tmux на PATH; поведение настоящего
// tmux — в tests/tmux/real-tmux-targets.test.ts.

import { afterEach, beforeEach, describe, expect, test } from 'bun:test'
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

import type { MultichatPolicy } from '../../src/chats/policy-loader.js'
import { TmuxSessionPool, type PoolLogger } from '../../src/router/tmux-session-pool.js'

const CHAT_ID = '12345'
const SESSION = `multichat-${CHAT_ID}`

interface Fixture {
  tmpDir: string
  binDir: string
  callsLog: string
  stateDir: string
}

// Поддельный tmux: пишет каждый вызов одной строкой; has-session отвечает
// «нет сессии», чтобы пул прошёл путь создания.
function setupFixture(): Fixture {
  const tmpDir = mkdtempSync(join(tmpdir(), 'tmux-pool-targets-'))
  const binDir = join(tmpDir, 'bin')
  const callsLog = join(tmpDir, 'calls.log')
  const stateDir = join(tmpDir, 'state')
  mkdirSync(binDir, { recursive: true })
  const fake = `#!/bin/sh
printf '%s\\n' "$*" >> "${callsLog}"
[ "$1" = "has-session" ] && exit 1
exit 0
`
  const fakePath = join(binDir, 'tmux')
  writeFileSync(fakePath, fake, 'utf8')
  chmodSync(fakePath, 0o755)
  return { tmpDir, binDir, callsLog, stateDir }
}

function quietLogger(): PoolLogger {
  return { info: () => {}, warn: () => {}, error: () => {} }
}

function makePolicy(chatId: string): MultichatPolicy {
  return {
    chats: {
      [chatId]: { idle_ttl_ms: 1_800_000 } as MultichatPolicy['chats'][string],
    },
  } as MultichatPolicy
}

function readCalls(fx: Fixture): string[] {
  return readFileSync(fx.callsLog, 'utf8').trim().split('\n')
}

describe('TmuxSessionPool uses exact tmux session targets', () => {
  let fx: Fixture | undefined
  let originalPath: string | undefined

  beforeEach(() => {
    fx = setupFixture()
    originalPath = process.env.PATH
    process.env.PATH = `${fx.binDir}:${originalPath ?? ''}`
  })

  afterEach(() => {
    if (originalPath !== undefined) process.env.PATH = originalPath
    else delete process.env.PATH
    if (fx !== undefined) rmSync(fx.tmpDir, { recursive: true, force: true })
  })

  test('spawn probes with =name, creates with the bare name, kill uses =name', async () => {
    if (fx === undefined) throw new Error('fixture missing')
    const pool = new TmuxSessionPool({
      policy: makePolicy(CHAT_ID),
      stateDir: fx.stateDir,
      workspaceDir: '/tmp/ws',
      chatsBasePath: '/tmp/ws/chats',
      claudeBinary: 'claude',
      logger: quietLogger(),
    })

    await pool.getOrSpawn(CHAT_ID)
    await pool.kill(CHAT_ID)

    const calls = readCalls(fx)
    expect(calls[0]).toBe(`has-session -t =${SESSION}`)
    // `-s` задаёт ИМЯ новой сессии, а не цель: `=` здесь стал бы частью имени.
    expect(calls[1]?.startsWith(`new-session -d -s ${SESSION} `)).toBe(true)
    expect(calls[2]).toBe(`kill-session -t =${SESSION}`)
    expect(calls).toHaveLength(3)
  })

  test('loadSessions prunes via an exact has-session probe', async () => {
    if (fx === undefined) throw new Error('fixture missing')
    mkdirSync(fx.stateDir, { recursive: true })
    writeFileSync(
      join(fx.stateDir, 'sessions.json'),
      JSON.stringify({
        version: 1,
        sessions: { [CHAT_ID]: { sessionName: SESSION, spawnedAt: 1, lastMessageAt: 1 } },
      }),
      'utf8',
    )
    const pool = new TmuxSessionPool({
      policy: makePolicy(CHAT_ID),
      stateDir: fx.stateDir,
      workspaceDir: '/tmp/ws',
      logger: quietLogger(),
    })

    await pool.loadSessions()

    expect(readCalls(fx)).toEqual([`has-session -t =${SESSION}`])
  })

  test('an unsafe persisted session name is treated as dead without calling tmux', async () => {
    if (fx === undefined) throw new Error('fixture missing')
    const pool = new TmuxSessionPool({
      policy: makePolicy(CHAT_ID),
      stateDir: fx.stateDir,
      workspaceDir: '/tmp/ws',
      logger: quietLogger(),
    })

    expect(await pool.isAlive('multichat-1:0')).toBe(false)
    expect(() => readFileSync(fx?.callsLog ?? '', 'utf8')).toThrow()
  })
})
