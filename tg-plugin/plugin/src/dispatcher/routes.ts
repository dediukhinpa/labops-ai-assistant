// Таблица маршрутов общего бота: telegram_id → идентификатор агента.
//
// Единственный источник правды о том, чей агент получит сообщение. Живёт
// отдельным JSON-файлом, а не в базе веб-приложения: рой не должен зависеть
// от схемы приложения, а оператор должен видеть маршруты глазами.
//
// Файл перечитывается по mtime, поэтому нового пользователя видно без
// рестарта диспетчера — иначе каждое заведение требовало бы простоя бота.

import { readFileSync, statSync } from 'fs'
import { z } from 'zod'

/** Идентификатор агента = один сегмент пути внутри каталога состояния. */
const AGENT_ID_RE = /^[A-Za-z0-9][A-Za-z0-9._-]*$/

const RoutesFileSchema = z.object({
  routes: z.record(
    z.string().regex(/^[0-9]+$/, 'telegram id must be digits'),
    z.string().regex(AGENT_ID_RE, 'agent id must be a plain path segment'),
  ),
})

export interface RouteTableLogger {
  warn: (msg: string, fields?: Record<string, unknown>) => void
}

/**
 * Отображение отправителя Telegram на агента, с горячей перезагрузкой файла.
 */
export class RouteTable {
  private readonly path: string
  private readonly log: RouteTableLogger | undefined
  private routes: ReadonlyMap<string, string> = new Map()
  private loadedMtimeMs: number | undefined
  private loadedSize: number | undefined

  /**
   * @param path - Путь к routes.json.
   * @param log - Куда жаловаться на битый файл (необязателен в тестах).
   */
  constructor(path: string, log?: RouteTableLogger) {
    this.path = path
    this.log = log
    this.reloadIfChanged()
  }

  /**
   * Найти агента отправителя.
   *
   * @param telegramId - `from.id` входящего апдейта.
   * @returns Идентификатор агента или undefined, если маршрута нет.
   */
  lookup(telegramId: number | string): string | undefined {
    this.reloadIfChanged()
    return this.routes.get(String(telegramId))
  }

  /** Сколько маршрутов сейчас загружено (для логов старта). */
  get size(): number {
    this.reloadIfChanged()
    return this.routes.size
  }

  private reloadIfChanged(): void {
    let mtimeMs: number
    let size: number
    try {
      const st = statSync(this.path)
      mtimeMs = st.mtimeMs
      size = st.size
    } catch {
      // Файла нет — маршрутов нет. Это штатное состояние до первого
      // заведённого пользователя, поэтому не шумим в лог.
      this.routes = new Map()
      this.loadedMtimeMs = undefined
      this.loadedSize = undefined
      return
    }
    // Размер в ключе кэша потому, что запись в пределах одной миллисекунды
    // не меняет mtime на всех ФС, а правка маршрута легко в неё укладывается.
    if (mtimeMs === this.loadedMtimeMs && size === this.loadedSize) return

    try {
      const parsed: unknown = JSON.parse(readFileSync(this.path, 'utf8'))
      const file = RoutesFileSchema.parse(parsed)
      this.routes = new Map(Object.entries(file.routes))
      this.loadedMtimeMs = mtimeMs
      this.loadedSize = size
    } catch (err) {
      // Битый файл НЕ обнуляет таблицу: иначе опечатка оператора молча
      // отключила бы всех пользователей разом. Работаем на последней
      // валидной версии и повторим попытку при следующем изменении файла.
      this.log?.warn('routes.json invalid, keeping previous table', {
        path: this.path,
        error: err instanceof Error ? err.message : String(err),
        routes_in_use: this.routes.size,
      })
      this.loadedMtimeMs = mtimeMs
      this.loadedSize = size
    }
  }
}
