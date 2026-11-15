// Обёртка над TelegramApi для ФОНОВЫХ поверхностей: статус-пузырь, зеркало
// прогресса, зеркало задач, "агент занят", индикатор typing.
//
// Эти вызовы декоративны: потеря одной правки статуса ничего не ломает, а
// шторм правок (по хуку на каждый tool_use) приводит к flood-бану, который
// затем блокирует и настоящие ответы агента. Поэтому здесь:
//   * правки одного сообщения схлопываются: не чаще раза в minEditIntervalMs,
//     побеждает последний текст (trailing-flush по таймеру);
//   * правки в одном чате идут не чаще раза в chatEditGapMs (суммарно по всем
//     поверхностям), чтобы уложиться в лимиты Telegram на чат/группу;
//   * sendChatAction (typing) не чаще раза в typingMinIntervalMs на чат;
//   * при активном flood-бане фоновые вызовы сразу падают с TelegramFloodError
//     (совместима с 429), отложенные правки отбрасываются, сеть не трогается.
//
// Ответы агента (reply / edit_message / файлы) эту обёртку НЕ используют.

import type { Logger } from '../log.js'
import type {
  ChatAction,
  DownloadResult,
  EditOpts,
  SendDocumentOpts,
  SendMessageOpts,
  TelegramApi,
} from '../channel/tools.js'
import type { FloodGate } from './flood-gate.js'

// Правки одного сообщения: не чаще раза в 5 с (как ACTIVITY_EDIT_THROTTLE_MS).
const DEFAULT_MIN_EDIT_INTERVAL_MS = 5_000
// Между любыми фоновыми правками в одном чате: 3 с = не более 20 правок/мин.
const DEFAULT_CHAT_EDIT_GAP_MS = 3_000
// Typing живёт 5 с у Telegram; повторять чаще 4 с бессмысленно.
const DEFAULT_TYPING_MIN_INTERVAL_MS = 4_000
// Запись о сообщении без активности дольше этого забываем (память).
const STALE_ENTRY_MS = 60 * 60 * 1000

type TimerHandle = ReturnType<typeof setTimeout>

export interface BackgroundApiOptions {
  minEditIntervalMs?: number
  chatEditGapMs?: number
  typingMinIntervalMs?: number
  /** Шов для тестов. */
  now?: () => number
  setTimer?: (cb: () => void, ms: number) => TimerHandle
  clearTimer?: (h: TimerHandle) => void
}

interface PendingEdit {
  text: string
  opts: EditOpts
  timer: TimerHandle
}

interface MessageState {
  chatId: string
  messageId: number
  lastSentAt: number
  pending: PendingEdit | null
}

export function createBackgroundTelegramApi(
  base: TelegramApi,
  gate: FloodGate,
  log: Logger,
  opts: BackgroundApiOptions = {},
): TelegramApi {
  const minEditIntervalMs = opts.minEditIntervalMs ?? DEFAULT_MIN_EDIT_INTERVAL_MS
  const chatEditGapMs = opts.chatEditGapMs ?? DEFAULT_CHAT_EDIT_GAP_MS
  const typingMinIntervalMs = opts.typingMinIntervalMs ?? DEFAULT_TYPING_MIN_INTERVAL_MS
  const now = opts.now ?? ((): number => Date.now())
  const setTimer =
    opts.setTimer ??
    ((cb: () => void, ms: number): TimerHandle => {
      const h = setTimeout(cb, ms)
      // Отложенная правка не должна удерживать процесс при выходе.
      ;(h as { unref?: () => void }).unref?.()
      return h
    })
  const clearTimer = opts.clearTimer ?? ((h: TimerHandle): void => clearTimeout(h))

  const messages = new Map<string, MessageState>()
  // Когда в чате можно делать следующую фоновую правку.
  const chatNextEditAt = new Map<string, number>()
  const lastTypingAt = new Map<string, number>()

  const keyOf = (chatId: string, messageId: number): string => `${chatId}:${messageId}`

  function failIfBanned(): void {
    if (gate.isBanned('message')) throw gate.errorFor('message')
  }

  function prune(t: number): void {
    for (const [k, st] of messages) {
      if (st.pending === null && t - st.lastSentAt > STALE_ENTRY_MS) messages.delete(k)
    }
  }

  // Резервирует слот правки в чате и возвращает момент, когда можно слать.
  function reserveSlot(chatId: string, notBefore: number): number {
    const at = Math.max(notBefore, chatNextEditAt.get(chatId) ?? 0)
    chatNextEditAt.set(chatId, at + chatEditGapMs)
    return at
  }

  async function sendEdit(st: MessageState, text: string, editOpts: EditOpts): Promise<void> {
    st.lastSentAt = now()
    await base.editMessageText(st.chatId, st.messageId, text, editOpts)
  }

  function flushPending(key: string): void {
    const st = messages.get(key)
    if (st === undefined || st.pending === null) return
    const { text, opts: editOpts } = st.pending
    st.pending = null
    // Бан наступил, пока правка ждала: отбрасываем, сеть не трогаем.
    if (gate.isBanned('message')) {
      log.debug('background edit dropped: flood ban active', {
        chat_id: st.chatId,
        message_id: st.messageId,
      })
      return
    }
    sendEdit(st, text, editOpts).catch((err: unknown) => {
      // Вызывающий код уже получил "успех"; ошибка отложенной правки
      // не критична, следующая правка (если нужна) пойдёт обычным путём.
      log.warn('deferred background edit failed (ignored)', {
        chat_id: st.chatId,
        message_id: st.messageId,
        error: err instanceof Error ? err.message : String(err),
      })
    })
  }

  return {
    sendMessage(chatId: string, text: string, sendOpts: SendMessageOpts) {
      return base.sendMessage(chatId, text, sendOpts)
    },

    async editMessageText(
      chatId: string,
      messageId: number,
      text: string,
      editOpts: EditOpts,
    ): Promise<void> {
      failIfBanned()
      const t = now()
      prune(t)
      const key = keyOf(chatId, messageId)
      let st = messages.get(key)
      if (st === undefined) {
        st = { chatId, messageId, lastSentAt: Number.NEGATIVE_INFINITY, pending: null }
        messages.set(key, st)
      }
      // Уже ждёт отправки: просто подменяем текст, победит последний.
      if (st.pending !== null) {
        st.pending.text = text
        st.pending.opts = editOpts
        return
      }
      const dueAt = reserveSlot(chatId, st.lastSentAt + minEditIntervalMs)
      if (dueAt <= t) {
        // Слот свободен - отправляем сразу и отдаём вызывающему настоящий результат.
        await sendEdit(st, text, editOpts)
        return
      }
      const timer = setTimer(() => flushPending(key), dueAt - t)
      st.pending = { text, opts: editOpts, timer }
    },

    setMessageReaction(chatId: string, messageId: number, emoji: string) {
      return base.setMessageReaction(chatId, messageId, emoji)
    },

    async sendChatAction(chatId: string, action: ChatAction): Promise<void> {
      failIfBanned()
      const t = now()
      const last = lastTypingAt.get(chatId)
      if (last !== undefined && t - last < typingMinIntervalMs) return
      lastTypingAt.set(chatId, t)
      await base.sendChatAction(chatId, action)
    },

    sendDocument(chatId: string, filePath: string, docOpts: SendDocumentOpts) {
      return base.sendDocument(chatId, filePath, docOpts)
    },

    sendPhoto(chatId: string, filePath: string, photoOpts: SendDocumentOpts) {
      return base.sendPhoto(chatId, filePath, photoOpts)
    },

    downloadFile(fileId: string, destDir: string): Promise<DownloadResult> {
      return base.downloadFile(fileId, destDir)
    },

    async deleteMessage(chatId: string, messageId: number): Promise<void> {
      // Удаляемое сообщение больше не нужно править.
      const key = keyOf(chatId, messageId)
      const st = messages.get(key)
      if (st?.pending != null) clearTimer(st.pending.timer)
      messages.delete(key)
      return base.deleteMessage(chatId, messageId)
    },
  }
}
