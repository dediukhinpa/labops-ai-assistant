// Разбор входящего апдейта общего бота: чей он и куда его отдать.
//
// Изоляция пользователей держится ровно на одной строчке — агент ищется
// по `from.id`, а не по чату. В личке это одно и то же, но если бота
// когда-нибудь добавят в группу, привязка по чату отдала бы одному
// человеку агента другого.

import type { Message, Update } from 'grammy/types'

import type { AgentEndpoint } from './endpoints.js'
import type { DeliveryPayload, DeliveryResult } from './deliver.js'

/** Что сказать человеку, которого ещё не подключили к приложению. */
const NO_ROUTE_TEXT =
  'Этот аккаунт пока не подключён к LabOps App. Попросите оператора добавить вас.'

/** MVP принимает только текст: вложения требуют скачивания общим токеном. */
const UNSUPPORTED_TEXT = 'Пока принимаю только текстовые сообщения.'

/** Агент не ответил — честно говорим, а не молчим. */
const FAILED_TEXT = 'Не смогла передать сообщение ассистенту. Попробуйте ещё раз через минуту.'

export interface DispatchLogger {
  info: (msg: string, fields?: Record<string, unknown>) => void
  warn: (msg: string, fields?: Record<string, unknown>) => void
  error: (msg: string, fields?: Record<string, unknown>) => void
}

export interface DispatchDeps {
  /** Поиск агента по telegram id отправителя. */
  lookupAgent: (telegramId: number) => string | undefined
  /** Адрес приёмника агента и его bearer. */
  resolveEndpoint: (agentId: string) => AgentEndpoint
  /** Доставка в приёмник агента. */
  deliver: (target: AgentEndpoint, payload: DeliveryPayload) => Promise<DeliveryResult>
  /** Ответ человеку от имени общего бота. */
  replyToUser: (chatId: number, text: string) => Promise<void>
  log: DispatchLogger
}

export type DispatchOutcome = 'delivered' | 'no_route' | 'unsupported' | 'failed' | 'ignored'

export interface DispatchResult {
  outcome: DispatchOutcome
  agentId?: string
}

/**
 * Обработать один апдейт общего бота.
 *
 * @param update - Апдейт из getUpdates.
 * @param deps - Поиск маршрута, доставка и ответ пользователю.
 * @returns Что произошло с апдейтом (для логов и метрик).
 */
export async function dispatchUpdate(
  update: Update,
  deps: DispatchDeps,
): Promise<DispatchResult> {
  const message = update.message ?? update.edited_message
  if (message === undefined) return { outcome: 'ignored' }

  const from = message.from
  if (from === undefined || from.is_bot) return { outcome: 'ignored' }

  const chatId = message.chat.id
  const agentId = deps.lookupAgent(from.id)
  if (agentId === undefined) {
    // Не логируем текст: сообщение постороннего человека нам не принадлежит.
    deps.log.warn('нет маршрута для отправителя', { from_id: from.id })
    await safeReply(deps, chatId, NO_ROUTE_TEXT)
    return { outcome: 'no_route' }
  }

  const text = extractText(message)
  if (text === undefined) {
    await safeReply(deps, chatId, UNSUPPORTED_TEXT)
    return { outcome: 'unsupported', agentId }
  }

  let target: AgentEndpoint
  try {
    target = deps.resolveEndpoint(agentId)
  } catch (err) {
    deps.log.error('не удалось найти приёмник агента', {
      agent: agentId,
      error: err instanceof Error ? err.message : String(err),
    })
    await safeReply(deps, chatId, FAILED_TEXT)
    return { outcome: 'failed', agentId }
  }

  const result = await deps.deliver(target, { message: text, chatId })
  if (!result.ok) {
    deps.log.error('агент не принял сообщение', {
      agent: agentId,
      status: result.status ?? null,
      reason: result.reason,
    })
    await safeReply(deps, chatId, FAILED_TEXT)
    return { outcome: 'failed', agentId }
  }

  deps.log.info('сообщение доставлено агенту', { agent: agentId, from_id: from.id })
  return { outcome: 'delivered', agentId }
}

/** Текст сообщения или подпись к медиа; undefined — принимать нечего. */
function extractText(message: Message): string | undefined {
  const text = message.text ?? message.caption
  return text !== undefined && text.length > 0 ? text : undefined
}

/**
 * Ответить человеку, не роняя обработку апдейта.
 *
 * Сбой sendMessage (человек заблокировал бота, сеть моргнула) не должен
 * приводить к повтору апдейта: курсор поллера сдвинется в любом случае.
 */
async function safeReply(deps: DispatchDeps, chatId: number, text: string): Promise<void> {
  try {
    await deps.replyToUser(chatId, text)
  } catch (err) {
    deps.log.warn('не удалось ответить пользователю', {
      chat_id: chatId,
      error: err instanceof Error ? err.message : String(err),
    })
  }
}
