import { describe, expect, test } from 'bun:test'

import { ACK_TAKEN_TEXT, ackTaken, ackTakenEnabled } from '../../src/telegram/ack-taken.js'
import type { Logger } from '../../src/log.js'
import type { TelegramApi } from '../../src/channel/tools.js'

function silentLog(): Logger {
  return { debug: () => {}, info: () => {}, warn: () => {}, error: () => {} }
}

interface Sent {
  chatId: string
  text: string
  opts: Record<string, unknown>
}

function api(sent: Sent[], fail = false): TelegramApi {
  const boom = (name: string) => (): never => {
    throw new Error(`unexpected TelegramApi call: ${name}`)
  }
  return {
    sendMessage: (async (chatId: string, text: string, opts: Record<string, unknown>) => {
      if (fail) throw new Error('telegram down')
      sent.push({ chatId, text, opts })
      return { message_id: 1 }
    }) as TelegramApi['sendMessage'],
    editMessageText: boom('editMessageText') as TelegramApi['editMessageText'],
    setMessageReaction: boom('setMessageReaction') as TelegramApi['setMessageReaction'],
    sendChatAction: boom('sendChatAction') as TelegramApi['sendChatAction'],
    sendDocument: boom('sendDocument') as TelegramApi['sendDocument'],
    sendPhoto: boom('sendPhoto') as TelegramApi['sendPhoto'],
    downloadFile: boom('downloadFile') as TelegramApi['downloadFile'],
    deleteMessage: boom('deleteMessage') as TelegramApi['deleteMessage'],
  }
}

describe('подтверждение приёма', () => {
  test('отправляется ответом на исходное сообщение', async () => {
    const sent: Sent[] = []
    const ok = await ackTaken({
      telegramApi: api(sent),
      log: silentLog(),
      chatId: '42',
      replyToMessageId: 7,
      env: {} as NodeJS.ProcessEnv,
    })
    expect(ok).toBe(true)
    expect(sent).toHaveLength(1)
    expect(sent[0]!.text).toBe(ACK_TAKEN_TEXT)
    expect(sent[0]!.chatId).toBe('42')
    expect(sent[0]!.opts.reply_to_message_id).toBe(7)
  })

  test('молчит, когда агент занят — приём уже подтверждён автоответом «занят»', async () => {
    const sent: Sent[] = []
    const ok = await ackTaken({
      telegramApi: api(sent),
      log: silentLog(),
      chatId: '42',
      busy: true,
      env: {} as NodeJS.ProcessEnv,
    })
    expect(ok).toBe(false)
    expect(sent).toHaveLength(0)
  })

  test('выключается через TELEGRAM_ACK_TAKEN=0', async () => {
    const sent: Sent[] = []
    const ok = await ackTaken({
      telegramApi: api(sent),
      log: silentLog(),
      chatId: '42',
      env: { TELEGRAM_ACK_TAKEN: '0' } as NodeJS.ProcessEnv,
    })
    expect(ok).toBe(false)
    expect(sent).toHaveLength(0)
    expect(ackTakenEnabled({ TELEGRAM_ACK_TAKEN: '0' } as NodeJS.ProcessEnv)).toBe(false)
    expect(ackTakenEnabled({} as NodeJS.ProcessEnv)).toBe(true)
  })

  test('недоступный Telegram не роняет обработку входящего', async () => {
    const sent: Sent[] = []
    const ok = await ackTaken({
      telegramApi: api(sent, true),
      log: silentLog(),
      chatId: '42',
      env: {} as NodeJS.ProcessEnv,
    })
    expect(ok).toBe(false)
  })

  test('подтверждение не притворяется ответом по существу', () => {
    // Ответ приходит ОТДЕЛЬНЫМ сообщением; это — только расписка о приёме.
    expect(ACK_TAKEN_TEXT.length).toBeLessThan(40)
    expect(ACK_TAKEN_TEXT).toContain('Принял в работу')
  })
})
