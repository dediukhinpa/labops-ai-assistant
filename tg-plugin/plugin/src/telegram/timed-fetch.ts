// Таймауты HTTP-вызовов Telegram Bot API поверх глобального fetch.
//
// grammY по умолчанию ждёт ответ до 500 с на любой метод: повисший
// sendChatAction или setMessageReaction блокировал бы плагин минутами.
// Подменяем fetch так, чтобы таймауты действовали только для Bot API, а
// остальные вызовы (webhook-сервер, loopback) шли как есть.
//
// Для облака (api.telegram.org) поведение осталось прежним байт в байт.
// Если задан корень локального Bot API, обёртка применяется и к нему, но с
// другими таймаутами на «тяжёлые» вызовы: локальный сервер в getFile сначала
// сам скачивает файл (до 2 ГБ), а в send* заливает его в Telegram, и только
// потом отвечает. Лимиты облака на такие вызовы (8-20 с) его бы обрывали.

export const TG_TIMEOUTS_MS: Readonly<Record<string, number>> = {
  // Long-poll: Telegram держит соединение LONG_POLL_TIMEOUT_SEC (25 с);
  // +10 с запаса на дрожание сети, потом обрыв на уровне HTTP.
  getUpdates:           35_000,
  // Сигналы «выстрелил и забыл» — пользователь видит их сразу, падаем быстро.
  sendChatAction:        5_000,
  setMessageReaction:    5_000,
  deleteMessage:         5_000,
  answerCallbackQuery:   5_000,
  getMe:                 5_000,
  setMyCommands:         5_000,
  // Обычные сообщения и правки — достаточно коротко, чтобы заметить зависание.
  sendMessage:           8_000,
  editMessageText:       6_000,
  editMessageCaption:    6_000,
  forwardMessage:        8_000,
  copyMessage:           8_000,
  getFile:               8_000,
  // Загрузка медиа — больше времени на крупные тела.
  sendPhoto:            20_000,
  sendDocument:         20_000,
  sendVoice:            20_000,
  sendVideo:            20_000,
}
export const TG_DEFAULT_TIMEOUT_MS = 10_000

/** Таймаут «тяжёлых» вызовов локального сервера: файл до 2 ГБ идёт минутами. */
export const LOCAL_HEAVY_TIMEOUT_MS = 30 * 60 * 1000

/** Методы, на которых локальный сервер работает с самим файлом. */
const LOCAL_HEAVY_METHODS: ReadonlySet<string> = new Set([
  'getFile',
  'sendPhoto',
  'sendDocument',
  'sendVoice',
  'sendVideo',
  'sendAudio',
  'sendAnimation',
  'sendVideoNote',
])

const CLOUD_HOST_MARKER = 'api.telegram.org'

export function tgMethodFromUrl(url: string | URL | Request): string {
  const href =
    typeof url === 'string' ? url
    : url instanceof URL    ? url.href
    : (url as Request).url
  const m = /\/bot[^/]+\/([A-Za-z]+)/.exec(href)
  return m?.[1] ?? ''
}

/**
 * Таймаут для URL либо undefined, если вызов не относится к Bot API и
 * обёртка его не трогает.
 *
 * @param href    полный URL запроса
 * @param apiRoot нормализованный корень локального сервера (без «/» на конце)
 */
export function resolveTelegramTimeoutMs(href: string, apiRoot?: string): number | undefined {
  // Облако: прежнее условие и прежняя таблица, без изменений.
  if (href.includes(CLOUD_HOST_MARKER)) {
    return TG_TIMEOUTS_MS[tgMethodFromUrl(href)] ?? TG_DEFAULT_TIMEOUT_MS
  }
  if (apiRoot === undefined || !href.startsWith(`${apiRoot}/`)) return undefined

  // Скачивание файла с локального сервера: размер до 2 ГБ, короткий таймаут не годится.
  if (href.startsWith(`${apiRoot}/file/bot`)) return LOCAL_HEAVY_TIMEOUT_MS
  const method = tgMethodFromUrl(href)
  if (LOCAL_HEAVY_METHODS.has(method)) return LOCAL_HEAVY_TIMEOUT_MS
  return TG_TIMEOUTS_MS[method] ?? TG_DEFAULT_TIMEOUT_MS
}

export interface TimedFetchOptions {
  /** Корень локального Bot API; без него обёртка работает только с облаком. */
  apiRoot?: string
}

/**
 * Строит подменяющую fetch-функцию.
 *
 * @param nativeFetch исходный fetch (уже привязанный к globalThis)
 * @param preconnect  расширение Bun: bind() свойства функции не переносит,
 *                    поэтому подмена обязана пробросить его сама.
 */
export function createTimedTelegramFetch(
  nativeFetch: typeof fetch,
  preconnect: typeof fetch.preconnect,
  options: TimedFetchOptions = {},
): typeof fetch {
  function timedTelegramFetch(
    input: RequestInfo | URL,
    init?: RequestInit,
  ): Promise<Response> {
    const href =
      typeof input === 'string' ? input
      : input instanceof URL    ? input.href
      : (input as Request).url

    // Перехватываем только вызовы Telegram Bot API.
    const timeoutMs = resolveTelegramTimeoutMs(href, options.apiRoot)
    if (timeoutMs === undefined) return nativeFetch(input, init)

    const method     = tgMethodFromUrl(href)
    const controller = new AbortController()
    const timer      = setTimeout(
      () => controller.abort(new DOMException(`TG API timeout: ${method} (${timeoutMs} ms)`, 'TimeoutError')),
      timeoutMs,
    )

    // Склеиваем с собственным сигналом grammY (его запасные 500 с или сигнал вызывающего).
    const existing = (init as RequestInit & { signal?: AbortSignal })?.signal
    if (existing?.aborted) {
      clearTimeout(timer)
      controller.abort(existing.reason)
    } else {
      existing?.addEventListener('abort', () => controller.abort(existing.reason), { once: true })
    }

    return nativeFetch(input, { ...init, signal: controller.signal }).finally(() => clearTimeout(timer))
  }
  timedTelegramFetch.preconnect = preconnect
  return timedTelegramFetch
}
