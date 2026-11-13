// Fallback-reply: страховка от «тишины» агента.
//
// Агент отвечает пользователю в Telegram инструментом канала `reply`
// (или правит своё сообщение через `edit_message`). Если ход закончился
// (Stop-хук), а ни одного из этих вызовов в ходе не было,
// пользователь остаётся без ответа, хотя финальный текст в транскрипте есть.
// Этот модуль по пути транскрипта решает, нужен ли fallback, и отправляет
// последний текст ассистента в чат входящего сообщения.
//
// Решает СЕРВЕР, а не хук: хук только передаёт transcript_path/session_id
// из stdin Stop-хука (см. scripts/fallback-reply-hook.ts). Функция
// включается явно (TELEGRAM_FALLBACK_REPLY=1); без флага сервис ничего
// не читает и не отправляет.
//
// Инварианты (не слать лишнего):
//   * в ходе был вызов reply / edit_message → молчим;
//   * ход начат не из Telegram (нет ведущего <channel source="telegram" ...>
//     в пользовательском сообщении: задачи task-poller, напоминания,
//     task-notification, набранный в tmux текст) → молчим;
//   * в финальном сегменте хода нет текста ассистента → молчим;
//   * один и тот же ход не отправляется дважды (дедуп по chat_id:message_id
//     входящего сообщения, при его отсутствии — по хэшу текста).

import { createHash } from 'crypto'
import {
  closeSync,
  fstatSync,
  mkdirSync,
  openSync,
  readFileSync,
  readSync,
  realpathSync,
  renameSync,
  writeFileSync,
} from 'fs'
import { dirname, join, sep } from 'path'

import type { Logger } from '../log.js'
import { redactToken } from '../config.js'
import { splitMessage } from '../format/chunk.js'
import { isTelegramHtmlParseError, markdownToTelegramHtml } from '../format/html.js'
import type { SendMessageOpts } from './tools.js'

/** Имена MCP-инструментов канала, любой из которых означает «ответ был». */
export const REPLY_TOOL_NAMES: ReadonlySet<string> = new Set([
  'mcp__labops-channel__reply',
  'mcp__labops-channel__edit_message',
])

/** Пометка в начале fallback-сообщения по умолчанию. */
export const DEFAULT_FALLBACK_PREFIX = '⚠ ответ без reply:'

/** Сколько байт хвоста транскрипта читаем: ход с большими tool_result обычно влезает. */
export const TRANSCRIPT_TAIL_BYTES = 2 * 1024 * 1024

/** Потолок длины fallback-текста (без пометки): защита чата от простыни. */
export const FALLBACK_MAX_CHARS = 16_000

/** Маркер обрезки, если текст длиннее FALLBACK_MAX_CHARS. */
export const TRUNCATION_MARKER = '\n…[обрезано]'

/** Сколько сессий помним для дедупа (старые вытесняются). */
const DEDUP_MAX_SESSIONS = 200

/** Режим файла состояния дедупа: только владелец. */
const STATE_FILE_MODE = 0o600

// ─────────────────────────────────────────────────────────────────────
// Разбор транскрипта
// ─────────────────────────────────────────────────────────────────────

export interface TurnAnalysis {
  /** Был ли в ходе вызов reply / edit_message. */
  readonly replied: boolean
  /** Финальный текст ассистента (после последнего tool_result хода) или undefined. */
  readonly text?: string | undefined
  /** chat_id из ведущего <channel source="telegram" ...> граничного сообщения. */
  readonly chatId?: string | undefined
  /** message_id того же сообщения (для reply_to и дедупа). */
  readonly messageId?: number | undefined
}

interface TranscriptLine {
  readonly message?: unknown
}

/** Ведущий тег <channel ...> текста пользовательского сообщения → chat_id/message_id. */
export function parseLeadingTelegramEnvelope(
  promptText: string,
): { chatId: string; messageId?: number } | undefined {
  // Только ВЕДУЩИЙ тег: такой конверт всегда пишет сам плагин; тег <channel>
  // глубже в тексте (чужое сообщение, эхо транскрипта) не доверенный.
  const leading = /^<channel\b([^>]*)>/.exec(promptText.trimStart())
  if (!leading) return undefined
  const attrs = leading[1] ?? ''
  // Транскрипт хранит JSON-экранированные кавычки (\"), но после JSON.parse
  // они обычные; на всякий случай терпим оба варианта.
  if (!/source\s*=\s*\\?"telegram\\?"/.test(attrs)) return undefined
  const chat = /chat_id\s*=\s*\\?"(-?\d+)\\?"/.exec(attrs)
  if (!chat) return undefined
  const msg = /message_id\s*=\s*\\?"(\d+)\\?"/.exec(attrs)
  const messageId = msg ? Number(msg[1]) : undefined
  const valid = messageId !== undefined && Number.isSafeInteger(messageId) && messageId > 0
  return valid
    ? { chatId: chat[1] as string, messageId: messageId as number }
    : { chatId: chat[1] as string }
}

/** Текст пользовательского сообщения (строка или склейка text-блоков). */
function userPromptText(content: unknown): string | undefined {
  if (typeof content === 'string') return content
  if (!Array.isArray(content)) return undefined
  const parts: string[] = []
  for (const block of content) {
    if (block === null || typeof block !== 'object') continue
    const b = block as Record<string, unknown>
    if (b.type === 'text' && typeof b.text === 'string') parts.push(b.text)
  }
  return parts.length > 0 ? parts.join('\n') : undefined
}

/** Сообщение — эхо tool_result (часть текущего хода), а не новый запрос? */
function isToolResultOnly(content: unknown): boolean {
  if (!Array.isArray(content) || content.length === 0) return false
  return content.every(
    (block) =>
      block !== null &&
      typeof block === 'object' &&
      (block as Record<string, unknown>).type === 'tool_result',
  )
}

/** Это сообщение — настоящий запрос (граница хода)? Пустые не считаем. */
function isGenuinePrompt(content: unknown): boolean {
  if (typeof content === 'string') return content.trim().length > 0
  if (Array.isArray(content)) return content.length > 0 && !isToolResultOnly(content)
  return false
}

function callsReplyTool(content: unknown): boolean {
  if (!Array.isArray(content)) return false
  for (const block of content) {
    if (block === null || typeof block !== 'object') continue
    const b = block as Record<string, unknown>
    if (b.type === 'tool_use' && typeof b.name === 'string' && REPLY_TOOL_NAMES.has(b.name)) {
      return true
    }
  }
  return false
}

function assistantText(content: unknown): string {
  if (!Array.isArray(content)) return ''
  const parts: string[] = []
  for (const block of content) {
    if (block === null || typeof block !== 'object') continue
    const b = block as Record<string, unknown>
    if (b.type === 'text' && typeof b.text === 'string') parts.push(b.text)
  }
  return parts.join('\n')
}

/**
 * Анализ ТЕКУЩЕГО хода по тексту транскрипта (JSONL), с конца до последнего
 * настоящего пользовательского сообщения. Чистая функция, без I/O.
 *
 * `replied` считается по всему ходу. Текст берётся только из финального
 * сегмента — после последнего tool_result: реплики «сейчас проверю…» между
 * вызовами инструментов в чат не уходят.
 */
export function analyzeTurn(transcript: string): TurnAnalysis {
  const lines = transcript.split('\n').filter((l) => l.trim().length > 0)
  let replied = false
  let text: string | undefined
  let textClosed = false
  for (let i = lines.length - 1; i >= 0; i--) {
    let obj: unknown
    try {
      obj = JSON.parse(lines[i] as string)
    } catch {
      continue
    }
    if (obj === null || typeof obj !== 'object') continue
    const message = (obj as TranscriptLine).message
    if (message === null || typeof message !== 'object') continue
    const { role, content } = message as { role?: unknown; content?: unknown }

    if (role === 'user') {
      if (isToolResultOnly(content)) {
        textClosed = true
        continue
      }
      if (!isGenuinePrompt(content)) continue
      // Граница хода: достаём адресата из ведущего конверта.
      const promptText = userPromptText(content)
      const envelope =
        promptText !== undefined ? parseLeadingTelegramEnvelope(promptText) : undefined
      return {
        replied,
        text,
        chatId: envelope?.chatId,
        messageId: envelope?.messageId,
      }
    }
    if (role !== 'assistant') continue
    if (callsReplyTool(content)) replied = true
    if (text === undefined && !textClosed) {
      const t = assistantText(content)
      if (t.trim().length > 0) text = t
    }
  }
  // Границы хода в окне нет — адресата доказать нельзя, молчим.
  return { replied, text, chatId: undefined, messageId: undefined }
}

/** Читает хвост файла (до TRANSCRIPT_TAIL_BYTES); неполную первую строку отбрасывает. */
export function readTranscriptTail(path: string, maxBytes: number = TRANSCRIPT_TAIL_BYTES): string {
  const fd = openSync(path, 'r')
  try {
    const size = fstatSync(fd).size
    if (size === 0) return ''
    const length = Math.min(size, maxBytes)
    const start = size - length
    const buf = Buffer.alloc(length)
    readSync(fd, buf, 0, length, start)
    const text = buf.toString('utf8')
    if (start === 0) return text
    const nl = text.indexOf('\n')
    return nl >= 0 ? text.slice(nl + 1) : ''
  } finally {
    try {
      closeSync(fd)
    } catch {
      /* ignore */
    }
  }
}

/** Режем слишком длинный текст с маркером, чтобы не завалить чат. */
export function truncateFallbackText(text: string): string {
  if (text.length <= FALLBACK_MAX_CHARS) return text
  return text.slice(0, FALLBACK_MAX_CHARS - TRUNCATION_MARKER.length) + TRUNCATION_MARKER
}

// ─────────────────────────────────────────────────────────────────────
// Сервис
// ─────────────────────────────────────────────────────────────────────

export type FallbackReplyStatus =
  | 'disabled'
  | 'bad_path'
  | 'unreadable'
  | 'replied'
  | 'not_telegram'
  | 'no_text'
  | 'duplicate'
  | 'chat_not_allowed'
  | 'sent'
  | 'send_failed'

export interface FallbackReplyResult {
  readonly status: FallbackReplyStatus
}

export interface FallbackReplyRequest {
  readonly transcript_path: string
  readonly session_id?: string | undefined
}

export interface FallbackReplyServiceOpts {
  /** Флаг TELEGRAM_FALLBACK_REPLY; false → handle() сразу отвечает 'disabled'. */
  readonly enabled: boolean
  /** Каталоги, внутри которых разрешены транскрипты (обычно ~/.claude/projects). */
  readonly transcriptRoots: readonly string[]
  /** Файл состояния дедупа (рядом с остальным state плагина). */
  readonly statePath: string
  /** Пометка перед текстом; пустая строка — без пометки. */
  readonly prefix: string
  readonly log: Logger
  /** Отправка одного сообщения (safe-обёртка: редакция токенов, rate-limit). */
  readonly sendMessage: (
    chatId: string,
    text: string,
    opts: SendMessageOpts,
  ) => Promise<{ message_id: number }>
  /** Чат разрешён политикой плагина? Как для инструмента reply. */
  readonly isChatAllowed: (chatId: string) => boolean
  /** Хук после успешной отправки (снять статус «Печатает…»). */
  readonly afterSend?: ((chatId: string) => Promise<void>) | undefined
}

/** Безопасное имя ключа сессии. */
function sessionKey(req: FallbackReplyRequest): string {
  const raw = req.session_id && req.session_id.length > 0 ? req.session_id : req.transcript_path
  return raw.replace(/[^A-Za-z0-9._-]/g, '_').slice(0, 128) || 'session'
}

function hashText(text: string): string {
  return createHash('sha256').update(text, 'utf8').digest('hex').slice(0, 32)
}

export class FallbackReplyService {
  private readonly opts: FallbackReplyServiceOpts
  /** session → токен последнего отправленного хода. Порядок вставки = порядок вытеснения. */
  private readonly sent = new Map<string, string>()
  /** Ходы «в полёте»: параллельный второй Stop не должен отправить дубль. */
  private readonly inFlight = new Set<string>()

  constructor(opts: FallbackReplyServiceOpts) {
    this.opts = opts
    if (opts.enabled) this.loadState()
  }

  get enabled(): boolean {
    return this.opts.enabled
  }

  async handle(req: FallbackReplyRequest): Promise<FallbackReplyResult> {
    const { log } = this.opts
    if (!this.opts.enabled) return { status: 'disabled' }

    const path = this.resolveTranscriptPath(req.transcript_path)
    if (path === undefined) {
      log.warn('fallback-reply: transcript path rejected')
      return { status: 'bad_path' }
    }

    let transcript: string
    try {
      transcript = readTranscriptTail(path)
    } catch {
      return { status: 'unreadable' }
    }

    const turn = analyzeTurn(transcript)
    if (turn.replied) return { status: 'replied' }
    if (turn.chatId === undefined) return { status: 'not_telegram' }
    if (turn.text === undefined) return { status: 'no_text' }

    const chatId = turn.chatId
    if (!this.opts.isChatAllowed(chatId)) {
      log.warn('fallback-reply: chat not allowed', { chat_id: chatId })
      return { status: 'chat_not_allowed' }
    }

    const key = sessionKey(req)
    const token =
      turn.messageId !== undefined ? `${chatId}:${turn.messageId}` : `text:${hashText(turn.text)}`
    if (this.sent.get(key) === token || this.inFlight.has(`${key}|${token}`)) {
      return { status: 'duplicate' }
    }

    this.inFlight.add(`${key}|${token}`)
    try {
      await this.deliver(chatId, turn.text, turn.messageId)
    } catch (err) {
      // Токен не записываем: повторный Stop того же хода попробует снова.
      log.warn('fallback-reply: send failed', {
        chat_id: chatId,
        error: err instanceof Error ? redactToken(err.message) : String(err),
      })
      return { status: 'send_failed' }
    } finally {
      this.inFlight.delete(`${key}|${token}`)
    }

    this.remember(key, token)
    if (this.opts.afterSend) {
      try {
        await this.opts.afterSend(chatId)
      } catch (err) {
        log.warn('fallback-reply: afterSend failed (ignored)', {
          error: err instanceof Error ? redactToken(err.message) : String(err),
        })
      }
    }
    log.info('fallback-reply sent', { chat_id: chatId, message_id: turn.messageId ?? null })
    return { status: 'sent' }
  }

  /** Путь должен быть .jsonl внутри разрешённого корня (после realpath). */
  private resolveTranscriptPath(raw: string): string | undefined {
    if (!raw.endsWith('.jsonl')) return undefined
    let real: string
    try {
      real = realpathSync(raw)
    } catch {
      return undefined
    }
    for (const root of this.opts.transcriptRoots) {
      let realRoot: string
      try {
        realRoot = realpathSync(root)
      } catch {
        continue
      }
      if (real.startsWith(realRoot + sep)) return real
    }
    return undefined
  }

  /** Markdown → HTML, пометка, разбиение; reply_to только на первом куске. */
  private async deliver(
    chatId: string,
    rawText: string,
    replyTo: number | undefined,
  ): Promise<void> {
    const { prefix, sendMessage, log } = this.opts
    const body = truncateFallbackText(rawText.trim())
    const markdown = prefix.length > 0 ? `${prefix}\n\n${body}` : body
    const chunks = splitMessage(markdownToTelegramHtml(markdown))
    for (let i = 0; i < chunks.length; i++) {
      const chunk = chunks[i] as string
      const first = i === 0 && replyTo !== undefined
      const htmlOpts: SendMessageOpts = { parse_mode: 'HTML' }
      if (first) htmlOpts.reply_to_message_id = replyTo
      try {
        await sendMessage(chatId, chunk, htmlOpts)
      } catch (err) {
        // Как в инструменте reply: Telegram отклонил HTML — шлём этот же
        // кусок простым текстом, лучше потерять <b>, чем ответ.
        if (!isTelegramHtmlParseError(err)) throw err
        log.warn('fallback-reply: HTML parse failed, retrying as plain text', { chunk_index: i })
        const plainOpts: SendMessageOpts = {}
        if (first) plainOpts.reply_to_message_id = replyTo
        await sendMessage(chatId, chunk, plainOpts)
      }
    }
  }

  private remember(key: string, token: string): void {
    this.sent.delete(key)
    this.sent.set(key, token)
    while (this.sent.size > DEDUP_MAX_SESSIONS) {
      const oldest = this.sent.keys().next().value
      if (oldest === undefined) break
      this.sent.delete(oldest)
    }
    this.saveState()
  }

  private loadState(): void {
    try {
      const parsed: unknown = JSON.parse(readFileSync(this.opts.statePath, 'utf8'))
      if (parsed === null || typeof parsed !== 'object') return
      const entries = (parsed as { entries?: unknown }).entries
      if (!Array.isArray(entries)) return
      for (const e of entries) {
        if (Array.isArray(e) && typeof e[0] === 'string' && typeof e[1] === 'string') {
          this.sent.set(e[0], e[1])
        }
      }
    } catch {
      /* файла нет или он битый — начинаем с пустого дедупа */
    }
  }

  private saveState(): void {
    try {
      mkdirSync(dirname(this.opts.statePath), { recursive: true, mode: 0o700 })
      const tmp = `${this.opts.statePath}.tmp`
      writeFileSync(tmp, JSON.stringify({ entries: [...this.sent.entries()] }), {
        mode: STATE_FILE_MODE,
      })
      renameSync(tmp, this.opts.statePath)
    } catch (err) {
      // Дедуп best-effort: потеря состояния даёт максимум один редкий дубль.
      this.opts.log.warn('fallback-reply: state write failed', {
        error: err instanceof Error ? redactToken(err.message) : String(err),
      })
    }
  }
}

/** Корни, откуда разрешено читать транскрипты: ~/.claude/projects и $CLAUDE_CONFIG_DIR/projects. */
export function defaultTranscriptRoots(
  env: Readonly<Record<string, string | undefined>>,
  home: string,
): string[] {
  const roots = [join(home, '.claude', 'projects')]
  const cfg = env.CLAUDE_CONFIG_DIR
  if (cfg && cfg.length > 0) roots.push(join(cfg, 'projects'))
  return roots
}
