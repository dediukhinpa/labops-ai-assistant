// Инструменты канала Telegram (reply, react, edit_message, ...) для Codex по MCP over HTTP.
//
// У Claude Code плагин — stdio MCP-сервер, который запускает сам claude. У Codex процесс
// плагина — главный (его запускает watchdog), а codex app-server — его ребёнок; поэтому те
// же инструменты отдаются по HTTP на внутреннем порту плагина (маршрут /mcp webhook-сервера).
// Адрес и переменную с токеном драйвер передаёт codex флагами -c при запуске app-server.
//
// Режим без сессий (stateless): на каждый запрос — свой транспорт и свой экземпляр Server,
// как рекомендует SDK; состояние инструментов живёт в ToolDeps, а не в сессии MCP.
// Доступ: только loopback и Bearer-токен, который драйвер генерирует при старте.

import { randomBytes, timingSafeEqual } from 'crypto'
import type { IncomingMessage, ServerResponse } from 'http'

import { Server } from '@modelcontextprotocol/sdk/server/index.js'
import { StreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/streamableHttp.js'
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
  type CallToolResult,
  type ServerResult,
} from '@modelcontextprotocol/sdk/types.js'

/** Маршрут MCP на webhook-сервере плагина. */
export const MCP_HTTP_PATH = '/mcp'
/** Переменная окружения codex, из которой он берёт Bearer для MCP канала. */
export const CHANNEL_TOKEN_ENV = 'LABOPS_CHANNEL_MCP_TOKEN'
/** Длина токена в байтах. */
const TOKEN_BYTES = 32

/** Обработчики инструментов канала (те же, что у stdio-сервера). */
export interface ChannelToolHandlers {
  listTools: () => unknown[]
  callTool: (req: { params: { name: string; arguments?: Record<string, unknown> } }) => Promise<unknown>
}

export interface McpHttpOptions {
  name: string
  version: string
  /** Инструкции сервера (Codex показывает их модели). */
  instructions: string
  handlers: ChannelToolHandlers
  token: string
}

/** Случайный токен MCP канала на время жизни драйвера. */
export function newChannelToken(): string {
  return randomBytes(TOKEN_BYTES).toString('hex')
}

function isLoopback(addr: string | undefined): boolean {
  if (addr === undefined) return false
  return addr === '::1' || addr === '::ffff:127.0.0.1' || addr.startsWith('127.')
}

function bearerOk(header: string | undefined, token: string): boolean {
  const expected = Buffer.from(`Bearer ${token}`)
  const received = Buffer.from(header ?? '')
  return received.length === expected.length && timingSafeEqual(received, expected)
}

function deny(res: ServerResponse, status: number, message: string): void {
  res.writeHead(status, { 'content-type': 'application/json' })
  res.end(JSON.stringify({ jsonrpc: '2.0', error: { code: -32000, message }, id: null }))
}

function buildServer(opts: McpHttpOptions): Server {
  const server = new Server(
    { name: opts.name, version: opts.version },
    { capabilities: { tools: {} }, instructions: opts.instructions },
  )
  server.setRequestHandler(ListToolsRequestSchema, async () => ({
    tools: opts.handlers.listTools() as never,
  }))
  server.setRequestHandler(CallToolRequestSchema, async (req): Promise<ServerResult> => {
    const result = await opts.handlers.callTool({
      params: {
        name: req.params.name,
        ...(req.params.arguments !== undefined ? { arguments: req.params.arguments } : {}),
      },
    })
    return result as CallToolResult
  })
  return server
}

/**
 * Обработчик маршрута /mcp для webhook-сервера плагина.
 *
 * @param opts Описание сервера, инструменты и токен.
 * @returns (req, res) => Promise<void>.
 */
export function createMcpHttpHandler(
  opts: McpHttpOptions,
): (req: IncomingMessage, res: ServerResponse) => Promise<void> {
  return async (req, res) => {
    if (!isLoopback(req.socket.remoteAddress)) {
      deny(res, 403, 'loopback only')
      return
    }
    if (!bearerOk(req.headers.authorization, opts.token)) {
      deny(res, 401, 'unauthorized')
      return
    }
    // Без сессий GET (поток уведомлений) и DELETE (закрытие сессии) не нужны.
    if (req.method !== 'POST') {
      deny(res, 405, 'method not allowed')
      return
    }
    const server = buildServer(opts)
    const transport = new StreamableHTTPServerTransport({}) // без sessionIdGenerator — режим без сессий
    res.on('close', () => {
      void transport.close()
      void server.close()
    })
    await server.connect(transport)
    await transport.handleRequest(req, res)
  }
}
