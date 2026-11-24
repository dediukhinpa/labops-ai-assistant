// Папка-очередь входящих для агента на Codex: задачи agent router и доски задач.
//
// У Claude поллер задач печатает задачу в поле ввода tmux, когда сессия простаивает. У
// Codex поля ввода нет: поллер кладёт файл задачи сюда (атомарно: временное имя с точкой +
// rename), плагин подбирает его и отдаёт драйверу как обычное входящее.
//
// Доставка «хотя бы раз»: файл удаляется не когда драйвер принял задачу в очередь, а когда
// закончился ход, который её взял (DeliveryHandle.ack). Пока ход идёт, имя файла помнится как
// взятое — повторно в живом процессе он не отдаётся. Падение app-server, сбой смены режима,
// SIGTERM — файл остаётся, следующий запуск драйвера подберёт его заново. Чтобы задача,
// которая сама валит агента, не крутилась вечно, число попыток пишется в файл (attempts);
// после MAX_TASK_ATTEMPTS файл уходит в failed/ с записью в журнал.

import { mkdirSync, readdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from 'fs'
import { join } from 'path'

import type { ChannelEvent } from '../../channel/notify.js'
import type { Logger } from '../../log.js'
import type { DeliveryHandle } from './driver.js'

/** Каталог очереди внутри рабочей папки агента. */
export const INBOX_DIR = join('state', 'codex-inbox')
/** Куда уходят задачи, исчерпавшие попытки (внутри INBOX_DIR). */
export const INBOX_FAILED_DIR = 'failed'
/** Расширение готового файла (временные файлы поллера — с точкой в начале имени). */
export const INBOX_SUFFIX = '.json'
/** Как часто смотреть в папку. Поллер задач опрашивает память раз в 5 с. */
export const INBOX_POLL_MS = 2000
/** Сколько раз отдавать задачу драйверу, прежде чем признать её неисполнимой. */
export const MAX_TASK_ATTEMPTS = 3

/** Файл задачи от поллера. */
export interface InboxItem {
  text: string
  /** Источник для журнала и meta (agent_router, task_board). */
  source?: string
  /** Сколько раз задача уже отдавалась драйверу (пишет сам плагин). */
  attempts?: number
}

export interface InboxOptions {
  workspace: string
  /** Чат, куда уйдёт ответ на задачу (личка оператора). */
  chatId: string
  deliver: (event: ChannelEvent, handle: DeliveryHandle) => Promise<boolean>
  log: Logger
  pollMs?: number
  /**
   * Имена файлов, отданных драйверу и ещё не подтверждённых. Живёт между проходами
   * (watchInbox держит одно множество); без него каждый проход — как первый.
   */
  claimed?: Set<string>
}

function parseItem(raw: string): InboxItem | undefined {
  try {
    const data = JSON.parse(raw) as unknown
    if (typeof data !== 'object' || data === null) return undefined
    const rec = data as Record<string, unknown>
    if (typeof rec.text !== 'string' || rec.text.trim() === '') return undefined
    const item: InboxItem = { text: rec.text }
    if (typeof rec.source === 'string') item.source = rec.source
    if (typeof rec.attempts === 'number' && Number.isFinite(rec.attempts)) item.attempts = rec.attempts
    return item
  } catch {
    return undefined
  }
}

/** Переписать файл задачи атомарно (временное имя с точкой драйвер не подбирает). */
function rewriteItem(dir: string, name: string, item: InboxItem): void {
  const tmp = join(dir, `.${name}.attempt`)
  writeFileSync(tmp, JSON.stringify(item), { mode: 0o600 })
  renameSync(tmp, join(dir, name))
}

/**
 * Один проход по папке: отдать драйверу готовые файлы по порядку имён.
 *
 * @returns Сколько файлов отдано в этом проходе.
 */
export async function drainInbox(opts: InboxOptions): Promise<number> {
  const dir = join(opts.workspace, INBOX_DIR)
  const claimed = opts.claimed ?? new Set<string>()
  let names: string[]
  try {
    names = readdirSync(dir)
  } catch {
    return 0
  }
  let delivered = 0
  for (const name of names.filter(n => n.endsWith(INBOX_SUFFIX) && !n.startsWith('.')).sort()) {
    if (claimed.has(name)) continue
    const path = join(dir, name)
    let raw: string
    try {
      raw = readFileSync(path, 'utf8')
    } catch {
      continue
    }
    const item = parseItem(raw)
    if (item === undefined) {
      opts.log.warn('codex inbox: unreadable task file dropped', { file: name })
      rmSync(path, { force: true })
      continue
    }
    const attempts = (item.attempts ?? 0) + 1
    if (attempts > MAX_TASK_ATTEMPTS) {
      const failedDir = join(dir, INBOX_FAILED_DIR)
      mkdirSync(failedDir, { recursive: true, mode: 0o700 })
      renameSync(path, join(failedDir, name))
      opts.log.error('codex inbox: task failed too many times — moved aside', {
        file: name,
        attempts: item.attempts ?? 0,
        dir: failedDir,
      })
      continue
    }
    // Попытка записывается до доставки: падение посреди хода тоже засчитается.
    rewriteItem(dir, name, { ...item, attempts })
    claimed.add(name)
    let settled = false
    const handle: DeliveryHandle = {
      ack: () => {
        if (settled) return
        settled = true
        rmSync(path, { force: true })
        claimed.delete(name)
      },
      release: () => {
        if (settled) return
        settled = true
        claimed.delete(name)
      },
    }
    let ok = false
    try {
      ok = await opts.deliver(
        {
          content: item.text,
          meta: { source: item.source ?? 'agent_router', chat_id: opts.chatId, ts: new Date().toISOString() },
        },
        handle,
      )
    } finally {
      if (!ok) handle.release()
    }
    if (!ok) return delivered
    delivered += 1
  }
  return delivered
}

/**
 * Запустить наблюдение за папкой. Возвращает функцию остановки.
 */
export function watchInbox(opts: InboxOptions): () => void {
  mkdirSync(join(opts.workspace, INBOX_DIR), { recursive: true, mode: 0o700 })
  const claimed = opts.claimed ?? new Set<string>()
  let running = false
  const timer = setInterval(() => {
    if (running) return
    running = true
    void drainInbox({ ...opts, claimed })
      .catch((err: unknown) => {
        opts.log.warn('codex inbox drain failed', { error: err instanceof Error ? err.message : String(err) })
      })
      .finally(() => {
        running = false
      })
  }, opts.pollMs ?? INBOX_POLL_MS)
  timer.unref?.()
  return () => clearInterval(timer)
}

/** Сколько ждать конца хода, прежде чем отменить /reset (как у watchdog для Claude). */
export const RESET_MAX_WAIT_MS = 30 * 60 * 1000

export interface ResetWatchOptions {
  /** Файл заявки (его пишет команда /reset force; внутри — id чата). */
  requestPath: string
  busy: () => boolean
  reset: () => Promise<void>
  notify: (chatId: string, text: string) => Promise<void>
  log: Logger
  pollMs?: number
  now?: () => number
}

/**
 * Обслужить заявку /reset force: у Claude её выполняет watchdog набором /clear в tmux, у
 * Codex — сам плагин новой нитью, когда текущий ход закончится.
 *
 * @returns true — заявка была и обработана (выполнена или отменена по ожиданию).
 */
export async function serveResetRequest(opts: ResetWatchOptions): Promise<boolean> {
  let stat: { mtimeMs: number }
  try {
    stat = statSync(opts.requestPath)
  } catch {
    return false
  }
  const now = (opts.now ?? Date.now)()
  const tooOld = now - stat.mtimeMs >= RESET_MAX_WAIT_MS
  if (opts.busy() && !tooOld) return false
  let chatId = ''
  try {
    chatId = readFileSync(opts.requestPath, 'utf8').trim()
  } finally {
    rmSync(opts.requestPath, { force: true })
  }
  if (opts.busy()) {
    opts.log.warn('codex /reset cancelled: the turn did not finish in time')
    if (chatId !== '') {
      await opts.notify(chatId, '⚠️ Сброс сессии отменён: агент так и не закончил текущую задачу. Пришлите /stop, затем /reset.')
    }
    return true
  }
  try {
    await opts.reset()
    if (chatId !== '') await opts.notify(chatId, '✅ Сессия сброшена: начинаю с чистого контекста.')
  } catch (err) {
    opts.log.error('codex /reset failed', { error: err instanceof Error ? err.message : String(err) })
    if (chatId !== '') await opts.notify(chatId, '⚠️ Сбросить сессию не удалось — пришлите /doctor.')
  }
  return true
}

/** Периодически проверять заявку /reset. Возвращает функцию остановки. */
export function watchResetRequest(opts: ResetWatchOptions): () => void {
  let running = false
  const timer = setInterval(() => {
    if (running) return
    running = true
    void serveResetRequest(opts)
      .catch((err: unknown) => {
        opts.log.warn('codex reset watch failed', { error: err instanceof Error ? err.message : String(err) })
      })
      .finally(() => {
        running = false
      })
  }, opts.pollMs ?? INBOX_POLL_MS)
  timer.unref?.()
  return () => clearInterval(timer)
}
