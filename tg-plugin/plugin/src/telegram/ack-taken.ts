// ack-taken.ts — короткое «принял в работу» на входящее сообщение.
//
// ЗАЧЕМ, если есть 👀 и «Печатает…»:
// реакция 👀 легко теряется в ленте, а индикатор статуса живёт в одном
// сообщении, которое переписывается по ходу дела, — по нему не видно момента
// «задача принята». Оператору нужен явный ответ: агент получил задачу и взялся
// за неё. Ответ по существу приходит ОТДЕЛЬНЫМ сообщением, когда будет готов
// (требование оператора 2026-08-09) — это подтверждение его не заменяет и
// никогда не притворяется результатом.
//
// Свойства:
//   * отправляется ТОЛЬКО после того, как сообщение реально ушло агенту, —
//     иначе подтверждали бы приём того, что потерялось;
//   * ответом на исходное сообщение, чтобы в потоке было видно, что принято;
//   * никогда не бросает и никогда не задерживает доставку;
//   * выключается через TELEGRAM_ACK_TAKEN=0.

import type { Logger } from '../log.js'
import type { TelegramApi } from '../channel/tools.js'

export const ACK_TAKEN_TEXT = '✅ Принял в работу.'

export interface AckTakenDeps {
  telegramApi: TelegramApi
  log: Logger
  chatId: string
  /** message_id исходного сообщения — ответом на него и подтверждаем. */
  replyToMessageId?: number
  /**
   * Занят ли агент. Когда занят, автоответ «<агент> занят» уже подтверждает
   * приём — подтверждать второй раз значит сказать одно и то же дважды.
   */
  busy?: boolean
  env?: NodeJS.ProcessEnv
}

/** Включено ли подтверждение приёма (по умолчанию да). */
export function ackTakenEnabled(env: NodeJS.ProcessEnv = process.env): boolean {
  return env.TELEGRAM_ACK_TAKEN !== '0'
}

// Подтвердить приём. Ошибки только логируются: не доставить подтверждение —
// досадно, но уронить из-за него обработку входящего нельзя.
export async function ackTaken(deps: AckTakenDeps): Promise<boolean> {
  const env = deps.env ?? process.env
  if (!ackTakenEnabled(env)) return false
  if (deps.busy === true) return false
  try {
    await deps.telegramApi.sendMessage(deps.chatId, ACK_TAKEN_TEXT, {
      ...(deps.replyToMessageId !== undefined
        ? { reply_to_message_id: deps.replyToMessageId }
        : {}),
    })
    return true
  } catch (err) {
    deps.log.debug('ack «принял в работу» не отправлен (игнорируем)', {
      chat_id: deps.chatId,
      error: err instanceof Error ? err.message : String(err),
    })
    return false
  }
}
