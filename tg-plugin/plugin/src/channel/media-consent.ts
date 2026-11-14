// Разрешение владельца на отправку ОРИГИНАЛА вложения с ПДн модели.
//
// Поток: pii-proxy отдаёт модели закрашенную версию и пишет предложение
// `<dir>/offers/<media_id>.json` (отпечаток sha256, типы ПДн без значений). Агент вызывает
// инструмент request_media_consent(media_id): владельцу уходит сообщение с одноразовым
// 6-значным кодом. Владелец отвечает этим кодом; если отправитель (from.id, не chat.id)
// входит в список подтверждающих, код совпал и не просрочен -- пишется файл разрешения
// `<dir>/<sha256>.json`, который читает прокси.
//
// Граница доверия: у агента НЕТ инструмента записи разрешения, а сообщение с кодом
// перехватывается здесь и агенту не доставляется. Но плагин, прокси и агент работают под
// одним пользователем ОС: взломанный агент может записать файл сам. Защита рассчитана на
// «агента уговорили разрешить самому», а не на полный взлом процесса агента.
//
// Формат файлов и константы зеркалят labops-pii (ts/src/media-consent.ts, constants.ts).

import { randomBytes, randomInt } from 'crypto'
import {
  chmodSync, existsSync, mkdirSync, readFileSync, renameSync, writeFileSync,
} from 'fs'
import { homedir } from 'os'
import { join } from 'path'
import { z } from 'zod'

import type { AppConfig } from '../config.js'
import type { Logger } from '../log.js'
import { MEDIA_ID_RE, RequestMediaConsentArgsSchema } from '../schemas.js'
import type { TelegramApi } from './tools.js'

/** Срок действия кода, мс. */
export const CONSENT_CODE_TTL_MS = 15 * 60 * 1000
/** Срок действия разрешения с момента подтверждения, мс (зеркало CONSENT_TTL_MS прокси). */
export const CONSENT_TTL_MS = 30 * 60 * 1000
/** Не чаще одного запроса на одно вложение в этот срок, мс (не спамить владельца). */
export const CONSENT_REQUEST_COOLDOWN_MS = 60 * 1000
/** Сколько незакрытых запросов одновременно. */
export const CONSENT_MAX_PENDING = 10
/** Длина кода. */
const CODE_DIGITS = 6
const CODE_SPACE = 10 ** CODE_DIGITS
const CODE_RE = /^\d{6}$/
/** Предел текста причины от агента в сообщении владельцу. */
const REASON_MAX_CHARS = 200
const DIR_MODE = 0o700
const FILE_MODE = 0o600
const OFFERS_DIR = 'offers'
const SHA256_RE = /^[0-9a-f]{64}$/
const KIND_RE = /^[A-Z][A-Z0-9_]{0,23}$/

const offerSchema = z.object({
  sha256: z.string().regex(SHA256_RE),
  kinds: z.array(z.string()).default([]),
  agent: z.string().min(1),
})
const approvalSchema = z.object({
  sha256: z.string().regex(SHA256_RE),
  agent: z.string().min(1),
  approved_at: z.string().datetime(),
  expires_at: z.string().datetime(),
})

/** Каталог разрешений по умолчанию (общий с pii-proxy). */
export function defaultConsentDir(): string {
  return join(homedir(), '.config', 'labops-pii', 'consent')
}

/**
 * Кто может подтвердить: явный список, иначе операторы, иначе allowlist.
 *
 * @param config Конфиг плагина.
 */
export function resolveConsentApprovers(config: AppConfig): readonly number[] {
  return config.media_consent?.approver_user_ids
    ?? config.operator_user_ids
    ?? config.allowed_user_ids
}

interface PendingConsent {
  readonly code: string
  readonly mediaId: string
  readonly sha256: string
  readonly kinds: readonly string[]
  readonly createdAt: number
  readonly expiresAt: number
}

export interface MediaConsentDeps {
  config: AppConfig
  telegramApi: Pick<TelegramApi, 'sendMessage'>
  log: Logger
  /** Имя агента: попадает в сообщение владельцу и в файл разрешения. */
  agentId: string
  /** Сообщить сессии агента (обычное уведомление канала). */
  notifyAgent: (content: string, chatId: string) => Promise<void>
  /** Каталог разрешений; по умолчанию ~/.config/labops-pii/consent. */
  dir?: string
  now?: () => number
  /** Генератор кода (в тестах подменяется). */
  randomCode?: () => string
}

export interface ConsentTextInput {
  /** Отправитель сообщения (from.id): именно он проверяется, не chat.id. */
  fromUserId: number | undefined
  chatId: string
  text: string
}

export interface ConsentToolResult {
  ok: boolean
  message: string
}

/** Запросы разрешений и проверка кода владельца. */
export class MediaConsent {
  private readonly pending = new Map<string, PendingConsent>() // код -> запрос
  private readonly dir: string
  private readonly now: () => number
  private readonly randomCode: () => string

  constructor(private readonly deps: MediaConsentDeps) {
    this.dir = deps.dir ?? deps.config.media_consent?.dir ?? defaultConsentDir()
    this.now = deps.now ?? (() => Date.now())
    this.randomCode = deps.randomCode
      ?? (() => String(randomInt(0, CODE_SPACE)).padStart(CODE_DIGITS, '0'))
  }

  /** Число незакрытых запросов (для тестов и логов). */
  get pendingCount(): number {
    return this.pending.size
  }

  /**
   * Инструмент request_media_consent: отправить владельцу запрос с кодом.
   * Код агенту не возвращается.
   */
  async request(rawArgs: unknown): Promise<ConsentToolResult> {
    const parsed = RequestMediaConsentArgsSchema.safeParse(rawArgs)
    if (!parsed.success) {
      return { ok: false, message: parsed.error.errors.map(e => e.message).join('; ') }
    }
    const { media_id: mediaId, kinds: agentKinds, reason } = parsed.data
    const offer = this.readOffer(mediaId)
    if (offer === undefined) {
      return {
        ok: false,
        message: 'неизвестный media_id: оригинал можно запросить только для вложения, '
          + 'которое прокси показал закрашенным (id указан рядом с вложением)',
      }
    }
    if (offer.agent !== this.deps.agentId) {
      this.deps.log.warn('media_consent.offer_other_agent', { media_id: mediaId })
      return { ok: false, message: 'вложение относится к другому агенту' }
    }
    if (this.isApproved(offer.sha256)) {
      return { ok: true, message: 'разрешение уже действует: перечитайте файл' }
    }
    const now = this.now()
    this.dropExpired(now)
    for (const p of this.pending.values()) {
      if (p.mediaId === mediaId && now - p.createdAt < CONSENT_REQUEST_COOLDOWN_MS) {
        return { ok: false, message: 'запрос уже отправлен владельцу, ждите ответа' }
      }
    }
    if (this.pending.size >= CONSENT_MAX_PENDING) {
      return { ok: false, message: 'слишком много неотвеченных запросов, подождите' }
    }
    const approvers = resolveConsentApprovers(this.deps.config)
    if (approvers.length === 0) return { ok: false, message: 'некому подтверждать запрос' }

    // Типы - из записи прокси; от агента только если там пусто
    const kinds = offer.kinds.length > 0 ? offer.kinds : sanitizeKinds(agentKinds ?? [])
    const code = this.freshCode()
    // Старый запрос на то же вложение заменяется: действует только последний код
    for (const [c, p] of this.pending) if (p.mediaId === mediaId) this.pending.delete(c)
    this.pending.set(code, {
      code, mediaId, sha256: offer.sha256, kinds,
      createdAt: now, expiresAt: now + CONSENT_CODE_TTL_MS,
    })

    const text = this.requestText(mediaId, kinds, code, reason)
    let sent = 0
    for (const id of approvers) {
      try {
        await this.deps.telegramApi.sendMessage(String(id), text, {})
        sent++
      } catch (err) {
        this.deps.log.warn('media_consent.send_failed', {
          approver: id, error: err instanceof Error ? err.message : String(err),
        })
      }
    }
    if (sent === 0) {
      this.pending.delete(code)
      return { ok: false, message: 'не удалось отправить запрос владельцу' }
    }
    this.deps.log.info('media_consent.requested', { media_id: mediaId, kinds, approvers: sent })
    return {
      ok: true,
      message: 'Запрос отправлен владельцу. Он ответит одноразовым кодом, код вам не '
        + 'передаётся. Когда придёт сообщение о подтверждении, перечитайте файл.',
    }
  }

  /**
   * Сообщение из Telegram: если это действующий код от подтверждающего, оформить разрешение.
   *
   * @returns true, если сообщение потреблено (агенту его доставлять не нужно).
   */
  async tryHandleText(input: ConsentTextInput): Promise<boolean> {
    const code = input.text.trim()
    if (!CODE_RE.test(code)) return false
    const p = this.pending.get(code)
    if (p === undefined) return false
    const sender = input.fromUserId
    if (sender === undefined || !resolveConsentApprovers(this.deps.config).includes(sender)) {
      // Код чужой руки: разрешения нет. Сам код в журнал не пишется
      this.deps.log.warn('media_consent.code_wrong_sender', {
        from_id: sender, chat_id: input.chatId, media_id: p.mediaId,
      })
      return false
    }
    const now = this.now()
    if (now >= p.expiresAt) {
      this.pending.delete(code)
      await this.reply(input.chatId, 'Код просрочен, разрешения нет. Агент может запросить заново.')
      this.deps.log.info('media_consent.code_expired', { media_id: p.mediaId })
      return true
    }
    try {
      this.writeApproval(p, sender, now)
    } catch (err) {
      this.deps.log.error('media_consent.write_failed', {
        media_id: p.mediaId, error: err instanceof Error ? err.message : String(err),
      })
      await this.reply(input.chatId, 'Не удалось записать разрешение. Попробуйте ещё раз позже.')
      return true
    }
    this.pending.delete(code) // одноразовый
    this.deps.log.info('media_consent.approved', { media_id: p.mediaId, approved_by: sender })
    await this.reply(
      input.chatId,
      `Разрешено: оригинал вложения ${p.mediaId} доступен агенту ${this.deps.agentId} `
      + `на ${CONSENT_TTL_MS / 60_000} минут.`,
    )
    try {
      await this.deps.notifyAgent(
        `Владелец разрешил отправить оригинал вложения ${p.mediaId} на `
        + `${CONSENT_TTL_MS / 60_000} минут. Перечитайте файл.`,
        input.chatId,
      )
    } catch (err) {
      this.deps.log.warn('media_consent.notify_failed', {
        error: err instanceof Error ? err.message : String(err),
      })
    }
    return true
  }

  private requestText(
    mediaId: string,
    kinds: readonly string[],
    code: string,
    reason: string | undefined,
  ): string {
    const lines = [
      `Агент ${this.deps.agentId} просит разрешение отправить ОРИГИНАЛ вложения (id ${mediaId}).`,
      `Найдены персональные данные: ${kinds.length > 0 ? kinds.join(', ') : 'тип не определён'}.`,
      'Оригинал уйдёт в Anthropic за границу (передача ПДн).',
    ]
    const why = reason === undefined ? '' : cleanReason(reason)
    if (why !== '') lines.push(`Причина от агента: ${why}`)
    lines.push(
      '',
      `Чтобы разрешить, ответьте этим кодом: ${code}`,
      `Код одноразовый, действует ${CONSENT_CODE_TTL_MS / 60_000} минут. Если не согласны, `
      + 'проигнорируйте сообщение.',
    )
    return lines.join('\n')
  }

  private async reply(chatId: string, text: string): Promise<void> {
    try {
      await this.deps.telegramApi.sendMessage(chatId, text, {})
    } catch (err) {
      this.deps.log.warn('media_consent.reply_failed', {
        error: err instanceof Error ? err.message : String(err),
      })
    }
  }

  private freshCode(): string {
    for (let i = 0; i < 20; i++) {
      const c = this.randomCode()
      if (!this.pending.has(c)) return c
    }
    throw new Error('не удалось выбрать уникальный код')
  }

  private dropExpired(now: number): void {
    for (const [c, p] of this.pending) if (now >= p.expiresAt) this.pending.delete(c)
  }

  private readOffer(mediaId: string): { sha256: string; kinds: string[]; agent: string } | undefined {
    if (!MEDIA_ID_RE.test(mediaId)) return undefined
    try {
      const file = join(this.dir, OFFERS_DIR, `${mediaId}.json`)
      if (!existsSync(file)) return undefined
      const parsed = offerSchema.safeParse(JSON.parse(readFileSync(file, 'utf8')))
      if (!parsed.success) return undefined
      // id обязан соответствовать отпечатку: запись нельзя подменить под чужой id
      if (`m${parsed.data.sha256.slice(0, 11)}` !== mediaId) return undefined
      return { ...parsed.data, kinds: sanitizeKinds(parsed.data.kinds) }
    } catch {
      return undefined
    }
  }

  private isApproved(sha256: string): boolean {
    try {
      const file = join(this.dir, `${sha256}.json`)
      if (!existsSync(file)) return false
      const parsed = approvalSchema.safeParse(JSON.parse(readFileSync(file, 'utf8')))
      return parsed.success && Date.parse(parsed.data.expires_at) > this.now()
        && parsed.data.agent === this.deps.agentId
    } catch {
      return false
    }
  }

  private writeApproval(p: PendingConsent, approvedBy: number, now: number): void {
    mkdirSync(this.dir, { recursive: true, mode: DIR_MODE })
    chmodSync(this.dir, DIR_MODE)
    const record = {
      sha256: p.sha256,
      agent: this.deps.agentId,
      kinds: p.kinds,
      approved_by: approvedBy,
      approved_at: new Date(now).toISOString(),
      expires_at: new Date(now + CONSENT_TTL_MS).toISOString(),
    }
    const file = join(this.dir, `${p.sha256}.json`)
    // Атомарно: временный файл рядом с правами 600, затем rename
    const tmp = `${file}.tmp-${randomBytes(6).toString('hex')}`
    writeFileSync(tmp, JSON.stringify(record), { mode: FILE_MODE })
    renameSync(tmp, file)
  }
}

function sanitizeKinds(kinds: readonly string[]): string[] {
  return [...new Set(kinds.filter(k => KIND_RE.test(k)))].sort().slice(0, 16)
}

/** Причина от агента: одна строка без управляющих символов, ограниченной длины. */
function cleanReason(reason: string): string {
  // eslint-disable-next-line no-control-regex
  return reason.replace(/[\u0000-\u001f\u007f]+/g, ' ').replace(/\s+/g, ' ').trim()
    .slice(0, REASON_MAX_CHARS)
}
