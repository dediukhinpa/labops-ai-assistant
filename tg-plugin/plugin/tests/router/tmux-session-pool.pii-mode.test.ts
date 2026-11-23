// Сессии multichat следуют режиму pii-proxy агента (решение владельца 23.11.2026): прокси упал —
// сессия поднимается напрямую, прокси поднялся — снова через прокси. Живая сессия в старом
// режиме закрывается только между ходами, следующее сообщение поднимет её в нужном.
// tmux — поддельный скрипт на PATH; экран сессии задаёт файл pane.txt.

import { afterEach, beforeEach, describe, expect, test } from 'bun:test'
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

import type { MultichatPolicy } from '../../src/chats/policy-loader.js'
import { PII_MODE_FILE } from '../../src/router/proxy-env.js'
import { TmuxSessionPool, type PoolLogger } from '../../src/router/tmux-session-pool.js'

const CHAT_ID = '777'
const PROXY_URL = 'http://127.0.0.1:6311'

interface Fixture {
  root: string
  binDir: string
  calls: string
  pane: string
  workspace: string
  chats: string
}

// has-session: живой, если сессия создана и не убита; capture-pane печатает pane.txt.
function setupFixture(): Fixture {
  const root = mkdtempSync(join(tmpdir(), 'pool-pii-mode-'))
  const binDir = join(root, 'bin')
  const calls = join(root, 'calls.log')
  const pane = join(root, 'pane.txt')
  const alive = join(root, 'alive')
  const workspace = join(root, 'ws')
  const chats = join(workspace, 'chats')
  mkdirSync(binDir, { recursive: true })
  mkdirSync(join(workspace, 'state'), { recursive: true })
  writeFileSync(
    join(workspace, 'settings.json'),
    JSON.stringify({ env: { ANTHROPIC_BASE_URL: PROXY_URL } }),
  )
  writeFileSync(pane, '❯ \n')
  const fake = `#!/bin/sh
printf '%s\\n' "$*" >> "${calls}"
case "$1" in
  has-session) [ -e "${alive}" ] || exit 1 ;;
  new-session) : > "${alive}" ;;
  kill-session) rm -f "${alive}" ;;
  capture-pane) cat "${pane}" ;;
esac
exit 0
`
  writeFileSync(join(binDir, 'tmux'), fake, 'utf8')
  chmodSync(join(binDir, 'tmux'), 0o755)
  return { root, binDir, calls, pane, workspace, chats }
}

const quiet: PoolLogger = { info: () => {}, warn: () => {}, error: () => {} }

function makePool(fx: Fixture): TmuxSessionPool {
  return new TmuxSessionPool({
    policy: {
      chats: { [CHAT_ID]: { idle_ttl_ms: 1_800_000 } as MultichatPolicy['chats'][string] },
    } as unknown as MultichatPolicy,
    stateDir: join(fx.root, 'state'),
    workspaceDir: fx.workspace,
    chatsBasePath: fx.chats,
    claudeBinary: 'claude',
    logger: quiet,
  })
}

const setMode = (fx: Fixture, mode: string): void =>
  writeFileSync(join(fx.workspace, PII_MODE_FILE), `${mode}\n`)
const chatsUrl = (fx: Fixture): unknown =>
  JSON.parse(readFileSync(join(fx.chats, '.claude', 'settings.json'), 'utf8')).env
    ?.ANTHROPIC_BASE_URL
const killed = (fx: Fixture): number =>
  readFileSync(fx.calls, 'utf8').split('\n').filter(l => l.startsWith('kill-session')).length

describe('TmuxSessionPool и режим pii-proxy', () => {
  let fx: Fixture
  let originalPath: string | undefined

  beforeEach(() => {
    fx = setupFixture()
    originalPath = process.env.PATH
    process.env.PATH = `${fx.binDir}:${originalPath ?? ''}`
  })
  afterEach(() => {
    if (originalPath !== undefined) process.env.PATH = originalPath
    rmSync(fx.root, { recursive: true, force: true })
  })

  test('прокси упал: сессия закрывается между ходами и поднимается напрямую', async () => {
    const pool = makePool(fx)
    await pool.getOrSpawn(CHAT_ID)
    expect(chatsUrl(fx)).toBe(PROXY_URL)

    setMode(fx, 'direct')
    // Ход идёт — не рвём.
    writeFileSync(fx.pane, '✻ Working… (5s · esc to interrupt)\n')
    await pool.runIdleCheck()
    expect(killed(fx)).toBe(0)
    // Ход кончился — сессия закрыта, следующая поднимается без адреса прокси.
    writeFileSync(fx.pane, '❯ \n')
    await pool.runIdleCheck()
    expect(killed(fx)).toBe(1)
    await pool.getOrSpawn(CHAT_ID)
    expect(chatsUrl(fx)).toBeUndefined()
    // Режим совпадает — повторная проверка ничего не трогает.
    await pool.runIdleCheck()
    expect(killed(fx)).toBe(1)
  })

  test('прокси поднялся: сессия снова идёт через прокси', async () => {
    setMode(fx, 'direct')
    const pool = makePool(fx)
    await pool.getOrSpawn(CHAT_ID)
    expect(chatsUrl(fx)).toBeUndefined()
    setMode(fx, 'proxy')
    await pool.runIdleCheck()
    expect(killed(fx)).toBe(1)
    await pool.getOrSpawn(CHAT_ID)
    expect(chatsUrl(fx)).toBe(PROXY_URL)
  })
})
