// Папка-очередь входящих для агента на Codex: задачи agent router и доски задач.
//
// У Claude поллер задач печатает задачу в поле ввода tmux, когда сессия простаивает. У
// Codex поля ввода нет: поллер кладёт файл задачи сюда, плагин подбирает его и отдаёт
// драйверу как обычное входящее (драйвер сам решает — новый ход или очередь). Файл пишется
// атомарно (временное имя + rename) и удаляется только после того, как драйвер принял
// сообщение, — сбой между ними даст повторную доставку, а не потерю задачи.

import { mkdirSync, readdirSync, readFileSync, rmSync, statSync } from 'fs'
import { join } from 'path'

import type { ChannelEvent } from '../../channel/notify.js'
import type { Logger } from '../../log.js'

/** Каталог очереди внутри рабочей папки агента. */
export const INBOX_DIR = join('state', 'codex-inbox')
/** Расширение готового файла (временные файлы поллера — с точкой в начале имени). */
export const INBOX_SUFFIX = '.json'
/** Как часто смотреть в папку. Поллер задач опрашивает память раз в 5 с. */
export const INBOX_POLL_MS = 2000

/** Файл задачи от поллера. */
export interface InboxItem {
  text: string
  /** Источник для журнала и meta (agent_router, task_board). */
  source?: string
}

export interface InboxOptions {
  workspace: string
  /** Чат, куда уйдёт ответ на задачу (личка оператора). */
  chatId: string
  deliver: (event: ChannelEvent) => Promise<boolean>
  log: Logger
  pollMs?: number
}

function parseItem(raw: string): InboxItem | undefined {
  try {
    const data = JSON.parse(raw) as unknown
    if (typeof data !== 'object' || data === null) return undefined
    const rec = data as Record<string, unknown>
    if (typeof rec.text !== 'string' || rec.text.trim() === '') return undefined
    return typeof rec.source === 'string' ? { text: rec.text, source: rec.source } : { text: rec.text }
  } catch {
    return undefined
  }
}

/**
 * Один проход по папке: доставить готовые файлы по порядку имён.
 *
 * @returns Сколько файлов доставлено.
 */
export async function drainInbox(opts: InboxOptions): Promise<number> {
  const dir = join(opts.workspace, INBOX_DIR)
  let names: string[]
  try {
    names = readdirSync(dir)
  } catch {
    return 0
  }
  let delivered = 0
  for (const name of names.filter(n => n.endsWith(INBOX_SUFFIX) && !n.startsWith('.')).sort()) {
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
    const ok = await opts.deliver({
      content: item.text,
      meta: { source: item.source ?? 'agent_router', chat_id: opts.chatId, ts: new Date().toISOString() },
    })
    if (!ok) return delivered
    rmSync(path, { force: true })
    delivered += 1
  }
  return delivered
}

/**
 * Запустить наблюдение за папкой. Возвращает функцию остановки.
 */
export function watchInbox(opts: InboxOptions): () => void {
  mkdirSync(join(opts.workspace, INBOX_DIR), { recursive: true, mode: 0o700 })
  let running = false
  const timer = setInterval(() => {
    if (running) return
    running = true
    void drainInbox(opts)
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
      await opts.notify(chatId, '⚠️ Сброс сессии отменён: агент так и не закончил текущую задачу. Пришлите /stop, затем /reset force.')
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
