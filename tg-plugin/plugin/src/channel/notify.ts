// MCP `notifications/claude/channel` event helpers.
//
// Claude Code drops meta keys with hyphens silently (per RESEARCH.md). We
// enforce identifier-style snake_case keys and stringify all values so the
// receiver never has to guess how to render a number/boolean.
//
// Multichat contract: callers MUST populate `meta.chat_id` with the
// originating Telegram chat id (already done in handlers.ts:buildMeta).
// The master Claude session inspects `meta.chat_id` to know which chat
// the inbound message came from — there is NO implicit fallback to the
// operator's DM. This module never injects a default chat_id; an event
// arriving without one is a wiring bug at the caller, not something we
// paper over here.

import type { Server } from '@modelcontextprotocol/sdk/server/index.js'
import type { Logger } from '../log.js'
import {
  createTmuxRunner,
  resolveAgentSession,
  type TmuxRunner,
} from './ensure-submit.js'

export type ChannelEvent = {
  content: string
  // Caller-supplied metadata. In multichat mode this MUST include
  // `chat_id` so the master session can route the event; in the legacy
  // DM-only mode `chat_id` is still set (handlers.ts always populates it).
  meta: Record<string, string>
}

const IDENT_RE = /^[A-Za-z_][A-Za-z0-9_]*$/

export function normalizeMeta(raw: Record<string, unknown>): Record<string, string> {
  const out: Record<string, string> = {}
  for (const [key, value] of Object.entries(raw)) {
    if (value === null || value === undefined) continue
    if (key.includes('-')) continue
    if (!IDENT_RE.test(key)) continue
    if (typeof value === 'string') {
      out[key] = value
    } else if (typeof value === 'number' && Number.isFinite(value)) {
      out[key] = String(value)
    } else if (typeof value === 'boolean') {
      out[key] = value ? 'true' : 'false'
    } else if (typeof value === 'bigint') {
      out[key] = value.toString()
    } else {
      // Object/array/symbol/function — drop with a serialized fallback only if JSON works.
      try {
        out[key] = JSON.stringify(value)
      } catch {
        // skip
      }
    }
  }
  return out
}

// Режим доставки «в окно tmux». Нужен там, где Claude Code не включает каналы
// (`Channels are not currently available`): например, агент работает через шлюз
// LiteLLM без входа в аккаунт Claude. Тогда notifications/claude/channel уходит в
// пустоту, а сообщение оператора надо напечатать в сессию так, как это сделал бы
// человек. Ответы агент по-прежнему шлёт инструментами этого же MCP-сервера.
export const INBOUND_VIA_TMUX_ENV = 'LABOPS_INBOUND_VIA_TMUX'

// Управляющие символы (включая ESC) из текста вырезаем: иначе сообщение из Telegram
// могло бы закрыть bracketed paste раньше времени и подсунуть терминалу свои клавиши.
// Перевод строки и табуляция остаются.
// eslint-disable-next-line no-control-regex
const CONTROL_CHARS_RE = /[\u0000-\u0008\u000b-\u001f\u007f]/g

export function inboundViaTmuxEnabled(env: NodeJS.ProcessEnv = process.env): boolean {
  return env[INBOUND_VIA_TMUX_ENV] === '1'
}

/**
 * Текст, который агент увидит в поле ввода: тот же вид, что Claude Code рисует для
 * канала, чтобы инструкции агента («отвечай в chat_id из тега channel») работали.
 */
export function formatInboundForTmux(event: ChannelEvent): string {
  const attrs = Object.entries(event.meta)
    .map(([key, value]) => `${key}="${value.replace(CONTROL_CHARS_RE, ' ').replace(/"/g, "'")}"`)
    .join(' ')
  const body = event.content.replace(CONTROL_CHARS_RE, '')
  return `<channel source="labops-channel" ${attrs}>\n${body}\n</channel>`
}

export interface TmuxDeliveryOptions {
  /** Для тестов: подмена tmux. */
  runner?: TmuxRunner
  env?: NodeJS.ProcessEnv
}

// Сообщения печатаются строго по одному: два параллельных send-keys перемешали бы текст.
let tmuxQueue: Promise<unknown> = Promise.resolve()

async function deliverViaTmux(
  event: ChannelEvent,
  log: Logger,
  opts: TmuxDeliveryOptions,
): Promise<boolean> {
  const session = resolveAgentSession(opts.env ?? process.env)
  if (session.length === 0) {
    log.error('tmux inbound: no AGENT_ID, cannot pick the session')
    return false
  }
  const runner = opts.runner ?? createTmuxRunner()
  const text = formatInboundForTmux(event)
  const job = tmuxQueue.then(async () => {
    await runner.submitText(session, text)
    return true
  })
  tmuxQueue = job.catch(() => undefined)
  try {
    return await job
  } catch (err) {
    log.error('tmux inbound delivery failed', {
      session,
      error: err instanceof Error ? err.message : String(err),
    })
    return false
  }
}

// Харнес Codex: входящие уходят не уведомлением MCP (у Codex нет каналов Claude), а в
// драйвер app-server. Пока приёмник установлен, sendChannelNotification отдаёт события ему.
export type InboundSink = (event: ChannelEvent) => Promise<boolean>
let inboundSink: InboundSink | undefined

/** Установить (или снять — undefined) приёмник входящих вместо канала Claude. */
export function setInboundSink(sink: InboundSink | undefined): void {
  inboundSink = sink
}

/** Входящие идут в драйвер Codex, а не в сессию Claude Code. */
export function inboundSinkActive(): boolean {
  return inboundSink !== undefined
}

// Returns true when server.notification accepted the write; false when the
// transport threw (error already logged). Callers MUST honour false: poller
// dead-letters the update, webhook returns 503.
export async function sendChannelNotification(
  server: Server,
  event: ChannelEvent,
  log: Logger,
  opts: TmuxDeliveryOptions = {},
): Promise<boolean> {
  if (inboundSink !== undefined) {
    try {
      return await inboundSink(event)
    } catch (err) {
      log.error('inbound sink failed', { error: err instanceof Error ? err.message : String(err) })
      return false
    }
  }
  if (inboundViaTmuxEnabled(opts.env)) return deliverViaTmux(event, log, opts)
  try {
    await server.notification({
      method: 'notifications/claude/channel',
      params: {
        content: event.content,
        meta: event.meta,
      },
    })
    return true
  } catch (err) {
    log.error('channel notification failed', {
      error: err instanceof Error ? err.message : String(err),
    })
    return false
  }
}
