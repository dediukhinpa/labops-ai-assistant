// Точные цели против НАСТОЯЩЕГО tmux: сосед с более длинным именем не страдает.
//
// Сервер tmux — только свой: TMUX_TMPDIR указывает во временный каталог, а
// TMUX/TMUX_PANE сняты, чтобы код под тестом (он зовёт голый `tmux`) не нашёл
// сокет основного сервера хоста, где живут агенты. Сессии создаём явным `-S` на
// тот же сокет, и первый тест проверяет, что код под тестом их видит, — иначе
// изоляция не сработала и остальные тесты падают, ничего не тронув: все цели
// точные, а таких имён на основном сервере нет.
//
// base-index и pane-base-index = 1, в сессии агента второе окно текущее, а в
// первом окне активна нижняя панель: так видно, что `^.{top-left}` находит
// панель claude там, где `=имя:` ушёл бы в текущее окно.

import { afterAll, beforeAll, describe, expect, test } from 'bun:test'
import { execFileSync, spawnSync } from 'node:child_process'
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

import { createTmuxRunner } from '../../src/channel/ensure-submit.js'
import type { MultichatPolicy } from '../../src/chats/policy-loader.js'
import { TmuxSessionPool, type PoolLogger } from '../../src/router/tmux-session-pool.js'

const HAS_TMUX = spawnSync('tmux', ['-V']).status === 0

const AGENT = 'tgpt-agent'
// Имя сессии агента — начало имени соседа: ровно случай labops-app / labops-app-<id>.
const AGENT_NEIGHBOUR = `${AGENT}-12345`
const CHAT_ID = '12345'
const CHAT_SESSION = `multichat-${CHAT_ID}`
// Id соседнего чата начинается с id нашего.
const NEIGHBOUR_CHAT_SESSION = 'multichat-1234567'
const PANE_WIDTH = '120'
const PANE_HEIGHT = '30'
const POLL_INTERVAL_MS = 50
const POLL_TIMEOUT_MS = 3000
const ISOLATED_ENV_KEYS = ['TMUX', 'TMUX_PANE', 'TMUX_TMPDIR'] as const

let tmpRoot = ''
let socketPath = ''
const savedEnv = new Map<string, string | undefined>()

// Окружение без признаков основного сервера: только наш TMUX_TMPDIR.
function isolatedEnv(): NodeJS.ProcessEnv {
  const env: NodeJS.ProcessEnv = { ...process.env, TMUX_TMPDIR: tmpRoot }
  delete env.TMUX
  delete env.TMUX_PANE
  return env
}

/** tmux строго на тестовом сокете (явный `-S`) — основной сервер недостижим. */
function tmuxOnTestSocket(args: readonly string[]): string {
  return execFileSync('tmux', ['-S', socketPath, ...args], {
    env: isolatedEnv(),
    encoding: 'utf8',
  })
}

function testSocketStatus(args: readonly string[]): number | null {
  return spawnSync('tmux', ['-S', socketPath, ...args], { env: isolatedEnv() }).status
}

function paneText(target: string): string {
  return tmuxOnTestSocket(['capture-pane', '-p', '-t', target])
}

async function waitFor(predicate: () => boolean): Promise<boolean> {
  const deadline = Date.now() + POLL_TIMEOUT_MS
  while (Date.now() < deadline) {
    if (predicate()) return true
    await new Promise((resolve) => setTimeout(resolve, POLL_INTERVAL_MS))
  }
  return predicate()
}

function newCatSession(name: string): void {
  tmuxOnTestSocket(['new-session', '-d', '-s', name, '-x', PANE_WIDTH, '-y', PANE_HEIGHT, 'cat'])
}

function quietLogger(): PoolLogger {
  return { info: () => {}, warn: () => {}, error: () => {} }
}

// Минимальная политика: пул читает только chats[chatId].idle_ttl_ms.
function makePolicy(chatId: string): MultichatPolicy {
  return {
    chats: { [chatId]: { idle_ttl_ms: 1_800_000 } as MultichatPolicy['chats'][string] },
  } as MultichatPolicy
}

describe.skipIf(!HAS_TMUX)('exact tmux targets on a real (isolated) tmux server', () => {
  beforeAll(() => {
    tmpRoot = mkdtempSync(join(tmpdir(), 'tgpt-'))
    const uid = process.getuid?.() ?? 0
    // Тот же путь, который tmux сам выводит из TMUX_TMPDIR для голого `tmux`.
    const socketDir = join(tmpRoot, `tmux-${uid}`)
    mkdirSync(socketDir, { mode: 0o700 })
    socketPath = join(socketDir, 'default')

    for (const key of ISOLATED_ENV_KEYS) savedEnv.set(key, process.env[key])
    process.env.TMUX_TMPDIR = tmpRoot
    delete process.env.TMUX
    delete process.env.TMUX_PANE

    const conf = join(tmpRoot, 'tmux.conf')
    writeFileSync(conf, 'set -g base-index 1\nset -g pane-base-index 1\n', 'utf8')
    // Первая команда поднимает сервер, поэтому -f действует на весь тест.
    tmuxOnTestSocket(['-f', conf, 'new-session', '-d', '-s', AGENT_NEIGHBOUR,
      '-x', PANE_WIDTH, '-y', PANE_HEIGHT, 'cat'])
    newCatSession(AGENT)
    tmuxOnTestSocket(['split-window', '-t', `=${AGENT}:1`, 'cat'])
    tmuxOnTestSocket(['new-window', '-t', `=${AGENT}`, 'cat'])
    newCatSession(NEIGHBOUR_CHAT_SESSION)
    newCatSession(CHAT_SESSION)
  })

  afterAll(() => {
    if (socketPath.length > 0) testSocketStatus(['kill-server'])
    for (const [key, value] of savedEnv) {
      if (value === undefined) delete process.env[key]
      else process.env[key] = value
    }
    if (tmpRoot.length > 0) rmSync(tmpRoot, { recursive: true, force: true })
  })

  test('guard: the code under test talks to the isolated server', async () => {
    const pane = await createTmuxRunner().capturePane(AGENT)
    expect(typeof pane).toBe('string')
  })

  test('tmux itself prefix-matches a bare target (the hazard we avoid)', () => {
    expect(testSocketStatus(['has-session', '-t', `${AGENT}-1`])).toBe(0)
  })

  test('ensure-submit fails instead of acting on a prefix-matched neighbour', async () => {
    const runner = createTmuxRunner()
    await expect(runner.capturePane(`${AGENT}-1`)).rejects.toThrow()
    await expect(runner.submitText(`${AGENT}-1`, 'must-not-arrive')).rejects.toThrow()
    expect(paneText(`=${AGENT_NEIGHBOUR}:1.1`)).not.toContain('must-not-arrive')
  })

  test('ensure-submit types into the first window top-left pane only', async () => {
    const probe = 'exact-target-probe'
    await createTmuxRunner().submitText(AGENT, probe)

    expect(await waitFor(() => paneText(`=${AGENT}:1.1`).includes(probe))).toBe(true)
    expect(paneText(`=${AGENT}:1.2`)).not.toContain(probe)
    expect(paneText(`=${AGENT}:2.1`)).not.toContain(probe)
    expect(paneText(`=${AGENT_NEIGHBOUR}:1.1`)).not.toContain(probe)
  })

  test('pool: a dead chat session is not revived by a chat id sharing its prefix', async () => {
    const stateDir = join(tmpRoot, 'state')
    mkdirSync(stateDir, { recursive: true })
    writeFileSync(
      join(stateDir, 'sessions.json'),
      JSON.stringify({
        version: 1,
        sessions: { [CHAT_ID]: { sessionName: CHAT_SESSION, spawnedAt: 1, lastMessageAt: 1 } },
      }),
      'utf8',
    )
    const pool = new TmuxSessionPool({
      policy: makePolicy(CHAT_ID),
      stateDir,
      workspaceDir: tmpRoot,
      logger: quietLogger(),
    })

    // Сессия чата жива — пул её видит и держит в карте.
    await pool.loadSessions()
    expect(await pool.isAlive(CHAT_SESSION)).toBe(true)

    // Сессия умерла. Голое имя всё ещё «находится» за счёт соседа.
    tmuxOnTestSocket(['kill-session', '-t', `=${CHAT_SESSION}`])
    expect(testSocketStatus(['has-session', '-t', CHAT_SESSION])).toBe(0)
    expect(await pool.isAlive(CHAT_SESSION)).toBe(false)

    // kill мёртвого чата не должен убить соседний.
    await pool.kill(CHAT_ID)
    expect(testSocketStatus(['has-session', '-t', `=${NEIGHBOUR_CHAT_SESSION}`])).toBe(0)
  })
})
