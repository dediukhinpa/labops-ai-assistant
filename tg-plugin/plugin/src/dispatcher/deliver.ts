// Доставка входящего в приёмник агента.
//
// Транспорт не новый: `POST /hooks/agent` с bearer агента — тот же путь,
// которым в сессию пишет веб-приложение. Диспетчер только выбирает адресата.

import { redactSecrets } from '../safety/redact.js'

/** Сколько ждём агента, прежде чем признать доставку неудачной. */
const DEFAULT_TIMEOUT_MS = 10_000

export interface DeliveryTarget {
  url: string
  token: string
}

export interface DeliveryPayload {
  /** Текст пользователя — приходит в сессию как входящее сообщение. */
  message: string
  /** Реальный chat_id: по нему агент отвечает в тот же чат. */
  chatId: number | string
}

/**
 * Минимальная форма fetch, которой пользуется доставка. Берём не
 * `typeof fetch`: у рантайма на нём висят дополнительные поля
 * (например preconnect), и тест не смог бы подставить простую заглушку.
 */
export type FetchLike = (
  url: string,
  init: RequestInit,
) => Promise<Response>

export interface DeliveryOptions {
  timeoutMs?: number
  fetchImpl?: FetchLike
}

export type DeliveryResult =
  | { ok: true }
  | { ok: false; status?: number; reason: string }

/**
 * Отправить сообщение в приёмник агента.
 *
 * @param target - URL приёмника и bearer агента.
 * @param payload - Текст и chat_id отправителя.
 * @param options - Таймаут и подменяемый fetch (для тестов).
 * @returns Результат доставки; исключения наружу не выпускаются.
 */
export async function deliverToAgent(
  target: DeliveryTarget,
  payload: DeliveryPayload,
  options: DeliveryOptions = {},
): Promise<DeliveryResult> {
  const timeoutMs = options.timeoutMs ?? DEFAULT_TIMEOUT_MS
  const doFetch = options.fetchImpl ?? fetch
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), timeoutMs)

  try {
    const res = await doFetch(target.url, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        authorization: `Bearer ${target.token}`,
      },
      body: JSON.stringify({ message: payload.message, chatId: payload.chatId }),
      signal: controller.signal,
    })
    if (!res.ok) {
      return { ok: false, status: res.status, reason: `agent returned ${res.status}` }
    }
    return { ok: true }
  } catch (err) {
    // Сообщение об ошибке уходит в лог, а сетевые библиотеки любят
    // вставлять в него исходный запрос — чистим bearer на всякий случай.
    const raw = err instanceof Error ? err.message : String(err)
    return { ok: false, reason: redactSecrets(raw, [target.token]) }
  } finally {
    clearTimeout(timer)
  }
}
