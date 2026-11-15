// Общее состояние flood-бана Telegram для всего процесса плагина.
//
// Зачем: при 429 с большим retry_after (десятки тысяч секунд) каждый новый
// запрос во время бана его только продлевает, а раньше каждый фоновый вызов
// (зеркало прогресса, typing, правки статуса) ретраился сам по себе и
// долбил Bot API впустую. Здесь хранится ЕДИНЫЙ момент снятия бана: любой
// слой проверяет его до сетевого вызова и не ходит в сеть, пока бан активен.
//
// Бан хранится по группам методов: Telegram ограничивает отправку/правку
// текста отдельно от реакций (реакции проходят при бане sendMessage).
// Состояние сохраняется на диск, чтобы рестарт плагина (watchdog) не
// "забыл" бан и не начал проверять его запросами.

import { chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname } from 'node:path'

import type { Logger } from '../log.js'

/** Группы методов с независимыми flood-лимитами. */
export type FloodGroup = 'message' | 'reaction'

const MS_PER_SECOND = 1000
const SECONDS_PER_MINUTE = 60
const SECONDS_PER_HOUR = 3600
// Файл состояния содержит только метки времени, но держим 0600 как весь state.
const STATE_FILE_MODE = 0o600
// Защита от мусорного retry_after: больше недели не принимаем.
const MAX_BAN_SECONDS = 7 * 24 * SECONDS_PER_HOUR

/** Ошибка "Telegram запретил отправку до такого-то времени"; совместима с 429 grammY. */
export class TelegramFloodError extends Error {
  readonly error_code = 429
  readonly description: string
  readonly parameters: { retry_after: number }
  readonly group: FloodGroup
  readonly bannedUntilMs: number

  constructor(group: FloodGroup, bannedUntilMs: number, nowMs: number) {
    const remainingSec = Math.max(1, Math.ceil((bannedUntilMs - nowMs) / MS_PER_SECOND))
    const untilIso = new Date(bannedUntilMs).toISOString()
    const text =
      `Too Many Requests: Telegram flood control is active until ${untilIso} ` +
      `(in ${formatDuration(remainingSec)}). Sending is blocked locally; ` +
      'do not retry before that time - every attempt during the ban extends it.'
    super(text)
    this.name = 'TelegramFloodError'
    this.description = text
    this.parameters = { retry_after: remainingSec }
    this.group = group
    this.bannedUntilMs = bannedUntilMs
  }
}

/** "11h 0m", "4m 20s", "15s" - человекочитаемая длительность. */
export function formatDuration(totalSeconds: number): string {
  const s = Math.max(0, Math.round(totalSeconds))
  const h = Math.floor(s / SECONDS_PER_HOUR)
  const m = Math.floor((s % SECONDS_PER_HOUR) / SECONDS_PER_MINUTE)
  const sec = s % SECONDS_PER_MINUTE
  if (h > 0) return `${h}h ${m}m`
  if (m > 0) return `${m}m ${sec}s`
  return `${sec}s`
}

/** Достаёт retry_after из 429 в форме grammY; null если это не 429. */
export function parseFlood429(err: unknown): { retryAfterSec: number } | null {
  if (typeof err !== 'object' || err === null) return null
  const e = err as { error_code?: unknown; parameters?: { retry_after?: unknown } }
  if (e.error_code !== 429) return null
  const after = e.parameters?.retry_after
  if (typeof after !== 'number' || !Number.isFinite(after) || after < 1) {
    return { retryAfterSec: 1 }
  }
  return { retryAfterSec: Math.min(MAX_BAN_SECONDS, Math.ceil(after)) }
}

export interface FloodGateOptions {
  /** Куда сохранять бан между рестартами; без пути - только в памяти. */
  persistPath?: string
  log?: Logger
  /** Шов для тестов: виртуальные часы. */
  now?: () => number
}

type BanTable = Record<FloodGroup, number>

export class FloodGate {
  private readonly now: () => number
  private readonly persistPath: string | undefined
  private readonly log: Logger | undefined
  private until: BanTable = { message: 0, reaction: 0 }

  constructor(opts: FloodGateOptions = {}) {
    this.now = opts.now ?? ((): number => Date.now())
    this.persistPath = opts.persistPath
    this.log = opts.log
    this.load()
  }

  /** Сколько мс осталось до снятия бана группы; 0 - бана нет. */
  remainingMs(group: FloodGroup): number {
    return Math.max(0, this.until[group] - this.now())
  }

  isBanned(group: FloodGroup): boolean {
    return this.remainingMs(group) > 0
  }

  /**
   * Фиксирует бан по ответу 429. Берётся максимум с уже известным, чтобы
   * более короткий retry_after не сократил длинный бан. Возвращает момент
   * снятия (epoch ms).
   */
  recordBan(group: FloodGroup, retryAfterSec: number): number {
    const candidate = this.now() + retryAfterSec * MS_PER_SECOND
    if (candidate > this.until[group]) {
      this.until[group] = candidate
      this.log?.warn('telegram flood ban recorded', {
        group,
        retry_after_s: retryAfterSec,
        until: new Date(candidate).toISOString(),
      })
      this.save()
    }
    return this.until[group]
  }

  /** Ошибка для вызова, который нельзя выполнить из-за активного бана. */
  errorFor(group: FloodGroup): TelegramFloodError {
    return new TelegramFloodError(group, this.until[group], this.now())
  }

  private load(): void {
    if (this.persistPath === undefined || !existsSync(this.persistPath)) return
    try {
      const parsed: unknown = JSON.parse(readFileSync(this.persistPath, 'utf8'))
      if (typeof parsed !== 'object' || parsed === null) return
      const rec = parsed as Record<string, unknown>
      for (const group of ['message', 'reaction'] as const) {
        const v = rec[group]
        if (typeof v === 'number' && Number.isFinite(v) && v > this.now()) {
          this.until[group] = v
        }
      }
      if (this.isBanned('message') || this.isBanned('reaction')) {
        this.log?.warn('telegram flood ban restored from disk', {
          message_until: new Date(this.until.message).toISOString(),
        })
      }
    } catch (err) {
      this.log?.warn('flood gate state unreadable, ignored', {
        error: err instanceof Error ? err.message : String(err),
      })
    }
  }

  private save(): void {
    if (this.persistPath === undefined) return
    try {
      mkdirSync(dirname(this.persistPath), { recursive: true })
      writeFileSync(this.persistPath, JSON.stringify(this.until), { mode: STATE_FILE_MODE })
      chmodSync(this.persistPath, STATE_FILE_MODE)
    } catch (err) {
      this.log?.warn('flood gate state not saved', {
        error: err instanceof Error ? err.message : String(err),
      })
    }
  }
}
