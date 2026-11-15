// Журнал вызовов Telegram Bot API: одна JSON-строка на вызов.
//
// Зачем: при flood-бане нужно задним числом видеть, КАКИЕ вызовы и в каком
// темпе шли в Telegram (stderr плагина не сохраняется). Журнал лежит в каталоге
// состояния плагина (logs/bot-api.jsonl) и ротируется по размеру.
//
// Что пишется: ts, method, chat_id, category (critical/background/reaction),
// result (ok / http_<код> / network_error / skipped_*), duration_ms, для 429 -
// retry_after. НИКОГДА не пишется текст сообщений, описания ошибок Telegram,
// пути файлов и токен бота: журнал не должен становиться второй копией
// переписки или утечкой секрета.
//
// Пропуски (вызов не ушёл в сеть из-за лимита или бана) схлопываются счётчиком
// раз в минуту на ключ (method, chat_id, category, причина): шторм хуков не
// превращается в шторм строк.
//
// Любая ошибка записи гасится (журнал вспомогательный и не должен ломать отправку).

import {
  appendFileSync,
  chmodSync,
  mkdirSync,
  renameSync,
  rmSync,
  statSync,
} from 'node:fs'
import { dirname } from 'node:path'

import type { Logger } from '../log.js'

/** Путь вызова: ответ агента, фон (статус/прогресс/typing) или реакция. */
export type ApiCallCategory = 'critical' | 'background' | 'reaction'

/** Почему вызов не ушёл в сеть. */
export type SkipReason = 'skipped_throttled' | 'skipped_banned'

export interface ApiCallEntry {
  method: string
  /** Id чата как есть (не ПДн-текст); null для методов без чата (скачивание файла). */
  chatId: string | null
  category: ApiCallCategory
  /** 'ok', 'http_<код>', 'network_error'. */
  result: string
  durationMs: number
  /** Только для 429. */
  retryAfterSec?: number
}

export interface ApiCallLog {
  /** Вызов дошёл до сети (успешно или с ошибкой). */
  record(entry: ApiCallEntry): void
  /** Вызов не ушёл в сеть; копится в счётчик минуты. */
  recordSkip(
    method: string,
    chatId: string | null,
    category: ApiCallCategory,
    reason: SkipReason,
  ): void
  /** Сбросить накопленные счётчики пропусков (при выходе). */
  flush(): void
}

export interface ApiCallLogOptions {
  /** Путь основного файла; ротированные: <путь>.1, <путь>.2 ... */
  path: string
  /** Размер файла, после которого ротация. */
  maxBytes?: number
  /** Всего файлов, включая основной. */
  maxFiles?: number
  log?: Logger
  /** Шов для тестов. */
  now?: () => number
}

const BYTES_PER_MB = 1024 * 1024
export const DEFAULT_API_LOG_MAX_BYTES = 5 * BYTES_PER_MB
export const DEFAULT_API_LOG_MAX_FILES = 3
const MS_PER_MINUTE = 60_000
// Журнал содержит id чатов: как и остальное состояние плагина, только владельцу.
const LOG_FILE_MODE = 0o600
// Предупреждение о сбое записи не чаще раза в минуту, чтобы не засорять stderr.
const WARN_INTERVAL_MS = MS_PER_MINUTE
// В chat_id допустимы только числовой id или @username канала: любое другое
// значение (например, ошибочно переданный текст) в журнал не попадает.
const SAFE_CHAT_ID = /^(-?\d{1,20}|@[A-Za-z0-9_]{1,64})$/
const INVALID_CHAT_ID = '<invalid>'

function safeChatId(chatId: string | null): string | null {
  if (chatId === null) return null
  return SAFE_CHAT_ID.test(chatId) ? chatId : INVALID_CHAT_ID
}

interface SkipBucket {
  minuteStart: number
  method: string
  chatId: string | null
  category: ApiCallCategory
  reason: SkipReason
  count: number
}

export function createApiCallLog(opts: ApiCallLogOptions): ApiCallLog {
  const maxBytes = opts.maxBytes ?? DEFAULT_API_LOG_MAX_BYTES
  const maxFiles = Math.max(1, opts.maxFiles ?? DEFAULT_API_LOG_MAX_FILES)
  const now = opts.now ?? ((): number => Date.now())
  const path = opts.path

  let size = readSize()
  let lastWarnAt = Number.NEGATIVE_INFINITY
  const skips = new Map<string, SkipBucket>()

  function readSize(): number {
    try {
      return statSync(path).size
    } catch {
      return 0
    }
  }

  function warnOnce(msg: string, err: unknown): void {
    const t = now()
    if (t - lastWarnAt < WARN_INTERVAL_MS) return
    lastWarnAt = t
    opts.log?.warn(msg, { error: err instanceof Error ? err.message : String(err) })
  }

  // bot-api.jsonl -> .1 -> .2 ...; самый старый удаляется.
  function rotate(): void {
    const oldest = `${path}.${maxFiles - 1}`
    if (maxFiles > 1) rmSync(oldest, { force: true })
    for (let i = maxFiles - 2; i >= 1; i -= 1) {
      try {
        renameSync(`${path}.${i}`, `${path}.${i + 1}`)
      } catch (err) {
        if ((err as NodeJS.ErrnoException).code !== 'ENOENT') throw err
      }
    }
    if (maxFiles > 1) renameSync(path, `${path}.1`)
    else rmSync(path, { force: true })
    size = 0
  }

  function writeLine(obj: Record<string, unknown>): void {
    try {
      const line = `${JSON.stringify(obj)}\n`
      const bytes = Buffer.byteLength(line)
      if (size > 0 && size + bytes > maxBytes) rotate()
      mkdirSync(dirname(path), { recursive: true })
      const isNew = size === 0
      appendFileSync(path, line, { mode: LOG_FILE_MODE })
      if (isNew) chmodSync(path, LOG_FILE_MODE)
      size += bytes
    } catch (err) {
      // Строка теряется, отправка не страдает.
      warnOnce('bot api log write failed (ignored)', err)
      size = readSize()
    }
  }

  function flushSkips(force: boolean): void {
    const currentMinute = Math.floor(now() / MS_PER_MINUTE) * MS_PER_MINUTE
    for (const [key, b] of skips) {
      if (!force && b.minuteStart >= currentMinute) continue
      skips.delete(key)
      writeLine({
        ts: new Date(b.minuteStart).toISOString(),
        method: b.method,
        chat_id: b.chatId,
        category: b.category,
        result: b.reason,
        count: b.count,
        duration_ms: 0,
      })
    }
  }

  // Минута сменилась, а новых событий нет: счётчики всё равно должны попасть в файл.
  const timer = setInterval(() => {
    try {
      flushSkips(false)
    } catch {
      // журнал не должен ронять процесс
    }
  }, MS_PER_MINUTE)
  ;(timer as { unref?: () => void }).unref?.()

  return {
    record(entry: ApiCallEntry): void {
      try {
        flushSkips(false)
        const obj: Record<string, unknown> = {
          ts: new Date(now()).toISOString(),
          method: entry.method,
          chat_id: safeChatId(entry.chatId),
          category: entry.category,
          result: entry.result,
          duration_ms: Math.max(0, Math.round(entry.durationMs)),
        }
        if (entry.retryAfterSec !== undefined) obj.retry_after = entry.retryAfterSec
        writeLine(obj)
      } catch (err) {
        warnOnce('bot api log record failed (ignored)', err)
      }
    },

    recordSkip(method, chatId, category, reason): void {
      try {
        flushSkips(false)
        const minuteStart = Math.floor(now() / MS_PER_MINUTE) * MS_PER_MINUTE
        const chat = safeChatId(chatId)
        const key = `${minuteStart}|${method}|${chat ?? ''}|${category}|${reason}`
        const b = skips.get(key)
        if (b !== undefined) b.count += 1
        else skips.set(key, { minuteStart, method, chatId: chat, category, reason, count: 1 })
      } catch (err) {
        warnOnce('bot api log skip failed (ignored)', err)
      }
    },

    flush(): void {
      try {
        flushSkips(true)
      } catch (err) {
        warnOnce('bot api log flush failed (ignored)', err)
      }
    },
  }
}
