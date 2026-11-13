#!/usr/bin/env bun
// fallback-reply-hook.ts — Stop-хук → fallback-ответ плагина.
//
// Страховка от «тишины» агента: если ход закончился, а агент не ответил
// пользователю инструментом reply/edit_message, плагин сам отправит в чат
// последний текст ассистента. Хук ТОНКИЙ: он только берёт transcript_path и
// session_id из stdin Stop-хука и POST'ит их в loopback-роут плагина
// `/hooks/fallback-reply`. Решение (был ли ответ, из Telegram ли ход, дедуп,
// отправка) принимает сервер — см. src/channel/fallback-reply.ts.
//
// Включение явное: переменная TELEGRAM_FALLBACK_REPLY=1 в channel.env агента
// (её видит и сервер плагина, и этот хук через TELEGRAM_CHANNEL_ENV_FILE).
// Без флага хук сразу выходит, ничего не читая и не отправляя.
//
// Жёсткие инварианты (как у read-receipt-hook.ts):
//   * exit code 0 во всех ветках: ненулевой код блокирует модель;
//   * stdout ПУСТОЙ: stdout Stop-хука считается контекстом модели;
//   * stderr — короткие строки без токена и без содержимого транскрипта.
//
// Конфигурация (env; файл channel.env подмешивается ПОД process.env):
//   TELEGRAM_FALLBACK_REPLY        1/true/yes/on — включить
//   TELEGRAM_CHANNEL_ENV_FILE      путь до channel.env (там HOST/PORT/TOKEN)
//   TELEGRAM_WEBHOOK_TOKEN         bearer-токен роута
//   TELEGRAM_FALLBACK_REPLY_URL    полный URL роута (иначе HOST+PORT)
//   TELEGRAM_WEBHOOK_HOST/PORT     хост (по умолчанию 127.0.0.1) и порт
//   FALLBACK_REPLY_RETRY_ATTEMPTS  повторы при status=no_text (по умолч. 4)
//   FALLBACK_REPLY_RETRY_DELAY_MS  пауза между повторами (по умолч. 150 мс)

import { loadChannelEnvFile } from './read-receipt-hook.js'

/** Таймаут одного запроса к роуту: Stop-хук не должен задерживать завершение сессии. */
const FETCH_TIMEOUT_MS = 8000

/** Повторы при no_text: Stop может сработать раньше, чем в транскрипт попала строка с текстом. */
const DEFAULT_RETRY_ATTEMPTS = 4
const MAX_RETRY_ATTEMPTS = 10
const DEFAULT_RETRY_DELAY_MS = 150
const MAX_RETRY_DELAY_MS = 1000

/** Хост по умолчанию — только loopback. */
const DEFAULT_HOST = '127.0.0.1'

const TRUTHY_RE = /^(1|true|yes|on)$/i

type Env = Readonly<Record<string, string | undefined>>

/** Флаг включения функции (тот же формат, что у остальных флагов плагина). */
export function isFallbackEnabled(env: Env): boolean {
  const v = env.TELEGRAM_FALLBACK_REPLY
  return v !== undefined && TRUTHY_RE.test(v)
}

export interface FallbackHookConfig {
  readonly url: string
  readonly token: string
}

/** Адрес роута и токен из уже слитого env. Чистая функция. */
export function resolveFallbackHookConfig(
  env: Env,
): FallbackHookConfig | { readonly kind: 'error'; readonly reason: string } {
  const token = env.TELEGRAM_WEBHOOK_TOKEN
  if (!token) return { kind: 'error', reason: 'missing TELEGRAM_WEBHOOK_TOKEN' }
  if (env.TELEGRAM_FALLBACK_REPLY_URL) return { url: env.TELEGRAM_FALLBACK_REPLY_URL, token }
  const port = env.TELEGRAM_WEBHOOK_PORT
  if (!port) return { kind: 'error', reason: 'missing TELEGRAM_WEBHOOK_PORT' }
  const host = env.TELEGRAM_WEBHOOK_HOST ?? DEFAULT_HOST
  return { url: `http://${host}:${port}/hooks/fallback-reply`, token }
}

/** Ограниченное целое из env с запасным значением. */
function boundedInt(env: Env, name: string, def: number, max: number): number {
  const raw = env[name]
  if (!raw) return def
  const n = Number.parseInt(raw, 10)
  if (!Number.isFinite(n) || n < 0) return def
  return Math.min(n, max)
}

/** Поля, которые Stop-хук получает на stdin. */
export interface StopHookInput {
  readonly transcript_path: string
  readonly session_id?: string
}

/** Разбор stdin Stop-хука; undefined — если путь транскрипта не найден. */
export function parseStopInput(raw: string): StopHookInput | undefined {
  let parsed: unknown
  try {
    parsed = JSON.parse(raw)
  } catch {
    return undefined
  }
  if (parsed === null || typeof parsed !== 'object') return undefined
  const f = parsed as Record<string, unknown>
  if (typeof f.transcript_path !== 'string' || f.transcript_path.length === 0) return undefined
  return typeof f.session_id === 'string' && f.session_id.length > 0
    ? { transcript_path: f.transcript_path, session_id: f.session_id }
    : { transcript_path: f.transcript_path }
}

/**
 * Один запрос к роуту. Возвращает status из ответа или undefined при сетевой
 * ошибке / не-200 / нечитаемом теле (хук ничего не делает, следующий Stop
 * того же хода повторит попытку: дедуп на сервере пишется только после отправки).
 */
export async function postFallback(
  config: FallbackHookConfig,
  input: StopHookInput,
  fetchImpl: typeof fetch = fetch,
): Promise<string | undefined> {
  try {
    const response = await fetchImpl(config.url, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${config.token}`,
      },
      body: JSON.stringify(input),
      signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
    })
    if (!response.ok) return undefined
    const body: unknown = await response.json()
    if (body === null || typeof body !== 'object') return undefined
    const status = (body as Record<string, unknown>).status
    return typeof status === 'string' ? status : undefined
  } catch {
    return undefined
  }
}

const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms))

/**
 * Основной сценарий: флаг → конфиг → запрос; при no_text — ограниченные
 * повторы (строка с текстом могла ещё не дойти до транскрипта).
 * Возвращает последний status (для тестов); любые ошибки глотает.
 */
export async function runFallbackHook(
  raw: string,
  env: Env,
  deps: { fetchImpl?: typeof fetch; sleepImpl?: (ms: number) => Promise<void> } = {},
): Promise<string | undefined> {
  if (!isFallbackEnabled(env)) return undefined
  const input = parseStopInput(raw)
  if (!input) return undefined
  const config = resolveFallbackHookConfig(env)
  if ('kind' in config) {
    warn(config.reason)
    return undefined
  }
  const attempts = Math.max(
    1,
    boundedInt(env, 'FALLBACK_REPLY_RETRY_ATTEMPTS', DEFAULT_RETRY_ATTEMPTS, MAX_RETRY_ATTEMPTS),
  )
  const delayMs = boundedInt(
    env,
    'FALLBACK_REPLY_RETRY_DELAY_MS',
    DEFAULT_RETRY_DELAY_MS,
    MAX_RETRY_DELAY_MS,
  )
  const wait = deps.sleepImpl ?? sleep
  let status: string | undefined
  for (let i = 0; i < attempts; i++) {
    status = await postFallback(config, input, deps.fetchImpl)
    if (status !== 'no_text') break
    if (i < attempts - 1 && delayMs > 0) await wait(delayMs)
  }
  return status
}

interface BunGlobal {
  readonly stdin?: { readonly text?: () => Promise<string> }
}

async function readStdin(): Promise<string> {
  try {
    const bun = (globalThis as { Bun?: BunGlobal }).Bun
    const fn = bun?.stdin?.text
    if (typeof fn === 'function') return await fn.call(bun?.stdin)
  } catch {
    /* запасной путь ниже */
  }
  return await new Promise<string>((resolve) => {
    const chunks: Buffer[] = []
    process.stdin.on('data', (chunk: Buffer) => chunks.push(chunk))
    process.stdin.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')))
    process.stdin.on('error', () => resolve(''))
  })
}

function warn(reason: string): void {
  const safe = reason.length > 80 ? `${reason.slice(0, 77)}...` : reason
  process.stderr.write(`fallback-reply-hook: ${safe}\n`)
}

async function main(): Promise<void> {
  // channel.env подмешиваем ПОД process.env: у сессии с очищенным окружением
  // (multichat, env -i) токен и порт берутся из файла, а реальный env главнее.
  const fileVars = loadChannelEnvFile(process.env)
  const env: Record<string, string | undefined> = { ...fileVars, ...process.env }
  // Флаг проверяем до чтения stdin: выключено — выходим мгновенно.
  if (!isFallbackEnabled(env)) return
  let raw = ''
  try {
    raw = await readStdin()
  } catch {
    warn('stdin read failed')
    return
  }
  if (raw.trim().length === 0) return
  await runFallbackHook(raw, env)
}

const isMainModule = (() => {
  try {
    const arg = process.argv[1] ?? ''
    return arg.endsWith('fallback-reply-hook.ts') || arg.endsWith('fallback-reply-hook.js')
  } catch {
    return false
  }
})()

if (isMainModule) {
  await main().catch((err) => {
    warn(err instanceof Error ? err.message : 'unknown error')
  })
}
