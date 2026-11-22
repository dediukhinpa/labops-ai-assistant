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
  askViaRelay,
  codexChildEnv,
  codexHarnessEnabled,
} from '../../src/harness/codex/bootstrap.js'
import { runMemoryHook } from '../../src/harness/codex/memory-hooks.js'
import { mapItemToTool, replyTextOf } from '../../src/harness/codex/events.js'
import type { AskUserQuestionRelay, AskUserQuestionResult } from '../../src/channel/ask-user-question.js'
import type { AskUserQuestionUi } from '../../src/telegram/ask-user-question.js'

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

describe('вопросы кнопками', () => {
  test('ответы релея (ключ — текст вопроса) превращаются в ответы Codex (ключ — id)', async () => {
    let submitted: unknown
    const relay = {
      submit: (input: unknown) => {
        submitted = input
        const result: AskUserQuestionResult = {
          status: 'answered',
          updatedInput: { questions: [], answers: { 'Удалить?': 'Да', 'Что ещё?': ['A', 'B'] } },
        }
        return { requestId: 'req-1', result: Promise.resolve(result) }
      },
    } as unknown as AskUserQuestionRelay
    let started = ''
    const ui = { startQuestion: async (id: string) => void (started = id) } as unknown as AskUserQuestionUi
    const out = await askViaRelay(
      relay,
      ui,
      '42',
      [
        { id: 'q1', header: 'H', question: 'Удалить?', isOther: false, isSecret: false, options: [{ label: 'Да', description: '' }] },
        { id: 'q2', header: 'H', question: 'Что ещё?', isOther: true, isSecret: false, options: null },
      ],
      'item-1',
      'thr',
    )
    expect(started).toBe('req-1')
    expect(submitted).toMatchObject({ chatId: '42', toolUseId: 'item-1', sessionId: 'thr' })
    expect(out).toEqual({ answers: { q1: { answers: ['Да'] }, q2: { answers: ['A', 'B'] } } })
  })

  test('таймаут — null', async () => {
    const relay = {
      submit: () => ({ requestId: undefined, result: Promise.resolve({ status: 'timeout' }) }),
    } as unknown as AskUserQuestionRelay
    const ui = { startQuestion: async () => undefined } as unknown as AskUserQuestionUi
    expect(await askViaRelay(relay, ui, '42', [], 'i', 't')).toBeNull()
  })
})
