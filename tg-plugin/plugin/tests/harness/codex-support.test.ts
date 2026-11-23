// MCP канала по HTTP, окружение и аргументы codex app-server, хуки памяти, вопросы кнопками.

import { describe, expect, test } from 'bun:test'
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from 'fs'
import { createServer } from 'http'
import type { AddressInfo } from 'net'
import { tmpdir } from 'os'
import { join } from 'path'

import { Client } from '@modelcontextprotocol/sdk/client/index.js'
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js'

import { createMcpHttpHandler, CHANNEL_TOKEN_ENV } from '../../src/harness/codex/mcp-http.js'
import {
  appServerArgs,
  codexChildEnv,
  codexHarnessEnabled,
  instructionsHash,
  itemStallFromEnv,
  piiModeReader,
  turnStallFromEnv,
} from '../../src/harness/codex/bootstrap.js'
import { runMemoryHook } from '../../src/harness/codex/memory-hooks.js'
import { mapItemToTool, replyTextOf } from '../../src/harness/codex/events.js'

async function withMcpServer(
  token: string,
  fn: (url: string, calls: Array<{ name: string; args: unknown }>) => Promise<void>,
): Promise<void> {
  const calls: Array<{ name: string; args: unknown }> = []
  const handler = createMcpHttpHandler({
    name: 'labops-channel',
    version: '1.0.0',
    instructions: 'test',
    token,
    handlers: {
      listTools: () => [{ name: 'reply', description: 'r', inputSchema: { type: 'object', properties: {} } }],
      callTool: async req => {
        calls.push({ name: req.params.name, args: req.params.arguments })
        return { content: [{ type: 'text', text: 'sent' }] }
      },
    },
  })
  const http = createServer((req, res) => void handler(req, res))
  await new Promise<void>(r => http.listen(0, '127.0.0.1', r))
  const { port } = http.address() as AddressInfo
  try {
    await fn(`http://127.0.0.1:${port}/mcp`, calls)
  } finally {
    await new Promise<void>(r => http.close(() => r()))
  }
}

describe('MCP канала по HTTP', () => {
  test('клиент SDK видит инструменты и вызывает reply по токену', async () => {
    await withMcpServer('secret-token', async (url, calls) => {
      const client = new Client({ name: 't', version: '0' })
      await client.connect(
        new StreamableHTTPClientTransport(new URL(url), {
          requestInit: { headers: { Authorization: 'Bearer secret-token' } },
        }),
      )
      const tools = await client.listTools()
      expect(tools.tools.map(t => t.name)).toEqual(['reply'])
      const res = await client.callTool({ name: 'reply', arguments: { chat_id: '42', text: 'hi' } })
      expect(res.content).toEqual([{ type: 'text', text: 'sent' }])
      expect(calls).toEqual([{ name: 'reply', args: { chat_id: '42', text: 'hi' } }])
      await client.close()
    })
  })

  test('без токена или с чужим — 401', async () => {
    await withMcpServer('secret-token', async url => {
      const body = JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/list', params: {} })
      const headers = { 'content-type': 'application/json', accept: 'application/json, text/event-stream' }
      expect((await fetch(url, { method: 'POST', body, headers })).status).toBe(401)
      const wrong = await fetch(url, { method: 'POST', body, headers: { ...headers, Authorization: 'Bearer nope' } })
      expect(wrong.status).toBe(401)
    })
  })
})

describe('запуск codex', () => {
  test('секреты плагина не попадают в окружение codex, токен канала попадает', () => {
    const env = codexChildEnv(
      { PATH: '/bin', TELEGRAM_BOT_TOKEN: 'bot', TELEGRAM_WEBHOOK_TOKEN: 'wh', AGENT_BEARER: 'b' },
      'chan',
    )
    expect(env.TELEGRAM_BOT_TOKEN).toBeUndefined()
    expect(env.TELEGRAM_WEBHOOK_TOKEN).toBeUndefined()
    expect(env.AGENT_BEARER).toBe('b')
    expect(env[CHANNEL_TOKEN_ENV]).toBe('chan')
  })

  test('app-server получает адрес MCP канала флагами -c', () => {
    expect(appServerArgs('127.0.0.1', 6003)).toEqual([
      'app-server',
      '-c',
      'mcp_servers.labops-channel.url="http://127.0.0.1:6003/mcp"',
      '-c',
      `mcp_servers.labops-channel.bearer_token_env_var="${CHANNEL_TOKEN_ENV}"`,
    ])
  })

  test('напрямую — тот же провайдер с адресом бэкенда; через прокси — флаги прежние', () => {
    expect(appServerArgs('127.0.0.1', 6003, 'proxy')).toEqual(appServerArgs('127.0.0.1', 6003))
    expect(appServerArgs('127.0.0.1', 6003, 'direct')).toEqual([
      ...appServerArgs('127.0.0.1', 6003),
      '-c',
      'model_providers.labops-pii.base_url="https://chatgpt.com/backend-api/codex"',
    ])
  })

  test('файл режима: direct — напрямую; нет файла или другое значение — через прокси', () => {
    const dir = mkdtempSync(join(tmpdir(), 'pii-mode-'))
    const file = join(dir, 'pii-mode')
    const read = piiModeReader(file)
    expect(read()).toBe('proxy')
    writeFileSync(file, 'direct\n')
    expect(read()).toBe('direct')
    writeFileSync(file, 'proxy\n')
    expect(read()).toBe('proxy')
    writeFileSync(file, 'garbage')
    expect(read()).toBe('proxy')
    expect(piiModeReader('')()).toBe('proxy')
  })

  test('режим codex включается только LABOPS_HARNESS=codex', () => {
    expect(codexHarnessEnabled({ LABOPS_HARNESS: 'codex' })).toBe(true)
    expect(codexHarnessEnabled({})).toBe(false)
    expect(codexHarnessEnabled({ LABOPS_HARNESS: 'claude' })).toBe(false)
  })
})

describe('хуки памяти', () => {
  test('скрипт получает JSON на stdin и AGENT_WORKSPACE, stdout возвращается', async () => {
    const ws = mkdtempSync(join(tmpdir(), 'codex-hooks-'))
    mkdirSync(join(ws, 'hooks'))
    const script = join(ws, 'hooks', 'session-start-hook.sh')
    writeFileSync(script, '#!/usr/bin/env bash\ncat > "$AGENT_WORKSPACE/stdin.json"\necho "контекст"\n')
    chmodSync(script, 0o755)
    const out = await runMemoryHook(ws, 'session-start', { hook_event_name: 'SessionStart' }, { PATH: process.env.PATH })
    expect(out.trim()).toBe('контекст')
    expect(JSON.parse(readFileSync(join(ws, 'stdin.json'), 'utf8'))).toEqual({ hook_event_name: 'SessionStart' })
  })

  test('нет скрипта — пустой результат, не ошибка', async () => {
    const ws = mkdtempSync(join(tmpdir(), 'codex-hooks-'))
    expect(await runMemoryHook(ws, 'stop', {}, {})).toBe('')
  })

  test('упавший скрипт — исключение', async () => {
    const ws = mkdtempSync(join(tmpdir(), 'codex-hooks-'))
    mkdirSync(join(ws, 'hooks'))
    writeFileSync(join(ws, 'hooks', 'stop-hook.sh'), 'exit 3\n')
    await expect(runMemoryHook(ws, 'stop', {}, { PATH: process.env.PATH })).rejects.toThrow('exit 3')
  })
})

describe('перевод событий', () => {
  test('элементы Codex → имена инструментов отрисовщика', () => {
    expect(mapItemToTool({ type: 'fileChange', id: '1', changes: [{ path: '/a/b.ts' }] })).toEqual({
      toolName: 'Edit',
      toolInput: { file_path: '/a/b.ts' },
    })
    expect(mapItemToTool({ type: 'mcpToolCall', id: '2', server: 's', tool: 't', arguments: { x: 1 } })!.toolName).toBe(
      'mcp__s__t',
    )
    expect(mapItemToTool({ type: 'agentMessage', id: '3', text: 'x' })).toBeUndefined()
  })

  test('reply канала распознаётся, чужие инструменты — нет', () => {
    const item = { type: 'mcpToolCall', id: '1', server: 'labops-channel', tool: 'reply', arguments: { chat_id: 5, text: 'Hi' } }
    expect(replyTextOf(item)).toEqual({ chatId: '5', text: 'Hi' })
    expect(replyTextOf({ ...item, tool: 'react' })).toBeUndefined()
  })
})

describe('отпечаток инструкций и предел молчания хода', () => {
  test('instructionsHash меняется от AGENTS.md рабочей папки и глобального в CODEX_HOME', () => {
    const ws = mkdtempSync(join(tmpdir(), 'codex-ws-'))
    const home = mkdtempSync(join(tmpdir(), 'codex-home-'))
    writeFileSync(join(ws, 'AGENTS.md'), 'v1')
    const a = instructionsHash(ws, home)
    expect(instructionsHash(ws, home)).toBe(a)
    writeFileSync(join(ws, 'AGENTS.md'), 'v2')
    const b = instructionsHash(ws, home)
    expect(b).not.toBe(a)
    writeFileSync(join(home, 'AGENTS.md'), 'global')
    expect(instructionsHash(ws, home)).not.toBe(b)
    expect(instructionsHash(ws, '')).toBe(b)
  })

  test('turnStallFromEnv: секунды → мс, мусор — умолчание', () => {
    expect(turnStallFromEnv({ LABOPS_CODEX_TURN_STALL_SEC: '240' })).toBe(240_000)
    expect(turnStallFromEnv({ LABOPS_CODEX_TURN_STALL_SEC: '0' })).toBeUndefined()
    expect(turnStallFromEnv({ LABOPS_CODEX_TURN_STALL_SEC: 'abc' })).toBeUndefined()
    expect(turnStallFromEnv({})).toBeUndefined()
    expect(itemStallFromEnv({ LABOPS_CODEX_ITEM_STALL_SEC: '3600' })).toBe(3_600_000)
    expect(itemStallFromEnv({})).toBeUndefined()
  })
})
