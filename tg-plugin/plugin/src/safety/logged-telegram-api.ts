// Обёртка TelegramApi, пишущая каждый вызов в журнал Bot API (api-call-log.ts).
//
// Ставится ПОД лимитером, прямо над grammY-клиентом: так журнал видит только
// реальные походы в сеть, а их длительность и результат (ok / http-код / 429 с
// retry_after) настоящие. Пропуски из-за лимита и бана пишут сами лимитеры
// через onSkip. Текст сообщений, описание ошибок и пути файлов в журнал не
// попадают: в запись уходят только метод, id чата, категория и результат.

import type {
  ChatAction,
  DownloadResult,
  EditOpts,
  SendDocumentOpts,
  SendMessageOpts,
  TelegramApi,
} from '../channel/tools.js'
import type { ApiCallCategory, ApiCallLog } from './api-call-log.js'

export const RESULT_OK = 'ok'
export const RESULT_NETWORK_ERROR = 'network_error'
export const RESULT_ERROR = 'error'

/** Реакции лимитируются отдельно, поэтому у них своя категория независимо от пути. */
export function categoryFor(method: string, pathCategory: ApiCallCategory): ApiCallCategory {
  return method === 'setMessageReaction' ? 'reaction' : pathCategory
}

interface ClassifiedError {
  result: string
  retryAfterSec?: number
}

// grammY: GrammyError имеет error_code (HTTP-код Bot API), HttpError - сетевой сбой.
function classifyError(err: unknown): ClassifiedError {
  if (typeof err !== 'object' || err === null) return { result: RESULT_ERROR }
  const e = err as {
    name?: unknown
    error_code?: unknown
    parameters?: { retry_after?: unknown }
  }
  if (typeof e.error_code === 'number') {
    const out: ClassifiedError = { result: `http_${e.error_code}` }
    const after = e.parameters?.retry_after
    if (e.error_code === 429 && typeof after === 'number' && Number.isFinite(after)) {
      out.retryAfterSec = after
    }
    return out
  }
  if (e.name === 'HttpError') return { result: RESULT_NETWORK_ERROR }
  return { result: RESULT_ERROR }
}

export function createLoggedTelegramApi(
  base: TelegramApi,
  journal: ApiCallLog,
  pathCategory: ApiCallCategory,
  now: () => number = (): number => Date.now(),
): TelegramApi {
  async function timed<T>(method: string, chatId: string | null, op: () => Promise<T>): Promise<T> {
    const started = now()
    const category = categoryFor(method, pathCategory)
    try {
      const out = await op()
      journal.record({
        method,
        chatId,
        category,
        result: RESULT_OK,
        durationMs: now() - started,
      })
      return out
    } catch (err) {
      const c = classifyError(err)
      journal.record({
        method,
        chatId,
        category,
        result: c.result,
        durationMs: now() - started,
        ...(c.retryAfterSec !== undefined ? { retryAfterSec: c.retryAfterSec } : {}),
      })
      throw err
    }
  }

  return {
    sendMessage(chatId: string, text: string, opts: SendMessageOpts) {
      return timed('sendMessage', chatId, () => base.sendMessage(chatId, text, opts))
    },
    editMessageText(chatId: string, messageId: number, text: string, opts: EditOpts) {
      return timed('editMessageText', chatId, () =>
        base.editMessageText(chatId, messageId, text, opts),
      )
    },
    setMessageReaction(chatId: string, messageId: number, emoji: string) {
      return timed('setMessageReaction', chatId, () =>
        base.setMessageReaction(chatId, messageId, emoji),
      )
    },
    sendChatAction(chatId: string, action: ChatAction) {
      return timed('sendChatAction', chatId, () => base.sendChatAction(chatId, action))
    },
    sendDocument(chatId: string, filePath: string, opts: SendDocumentOpts) {
      return timed('sendDocument', chatId, () => base.sendDocument(chatId, filePath, opts))
    },
    sendPhoto(chatId: string, filePath: string, opts: SendDocumentOpts) {
      return timed('sendPhoto', chatId, () => base.sendPhoto(chatId, filePath, opts))
    },
    downloadFile(fileId: string, destDir: string): Promise<DownloadResult> {
      return timed('downloadFile', null, () => base.downloadFile(fileId, destDir))
    },
    deleteMessage(chatId: string, messageId: number) {
      return timed('deleteMessage', chatId, () => base.deleteMessage(chatId, messageId))
    },
  }
}
