// Релей сообщений посторонних клиентов в личке бота на HTTP-эндпоинт продукта.
//
// Зачем: этот же бот читает группу техподдержки, а клиенты приходят к нему по
// ссылке t.me/<бот>?start=t_<shortId>. Пока личка открыта только владельцу
// (gate.ts), любое сообщение клиента молча дропается. Эта ветка перехватывает
// приватные сообщения ПОСТОРОННИХ user_id ДО агентской логики: никакой
// Claude-сессии, инструментов и памяти на этом пути нет, есть только один
// POST на эндпоинт продукта и один sendMessage клиенту с тем, что он вернул.
//
// Ветка включается парой SUPPORT_FOLLOWUP_URL + SUPPORT_FOLLOWUP_TOKEN. Если
// любая не задана или URL некорректен -- ветка выключена, поведение прежнее.
//
// Ни токен, ни текст сообщений, ни ответ эндпоинта в журнал не попадают:
// пишутся только вид, длина и исход.
import type { TelegramApi } from '../channel/tools.js'
import type { Logger } from '../log.js'

/** Предел длины сообщения клиента; длиннее -- не форвардим, просим сократить. */
export const CLIENT_RELAY_MAX_TEXT_CHARS = 4000
/** Предел Bot API на длину исходящего сообщения. */
export const CLIENT_RELAY_MAX_REPLY_CHARS = 4096
/** Таймаут вызова эндпоинта продукта. */
export const CLIENT_RELAY_TIMEOUT_MS = 10_000

export const CLIENT_START_HINT_TEXT =
  'Чтобы продолжить обращение в поддержку, откройте этот чат по ссылке из ответа поддержки.'
export const CLIENT_TOO_LONG_TEXT =
  'Сообщение слишком длинное. Сократите его и отправьте ещё раз.'
export const CLIENT_UNAVAILABLE_TEXT =
  'Сейчас не получается принять сообщение. Попробуйте, пожалуйста, чуть позже.'

const START_PAYLOAD_RE = /^\/start(?:@\w+)?\s+t_([0-9a-f]{8})\s*$/i
const START_ANY_RE = /^\/start(?:@\w+)?(?:\s|$)/i

export type RelayRequest =
  | { kind: 'start'; telegramUserId: number; chatId: number; shortId: string }
  | { kind: 'message'; telegramUserId: number; chatId: number; text: string }

export interface ClientRelayInput {
  telegramUserId: number
  chatId: number
  text: string
}

export interface ClientRelay {
  /** Обработать сообщение клиента: форвард и ответ клиенту. Никогда не бросает. */
  handle(input: ClientRelayInput): Promise<void>
}

export type FetchLike = (input: string, init?: RequestInit) => Promise<Response>

export interface ClientRelayOptions {
  url: string
  token: string
  telegramApi: Pick<TelegramApi, 'sendMessage'>
  log: Logger
  fetchImpl?: FetchLike
  timeoutMs?: number
}

/** Разобрать текст клиента: `/start t_<8hex>` -> start, `/start` без валидного payload -> null. */
export function classifyClientText(
  input: ClientRelayInput,
): { relay: RelayRequest } | { fixedReply: string } {
  const text = input.text.trim()
  const start = START_PAYLOAD_RE.exec(text)
  if (start !== null && start[1] !== undefined) {
    return {
      relay: {
        kind: 'start',
        telegramUserId: input.telegramUserId,
        chatId: input.chatId,
        shortId: start[1].toLowerCase(),
      },
    }
  }
  if (START_ANY_RE.test(text)) return { fixedReply: CLIENT_START_HINT_TEXT }
  if (Array.from(text).length > CLIENT_RELAY_MAX_TEXT_CHARS) {
    return { fixedReply: CLIENT_TOO_LONG_TEXT }
  }
  if (text.length === 0) return { fixedReply: CLIENT_START_HINT_TEXT }
  return {
    relay: {
      kind: 'message',
      telegramUserId: input.telegramUserId,
      chatId: input.chatId,
      text,
    },
  }
}

/** Ветка включена только при заданных и корректных URL и токене. */
export function createClientRelayFromEnv(
  env: NodeJS.ProcessEnv,
  deps: { telegramApi: Pick<TelegramApi, 'sendMessage'>; log: Logger; fetchImpl?: FetchLike },
): ClientRelay | undefined {
  const url = env.SUPPORT_FOLLOWUP_URL?.trim() ?? ''
  const token = env.SUPPORT_FOLLOWUP_TOKEN?.trim() ?? ''
  if (url === '' || token === '') return undefined
  try {
    const parsed = new URL(url)
    if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') throw new Error('protocol')
  } catch {
    deps.log.warn('client relay disabled: SUPPORT_FOLLOWUP_URL is not a valid http(s) url')
    return undefined
  }
  return createClientRelay({
    url,
    token,
    telegramApi: deps.telegramApi,
    log: deps.log,
    ...(deps.fetchImpl !== undefined ? { fetchImpl: deps.fetchImpl } : {}),
  })
}

export function createClientRelay(options: ClientRelayOptions): ClientRelay {
  const fetchImpl: FetchLike = options.fetchImpl ?? ((input, init) => fetch(input, init))
  const timeoutMs = options.timeoutMs ?? CLIENT_RELAY_TIMEOUT_MS

  async function send(chatId: number, text: string, kind: string): Promise<void> {
    try {
      await options.telegramApi.sendMessage(String(chatId), text.slice(0, CLIENT_RELAY_MAX_REPLY_CHARS), {})
    } catch (err) {
      options.log.warn('client relay: reply not sent', {
        kind,
        error: err instanceof Error ? err.name : 'unknown',
      })
    }
  }

  async function forward(request: RelayRequest): Promise<string | null> {
    try {
      const response = await fetchImpl(options.url, {
        method: 'POST',
        headers: {
          authorization: `Bearer ${options.token}`,
          'content-type': 'application/json',
        },
        body: JSON.stringify(request),
        signal: AbortSignal.timeout(timeoutMs),
      })
      if (!response.ok) {
        options.log.warn('client relay: endpoint error', { kind: request.kind, status: response.status })
        return null
      }
      const body: unknown = await response.json()
      if (typeof body !== 'object' || body === null) return null
      const record = body as Record<string, unknown>
      if (record['ok'] !== true) {
        options.log.warn('client relay: endpoint refused', { kind: request.kind })
        return null
      }
      const reply = record['reply']
      return typeof reply === 'string' ? reply : ''
    } catch (err) {
      options.log.warn('client relay: call failed', {
        kind: request.kind,
        error: err instanceof Error ? err.name : 'unknown',
      })
      return null
    }
  }

  return {
    async handle(input: ClientRelayInput): Promise<void> {
      const decision = classifyClientText(input)
      if ('fixedReply' in decision) {
        await send(input.chatId, decision.fixedReply, 'fixed')
        return
      }
      const reply = await forward(decision.relay)
      if (reply === null) {
        await send(input.chatId, CLIENT_UNAVAILABLE_TEXT, decision.relay.kind)
        return
      }
      options.log.info('client relay: forwarded', {
        kind: decision.relay.kind,
        reply_chars: reply.length,
      })
      if (reply.trim() !== '') await send(input.chatId, reply, decision.relay.kind)
    },
  }
}
