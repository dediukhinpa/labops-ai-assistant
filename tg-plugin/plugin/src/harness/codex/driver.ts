// Драйвер агента на Codex: одна долгоживущая нить `codex app-server` вместо сессии Claude
// Code в tmux.
//
// Входы (Telegram, задачи agent router, webhook) приходят в deliver() и идут в одну очередь.
// Свободна нить — сообщение начинает ход (turn/start). Ход уже идёт и сообщение из того же
// чата — оно доставляется вдогонку (turn/steer), как дописка человека в активный разговор.
// Из другого чата — ждёт конца хода: финальный ответ хода уходит в чат, который его начал.
//
// Выходы: события хода → статус и прогресс в Telegram (через формат хуков Claude, см.
// events.ts); финальное сообщение хода → оператору, если агент не отправил тот же текст
// инструментом reply. Хуки памяти (session-start, stop, precompact, heartbeat, session-end)
// вызывает сам драйвер — у Claude их вызывает харнес.
//
// Подтверждения не ожидаются (approval_policy = never), но если придут — отклоняются и
// пишутся в журнал. Вопрос пользователю (request_user_input) уходит обычным текстом в чат
// хода — без кнопок; ответ оператора (следующее сообщение в том же чате) драйвер возвращает
// как результат синхронного вызова. Асинхронный вопрос (request_user_input_async) ход не
// останавливает: драйвер шлёт его тем же обычным текстом, а ответ человека приходит обычным
// сообщением и начинает (или продолжает) ход — отдельной корреляции ответа не требуется.
//
// Живучесть: heartbeat в простое — по таймеру, во время хода — только по уведомлениям нити,
// поэтому зависший ход виден watchdog. Сверх того сторож хода внутри драйвера: нить молчит
// дольше предела — turn/interrupt, не помогло — выход с ошибкой (watchdog перезапустит).
//
// Надёжность входа: сообщения, ждущие в очереди, сквозь пишутся в файл очереди и
// восстанавливаются на старте; задачи из папки-очереди подтверждаются (файл удаляется) только
// после конца хода, который их взял (DeliveryHandle).

import { appendFileSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from 'fs'
import { dirname, join } from 'path'

import type { Logger } from '../../log.js'
import type { ChannelEvent } from '../../channel/notify.js'
import { formatChannelInbound } from '../../channel/notify.js'
import { AppServerConnection, RPC_METHOD_NOT_FOUND, RpcError, type LineTransport } from './rpc.js'
import {
  isAsyncAgentMessage,
  lastAgentMessage,
  normalizeForDedup,
  planHook,
  promptHook,
  replyTextOf,
  stopHook,
  toolHook,
  type CodexItem,
  type HookContext,
  type PlanStep,
} from './events.js'

/** Минимальный интервал между вызовами heartbeat-хука. */
export const HEARTBEAT_MIN_INTERVAL_MS = 15_000
/** Heartbeat в простое: watchdog по нему отличает живой драйвер от зависшего. */
export const IDLE_HEARTBEAT_INTERVAL_MS = 60_000
/** Как часто сторож хода проверяет, не замолчала ли нить. */
export const TURN_WATCH_INTERVAL_MS = 15_000
/**
 * Сколько ход может идти без единого уведомления нити, прежде чем драйвер его прервёт.
 * Должно быть заметно меньше порога watchdog (WATCHDOG_CODEX_HEARTBEAT_STALE_SEC, 300 с):
 * во время хода heartbeat пишется только по уведомлениям, и при пороге выше watchdog
 * перезапустил бы агента раньше, без предупреждения в чат. Действует, только пока у хода
 * нет незавершённых элементов (иначе — ITEM_STALL_DEFAULT_MS); переопределяется TURN_STALL_ENV.
 */
export const TURN_STALL_DEFAULT_MS = 180_000
/** Переменная окружения: предел молчания хода в секундах. */
export const TURN_STALL_ENV = 'LABOPS_CODEX_TURN_STALL_SEC'
/**
 * Предел молчания, пока у хода есть незавершённый элемент (item/started без item/completed:
 * команда, MCP-вызов, рассуждение, правка файлов и т. п.). Ход не завис, а ждёт инструмент или
 * модель: тихая сборка, тесты, sleep, долгое рассуждение без summaries законно молчат минутами.
 * Короткий TURN_STALL_DEFAULT_MS действует только когда незавершённых элементов нет — сервер
 * замолчал между элементами.
 */
export const ITEM_STALL_DEFAULT_MS = 1_800_000
/** Переменная окружения: предел молчания при незавершённом элементе, в секундах. */
export const ITEM_STALL_ENV = 'LABOPS_CODEX_ITEM_STALL_SEC'
/** Сколько ждать конца хода после turn/interrupt сторожа, прежде чем выйти с ошибкой. */
export const STALL_INTERRUPT_GRACE_MS = 30_000
/** Сколько подряд неудачных thread/resume (не «нити нет») терпеть, прежде чем начать новую. */
export const MAX_RESUME_FAILURES = 3
/** Реакция «агент прочитал сообщение» — как у Claude (ставится, когда ход взял сообщение). */
export const READ_REACTION = '👀'
/** Реакция «готово» на конец хода — как Stop-хук у Claude (заменяет 👀 на сообщениях хода). */
export const DONE_REACTION = '👌'
/** Сколько ждать старта нити (resume/start грузят историю и MCP-серверы). */
export const THREAD_START_TIMEOUT_MS = 120_000
/** Как часто драйвер сверяет файл режима pii-proxy. */
export const PII_MODE_POLL_INTERVAL_MS = 5_000
/** Сколько ждать конца хода после turn/interrupt при переходе напрямую. */
export const PII_INTERRUPT_TIMEOUT_MS = 10_000
/** Шаг ожидания конца прерванного хода, мс. */
const INTERRUPT_POLL_MS = 50
/** Сколько id асинхронных сообщений агента помнить, чтобы не отправить одно дважды. */
export const ASYNC_SEEN_LIMIT = 200
/** Версия клиента в initialize. */
const CLIENT_INFO = { name: 'labops-codex-driver', version: '1.0.0' }

/**
 * Режим относительно pii-proxy: через прокси (норма) или напрямую (прокси не отвечает, решение
 * владельца 23.11.2026). Выбирает watchdog, драйвер только применяет.
 */
export type PiiMode = 'proxy' | 'direct'

/** Хук памяти рабочей папки агента. */
export type MemoryHook = 'session-start' | 'stop' | 'precompact' | 'heartbeat' | 'session-end'

/**
 * Подтверждение доставки для входа, у которого есть своя постоянная копия (файл задачи):
 * ack — ход, взявший вход, закончился, копию можно удалить; release — вход не дошёл до модели,
 * копию можно отдать повторно.
 */
export interface DeliveryHandle {
  ack(): void
  release(): void
}

/** Вопрос request_user_input от Codex. */
export interface UserInputQuestion {
  id: string
  header: string
  question: string
  isOther: boolean
  isSecret: boolean
  options: Array<{ label: string; description: string }> | null
}

/** Вопрос request_user_input_async (AsyncUserInputQuestion протокола app-server 0.171.0). */
export interface AsyncUserInputQuestion {
  title: string
  options: string[] | null
}

/**
 * Вопросы асинхронного сообщения агента (поле questions элемента agentMessage). Пустые
 * заголовки и варианты отбрасываются.
 *
 * @param item Элемент agentMessage с delivery = "async".
 * @returns Вопросы; пусто — это не вопрос, а просто сообщение (send_message_to_user_async).
 */
export function asyncQuestionsOf(item: Record<string, unknown>): AsyncUserInputQuestion[] {
  if (!Array.isArray(item.questions)) return []
  const out: AsyncUserInputQuestion[] = []
  for (const raw of item.questions as unknown[]) {
    const q = record(raw)
    if (typeof q.title !== 'string' || q.title.trim() === '') continue
    const options = Array.isArray(q.options)
      ? (q.options as unknown[]).filter((o): o is string => typeof o === 'string' && o.trim() !== '')
      : null
    out.push({ title: q.title, options: options !== null && options.length > 0 ? options : null })
  }
  return out
}

/**
 * Вопрос(ы) одним обычным сообщением — без кнопок: ведущий текст, затем для каждого вопроса
 * заголовок и варианты списком. Оператор отвечает обычным сообщением. Используется и для
 * синхронного request_user_input, и для асинхронного request_user_input_async.
 *
 * @param lead Ведущий текст (у async — текст самого сообщения агента; у sync — пусто).
 * @param questions Вопросы: заголовок и необязательные варианты.
 * @returns Текст сообщения; пустые заголовки/дубли ведущего текста не повторяются.
 */
export function questionsToText(
  lead: string,
  questions: ReadonlyArray<{ title: string; options: readonly string[] | null }>,
): string {
  const parts: string[] = []
  const head = lead.trim()
  if (head !== '') parts.push(head)
  for (const q of questions) {
    const title = q.title.trim()
    if (title !== '' && title !== head && !parts.includes(title)) parts.push(title)
    if (q.options !== null && q.options.length > 0) parts.push(q.options.map(o => `• ${o}`).join('\n'))
  }
  return parts.join('\n')
}

/** Ответ на request_user_input: id вопроса → выбранные варианты/текст. */
export interface UserInputAnswers {
  answers: Record<string, { answers: string[] }>
}

/** Внешние действия драйвера: всё, что касается Telegram, файлов памяти и скриптов. */
export interface DriverEffects {
  /** Событие статуса в формате хука Claude (StatusManager / ProgressReporter / TaskMirror). */
  status(payload: Record<string, unknown>): Promise<void>
  /** Отправить финальный ответ хода оператору. */
  deliverFinal(chatId: string, text: string): Promise<void>
  /** Запустить хук памяти; вернуть его stdout (session-start даёт контекст для первого хода). */
  memory(hook: MemoryHook, payload: Record<string, unknown>): Promise<string>
  /** Пересобрать AGENTS.md из AGENTS.src.md и файлов памяти. */
  rebuildIdentity(): Promise<void>
  /** Отметить сообщение Telegram прочитанным (реакция). */
  markRead(chatId: string, messageId: number): Promise<void>
  /** Отметить сообщение Telegram обработанным: ход, взявший его, закончился (реакция). */
  markDone(chatId: string, messageId: number): Promise<void>
  /** Предупредить оператора (личка) о событии, требующем внимания. */
  notifyOperator(text: string): Promise<void>
}

export interface CodexDriverDeps {
  /** Запуск процесса app-server в заданном режиме pii-proxy. */
  connect: (mode: PiiMode) => LineTransport
  /** Рабочая папка агента (cwd нити). */
  workspace: string
  /** Где хранить id нити между перезапусками. */
  stateFile: string
  effects: DriverEffects
  log: Logger
  now?: () => number
  /** Нужный сейчас режим pii-proxy (файл режима агента); не задан — всегда через прокси. */
  piiMode?: () => PiiMode
  /** Интервал сверки режима, мс (тесты ставят меньше). */
  piiModePollMs?: number
  /**
   * Отпечаток файлов инструкций (AGENTS.md рабочей папки и CODEX_HOME). Codex читает их только
   * при создании нити; изменился отпечаток — нужна новая нить. Не задан — не сравнивается.
   */
  identityHash?: () => string
  /** Файл очереди входящих; по умолчанию codex-queue.json рядом с stateFile. */
  queueFile?: string
  /** Предел молчания хода без незавершённых элементов, мс (по умолчанию TURN_STALL_DEFAULT_MS). */
  turnStallMs?: number
  /** Предел молчания при незавершённом элементе, мс (по умолчанию ITEM_STALL_DEFAULT_MS). */
  itemStallMs?: number
  /** Шаг сторожа хода и heartbeat в простое, мс (тесты ставят меньше). */
  turnWatchMs?: number
  /** Сколько ждать конца хода после прерывания сторожем, мс. */
  stallGraceMs?: number
}

interface QueuedInput {
  text: string
  chatId: string
  /** message_id сообщения Telegram (для реакции «прочитано»); у задач и webhook его нет. */
  messageId: number | undefined
  /** Подтверждение для входа с постоянной копией (задача из папки-очереди). */
  handle?: DeliveryHandle
}

interface ActiveTurn {
  /** Id хода; пусто, пока turn/start не ответил и turn/started не пришло. */
  id: string
  chatId: string
  replies: Set<string>
  /** Входы хода (первые и вдогонку): на конце хода подтверждаются, при повторе — в очередь. */
  inputs: QueuedInput[]
  lastAgentText: string
  /** message_id сообщений Telegram, взятых ходом: на конце хода им ставится 👌. */
  messageIds: number[]
}

/** Сохранённое состояние нити между перезапусками драйвера. */
interface ThreadState {
  threadId: string
  /** Отпечаток инструкций, с которыми нить создана (или впервые замечена). */
  identityHash?: string
  /** Неудачные thread/resume подряд (не «нити нет»). */
  resumeFailures?: number
}

/** Вход очереди в файле (без подтверждения: у задач есть свои файлы). */
interface PersistedInput {
  text: string
  chatId: string
  messageId?: number
}

/**
 * Ошибка thread/resume говорит, что такой нити нет (а не «app-server не успел» и т. п.).
 * Точный код ошибки в протоколе app-server не описан; сверяемся с текстом («no rollout found
 * for thread id …» / «… not found»). НЕ проверено на живом codex 0.171.0.
 */
export function isThreadMissingError(err: unknown): boolean {
  return err instanceof RpcError && /no rollout|not found/i.test(err.message)
}

function record(value: unknown): Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {}
}

function textInput(text: string): Record<string, unknown> {
  return { type: 'text', text, text_elements: [] }
}

/**
 * Драйвер одной нити Codex.
 */
export class CodexDriver {
  private conn: AppServerConnection | undefined
  private threadId = ''
  private transcriptPath = ''
  private ready = false
  private stopping = false
  private active: ActiveTurn | undefined
  private readonly queue: QueuedInput[] = []
  /**
   * message_id сообщений прерванного хода, чей вход повторяется (по чатам): 👀 на них уже
   * стоит, а 👌 поставит ход-повтор, когда закончится.
   */
  private readonly replayMessageIds = new Map<string, number[]>()
  /** Контекст session-start для первого хода новой нити. */
  private sessionContext = ''
  private lastHeartbeat = 0
  /** Последнее уведомление нити (или начало хода): по нему сторож хода видит зависание. */
  private lastTurnActivity = 0
  /** Идёт обработка зависшего хода (прерывание, выход). */
  private stallHandling = false
  /** Незавершённые элементы текущего хода: id → тип (item/started без item/completed). */
  private readonly openItems = new Map<string, string>()
  /** Id уже доставленных асинхронных сообщений агента (элемент мог прийти повторно). */
  private readonly asyncSeen = new Set<string>()
  /** Сколько вопросов пользователю ждут ответа: ход законно молчит, пока человек думает. */
  private waitingOnUser = 0
  /** Ждём ответ оператора на синхронный request_user_input: следующее сообщение этого чата — ответ. */
  private pendingAsk: { chatId: string; resolve: (text: string | null) => void } | undefined
  /** Отпечаток инструкций текущей нити. */
  private identityHash: string | undefined
  private heartbeatTimer: ReturnType<typeof setInterval> | undefined
  private modeTimer: ReturnType<typeof setInterval> | undefined
  /** Режим, в котором запущен текущий app-server. */
  private appliedMode: PiiMode = 'proxy'
  /** Идёт смена режима: старый app-server закрыт, новый поднимается. */
  private switching = false
  /** Ход, прерванный ради перехода напрямую: его вход повторится в новом app-server. */
  private interrupting: ActiveTurn | undefined
  private readonly exitListeners: Array<(code: number | null) => void> = []
  private readonly now: () => number

  private readonly queueFile: string

  constructor(private readonly deps: CodexDriverDeps) {
    this.now = deps.now ?? Date.now
    this.queueFile = deps.queueFile ?? join(dirname(deps.stateFile), 'codex-queue.json')
    // Очередь прошлого процесса — до любого deliver(): иначе первая же запись её затрёт.
    this.restoreQueue()
  }

  /** Id текущей нити (для журнала и тестов). */
  get thread(): string {
    return this.threadId
  }

  /** Идёт ли ход. */
  get busy(): boolean {
    return this.active !== undefined
  }

  /** Подписка на смерть app-server: процесс драйвера должен завершиться и подняться заново. */
  onExit(cb: (code: number | null) => void): void {
    this.exitListeners.push(cb)
  }

  /** Режим pii-proxy, в котором работает app-server сейчас. */
  get piiMode(): PiiMode {
    return this.appliedMode
  }

  /**
   * Запустить app-server, восстановить нить агента или начать новую.
   */
  async start(): Promise<void> {
    const conn = await this.openConnection()

    // Идентичность собирается до старта нити: Codex читает AGENTS.md при её создании.
    await this.deps.effects.rebuildIdentity()
    const hash = this.deps.identityHash?.()

    const saved = this.readState()
    let resumed = false
    if (saved.threadId !== '') {
      try {
        const res = record(
          await conn.request('thread/resume', { threadId: saved.threadId, excludeTurns: true }, THREAD_START_TIMEOUT_MS),
        )
        this.adoptThread(record(res.thread))
        resumed = true
      } catch (err) {
        await this.onResumeFailure(saved, err)
      }
    }
    // Смена нити по отпечатку — только после удачного resume: ошибка resume решается выше
    // (выход или счётчик), а не маскируется «всё равно нужна новая нить». Нить старой версии
    // сперва сбрасывается в общую память, как при /reset force.
    const identityChanged =
      resumed && hash !== undefined && saved.identityHash !== undefined && saved.identityHash !== hash
    if (identityChanged) {
      this.deps.log.info('codex instructions changed — starting a new thread', { old_thread_id: this.threadId })
      await this.safeMemory('session-end', { hook_event_name: 'SessionEnd', reason: 'clear' })
      await this.startNewThread('startup')
    } else if (!resumed) {
      await this.startNewThread('startup')
    }
    // Старая нить без отпечатка (до этой версии) не сбрасывается: отпечаток только
    // запоминается, чтобы обновление драйвера не обнулило контекст всем агентам сразу.
    this.identityHash = hash ?? saved.identityHash
    this.saveThread()
    this.ready = true
    this.deps.log.info('codex thread ready', { thread_id: this.threadId, resumed: resumed && !identityChanged })
    void this.heartbeat(true)
    this.heartbeatTimer = setInterval(() => void this.watchTick(), this.deps.turnWatchMs ?? TURN_WATCH_INTERVAL_MS)
    this.heartbeatTimer.unref?.()
    if (this.deps.piiMode !== undefined) {
      this.modeTimer = setInterval(
        () => void this.maybeSwitchMode(),
        this.deps.piiModePollMs ?? PII_MODE_POLL_INTERVAL_MS,
      )
      this.modeTimer.unref?.()
    }
    void this.pump()
  }

  /**
   * thread/resume не удался. Нити нет — новая нить (сохранять нечего). Иная ошибка (таймаут
   * медленного старта MCP, сбой app-server) — сохранённый id не трогаем и выходим с ошибкой:
   * watchdog перезапустит, и нить, скорее всего, восстановится. Чтобы не крутиться вечно,
   * после MAX_RESUME_FAILURES подряд старый id уходит в бэкап, нить новая, оператор
   * предупреждён.
   *
   * @throws Ошибка resume, если ещё не исчерпан счётчик попыток.
   */
  private async onResumeFailure(saved: ThreadState, err: unknown): Promise<void> {
    const error = err instanceof Error ? err.message : String(err)
    if (isThreadMissingError(err)) {
      this.deps.log.warn('codex thread not found on resume — starting a new thread', {
        thread_id: saved.threadId,
        error,
      })
      this.backupThreadId(saved.threadId, 'not-found')
      return
    }
    const failures = (saved.resumeFailures ?? 0) + 1
    if (failures < MAX_RESUME_FAILURES) {
      this.writeState({ ...saved, resumeFailures: failures })
      this.deps.log.error('codex thread resume failed — driver exits, saved thread kept', {
        thread_id: saved.threadId,
        failures,
        error,
      })
      throw err instanceof Error ? err : new Error(error)
    }
    this.backupThreadId(saved.threadId, 'resume-failed')
    this.deps.log.error('codex thread resume keeps failing — starting a new thread', {
      thread_id: saved.threadId,
      failures,
      error,
    })
    try {
      await this.deps.effects.notifyOperator(
        `⚠️ Агент ${failures} раз подряд не смог продолжить свою нить Codex (${error.slice(0, 200)}). ` +
          'Начинаю новую — контекст разговора потерян, id старой нити сохранён в codex-thread.backup.jsonl.',
      )
    } catch (notifyErr) {
      this.deps.log.warn('codex operator notice failed', {
        error: notifyErr instanceof Error ? notifyErr.message : String(notifyErr),
      })
    }
  }

  /** Записать id нити, которую драйвер бросает, в журнал рядом с файлом состояния. */
  private backupThreadId(threadId: string, reason: string): void {
    try {
      mkdirSync(dirname(this.deps.stateFile), { recursive: true })
      const line = JSON.stringify({ threadId, reason, at: new Date(this.now()).toISOString() })
      appendFileSync(this.backupFile(), `${line}\n`, { mode: 0o600 })
    } catch (err) {
      this.deps.log.warn('codex thread backup failed', { error: err instanceof Error ? err.message : String(err) })
    }
  }

  private backupFile(): string {
    return join(dirname(this.deps.stateFile), 'codex-thread.backup.jsonl')
  }

  /**
   * Шаг таймера: heartbeat в простое и сторож хода. Во время хода heartbeat пишут только
   * уведомления нити (onNotification) — иначе watchdog не увидит зависший ход. Исключения —
   * ожидание ответа человека на вопрос и незавершённый элемент хода (ждём инструмент или
   * модель): тогда heartbeat тикает, а предел молчания длинный (itemStallMs).
   */
  private async watchTick(): Promise<void> {
    if (!this.ready || this.stopping || this.switching) return
    const t = this.now()
    const turn = this.active
    if (turn === undefined) {
      if (t - this.lastHeartbeat >= IDLE_HEARTBEAT_INTERVAL_MS) await this.heartbeat(true)
      return
    }
    if (this.waitingOnUser > 0) {
      this.lastTurnActivity = t
      await this.heartbeat(false)
      return
    }
    if (this.stallHandling || this.interrupting !== undefined) return
    const waitingOnItem = this.openItems.size > 0
    const limit = waitingOnItem
      ? (this.deps.itemStallMs ?? ITEM_STALL_DEFAULT_MS)
      : (this.deps.turnStallMs ?? TURN_STALL_DEFAULT_MS)
    const silent = t - this.lastTurnActivity
    if (silent < limit) {
      if (waitingOnItem) await this.heartbeat(false)
      return
    }
    this.deps.log.error('codex turn silent past the limit', {
      open_items: [...this.openItems.values()],
      limit_ms: limit,
    })
    await this.onTurnStall(turn, silent)
  }

  /**
   * Ход молчит дольше предела: предупредить чат хода, turn/interrupt. Ход закончился — он
   * закрывается как обычно (его задачи подтверждаются: пользователь предупреждён, повтор
   * зависшей задачи по кругу хуже). Не закончился — выход драйвера с ошибкой (server.ts делает
   * штатную остановку с brain-flush, watchdog поднимает заново); задачи такого хода не
   * подтверждены и придут повторно (папка-очередь ограничивает число попыток).
   */
  private async onTurnStall(turn: ActiveTurn, silentMs: number): Promise<void> {
    this.stallHandling = true
    const minutes = Math.max(1, Math.round(silentMs / 60_000))
    this.deps.log.error('codex turn stalled — interrupting', { turn_id: turn.id, chat_id: turn.chatId, silent_ms: silentMs })
    try {
      await this.safeDeliver(
        turn.chatId,
        `⚠️ Агент ${minutes} мин не подаёт признаков жизни — прерываю зависший ход. Если ответ ещё нужен, повторите запрос.`,
      )
      if (turn.id !== '' && this.conn !== undefined) {
        try {
          await this.conn.request('turn/interrupt', { threadId: this.threadId, turnId: turn.id }, PII_INTERRUPT_TIMEOUT_MS)
        } catch (err) {
          this.deps.log.warn('codex stalled turn/interrupt failed', {
            error: err instanceof Error ? err.message : String(err),
          })
        }
      }
      const grace = this.deps.stallGraceMs ?? STALL_INTERRUPT_GRACE_MS
      for (let waited = 0; this.active === turn && waited < grace; waited += INTERRUPT_POLL_MS) {
        await new Promise(resolve => setTimeout(resolve, INTERRUPT_POLL_MS))
      }
      if (this.active !== turn) {
        this.deps.log.info('codex stalled turn interrupted', { turn_id: turn.id })
        return
      }
      this.deps.log.error('codex stalled turn did not stop — driver exits for a clean restart', { turn_id: turn.id })
      await this.safeDeliver(turn.chatId, '⚠️ Прервать ход не удалось — перезапускаю агента.')
      // Драйвер больше не работает: новых ходов и повторного срабатывания сторожа не будет,
      // пока server.ts завершает процесс.
      this.ready = false
      if (this.heartbeatTimer !== undefined) clearInterval(this.heartbeatTimer)
      this.exit(null)
    } finally {
      this.stallHandling = false
    }
  }

  /** Сообщить подписчикам, что драйвер должен завершиться (server.ts: shutdown(1)). */
  private exit(code: number | null): void {
    for (const cb of this.exitListeners) cb(code)
  }

  /** Запустить app-server в нужном сейчас режиме pii-proxy и пройти initialize. */
  private async openConnection(): Promise<AppServerConnection> {
    const mode = this.desiredMode()
    const conn = new AppServerConnection(this.deps.connect(mode), message =>
      this.deps.log.warn('codex app-server protocol', { message }),
    )
    this.conn = conn
    this.appliedMode = mode
    conn.onNotification((method, params) => {
      if (this.conn === conn) this.onNotification(method, params)
    })
    conn.setServerRequestHandler((method, params) => this.onServerRequest(method, params))
    conn.onClose(code => {
      // Старый app-server, закрытый при смене режима, — штатно, драйвер живёт дальше.
      if (this.conn !== conn) return
      this.ready = false
      if (this.heartbeatTimer !== undefined) clearInterval(this.heartbeatTimer)
      if (this.modeTimer !== undefined) clearInterval(this.modeTimer)
      if (!this.stopping) this.deps.log.error('codex app-server exited', { code })
      this.exit(code)
    })
    await conn.request('initialize', { clientInfo: CLIENT_INFO, capabilities: null })
    conn.notify('initialized')
    return conn
  }

  private desiredMode(): PiiMode {
    return this.deps.piiMode?.() ?? 'proxy'
  }

  /**
   * Сменить режим pii-proxy, если watchdog записал другой. Адрес модели codex читает на старте
   * app-server, поэтому app-server перезапускается, а нить продолжается (thread/resume) — с
   * историей разговора; новые сообщения на время смены ждут в очереди. Не вышло — драйвер
   * завершается, watchdog поднимет его заново (на старте нить тоже восстанавливается).
   *
   * Возврат через прокси — только между ходами. Переход напрямую (решение владельца 23.11.2026)
   * прокси мёртв, ход всё равно упадёт: turn/interrupt и повтор того же входа в той же нити уже
   * напрямую (interruptForReplay), пользователь ничего не пересылает.
   *
   * @returns true — смена была (или завершилась ошибкой); false — менять нечего или не время.
   */
  private async maybeSwitchMode(): Promise<boolean> {
    if (!this.ready || this.stopping || this.switching) return false
    const want = this.desiredMode()
    if (want === this.appliedMode) return false
    if (this.active !== undefined) {
      if (want !== 'direct' || this.active.id === '') return false
      this.switching = true
      try {
        await this.interruptForReplay(this.active)
      } finally {
        this.switching = false
      }
      // Ход успел закончиться сам — режим сменится между ходами обычным путём (pump).
      if (this.active !== undefined) return false
    }
    this.switching = true
    this.ready = false
    const from = this.appliedMode
    this.deps.log.info('codex pii mode switch', { from, to: want, thread_id: this.threadId })
    const old = this.conn
    this.conn = undefined
    old?.close()
    try {
      const conn = await this.openConnection()
      const params = { threadId: this.threadId, excludeTurns: true }
      const res = record(await conn.request('thread/resume', params, THREAD_START_TIMEOUT_MS))
      this.adoptThread(record(res.thread))
      this.ready = true
      this.deps.log.info('codex pii mode switched', {
        mode: this.appliedMode,
        thread_id: this.threadId,
      })
    } catch (err) {
      this.deps.log.error('codex pii mode switch failed — driver exits for a clean restart', {
        to: want,
        error: err instanceof Error ? err.message : String(err),
      })
      this.exit(null)
      return true
    } finally {
      this.switching = false
    }
    void this.pump()
    return true
  }

  /**
   * Прервать ход ради перехода напрямую. Его вход встаёт в начало очереди и уйдёт первым ходом
   * после смены app-server. Ход, успевший закончиться сам (turn/completed не interrupted),
   * обрабатывается как обычно и не повторяется — ответ уже был.
   */
  private async interruptForReplay(turn: ActiveTurn): Promise<void> {
    this.cancelPendingAsk()
    this.interrupting = turn
    this.deps.log.info('codex turn interrupted for direct mode', { turn_id: turn.id })
    try {
      await this.conn?.request(
        'turn/interrupt',
        { threadId: this.threadId, turnId: turn.id },
        PII_INTERRUPT_TIMEOUT_MS,
      )
    } catch (err) {
      this.deps.log.warn('codex turn/interrupt failed — replaying anyway', {
        error: err instanceof Error ? err.message : String(err),
      })
    }
    // Ждём turn/completed прерванного хода; не пришёл — старый app-server всё равно закрывается.
    for (
      let waited = 0;
      this.active === turn && waited < PII_INTERRUPT_TIMEOUT_MS;
      waited += INTERRUPT_POLL_MS
    ) {
      await new Promise(resolve => setTimeout(resolve, INTERRUPT_POLL_MS))
    }
    if (this.active === turn) {
      this.active = undefined
      this.requeueForReplay(turn)
    }
    this.interrupting = undefined
  }

  /** Вернуть вход хода в начало очереди: повтор напрямую, реакция «прочитано» уже стоит. */
  private requeueForReplay(turn: ActiveTurn): void {
    const inputs = turn.inputs.map(q => ({ ...q, messageId: undefined }))
    this.queue.unshift(...inputs)
    this.persistQueue()
    if (turn.messageIds.length > 0) {
      const carried = this.replayMessageIds.get(turn.chatId) ?? []
      this.replayMessageIds.set(turn.chatId, [...carried, ...turn.messageIds])
    }
    this.deps.log.info('codex turn input queued for replay', {
      chat_id: turn.chatId,
      messages: inputs.length,
    })
  }

  /**
   * Принять входящее сообщение (Telegram, задача, webhook).
   *
   * @param event Событие канала; meta.chat_id обязателен.
   * @param handle Подтверждение для входа с постоянной копией (файл задачи): ack — после
   *   конца хода, взявшего вход. Без него вход до начала хода живёт в файле очереди.
   * @returns true — принято (доставлено вдогонку или поставлено в очередь).
   */
  async deliver(event: ChannelEvent, handle?: DeliveryHandle): Promise<boolean> {
    const chatId = event.meta.chat_id ?? ''
    if (chatId === '') {
      this.deps.log.error('codex inbound without chat_id dropped')
      return false
    }
    if (this.stopping) return false
    // /stop из Telegram: прервать текущий ход, а не дописывать «/stop» модели.
    if (event.meta.command === 'stop') {
      await this.interrupt()
      handle?.ack()
      return true
    }
    const rawId = Number.parseInt(event.meta.message_id ?? '', 10)
    const input: QueuedInput = {
      text: formatChannelInbound(event),
      chatId,
      messageId: Number.isFinite(rawId) ? rawId : undefined,
      ...(handle !== undefined ? { handle } : {}),
    }
    // Ждём ответ на синхронный вопрос этого чата: это сообщение — ответ, а не новый ход/вход.
    if (this.pendingAsk !== undefined && this.pendingAsk.chatId === chatId) {
      const resolve = this.pendingAsk.resolve
      this.pendingAsk = undefined
      this.markRead(input)
      handle?.ack()
      resolve(event.content)
      return true
    }
    if (this.ready && this.active !== undefined && this.active.id !== '' && this.active.chatId === chatId) {
      if (await this.steer(this.active, input)) return true
    }
    this.queue.push(input)
    this.persistQueue()
    void this.pump()
    return true
  }

  /**
   * Сбросить контекст (/reset force): память сбрасывается в общий мозг, затем новая нить с
   * пересобранной идентичностью. Во время хода не выполняется — вызывающий ждёт простоя.
   */
  async resetThread(): Promise<void> {
    if (!this.ready || this.active !== undefined) throw new Error('codex thread is busy')
    this.ready = false
    try {
      await this.safeMemory('session-end', { hook_event_name: 'SessionEnd', reason: 'clear' })
      await this.deps.effects.rebuildIdentity()
      // Новая нить читает только что собранный AGENTS.md — его отпечаток и сохраняем. Раньше
      // в состоянии оставался отпечаток со старта драйвера: если AGENTS.md с тех пор менялся,
      // первый же перезапуск после /reset принимал инструкции за изменившиеся и начинал ещё
      // одну нить — переписка после сброса терялась (HRV, 26.11.2026).
      this.identityHash = this.deps.identityHash?.() ?? this.identityHash
      await this.startNewThread('clear')
      this.saveThread()
      this.deps.log.info('codex thread reset', { thread_id: this.threadId })
    } finally {
      this.ready = true
      void this.pump()
    }
  }

  private async startNewThread(source: 'startup' | 'clear'): Promise<void> {
    const res = record(
      await this.conn!.request(
        'thread/start',
        { cwd: this.deps.workspace, approvalPolicy: 'never', sandbox: 'danger-full-access' },
        THREAD_START_TIMEOUT_MS,
      ),
    )
    this.adoptThread(record(res.thread))
    this.sessionContext = (
      await this.safeMemory('session-start', { hook_event_name: 'SessionStart', source })
    ).trim()
  }

  /** Снять ожидание ответа на синхронный вопрос: вызов request_user_input получит пустой ответ. */
  private cancelPendingAsk(): void {
    const pending = this.pendingAsk
    if (pending === undefined) return
    this.pendingAsk = undefined
    pending.resolve(null)
  }

  /** Прервать текущий ход (команда /stop). */
  async interrupt(): Promise<void> {
    this.cancelPendingAsk()
    const turn = this.active
    if (turn === undefined || turn.id === '' || this.conn === undefined) return
    try {
      await this.conn.request('turn/interrupt', { threadId: this.threadId, turnId: turn.id })
    } catch (err) {
      this.deps.log.warn('codex turn/interrupt failed', {
        error: err instanceof Error ? err.message : String(err),
      })
    }
  }

  /**
   * Остановить драйвер: хук конца сессии, затем app-server. Очередь уже в файле (пишется
   * сквозь), задачи без ack остаются в папке-очереди — следующий запуск подберёт и то, и другое.
   */
  async stop(): Promise<void> {
    if (this.stopping) return
    this.stopping = true
    if (this.heartbeatTimer !== undefined) clearInterval(this.heartbeatTimer)
    await this.safeMemory('session-end', { hook_event_name: 'SessionEnd', reason: 'driver-stop' })
    this.conn?.close()
  }

  private adoptThread(thread: Record<string, unknown>): void {
    const id = typeof thread.id === 'string' ? thread.id : ''
    if (id === '') throw new Error('app-server returned a thread without id')
    this.threadId = id
    this.transcriptPath = typeof thread.path === 'string' && thread.path !== '' ? thread.path : this.deps.stateFile
  }

  private readState(): ThreadState {
    try {
      const data = record(JSON.parse(readFileSync(this.deps.stateFile, 'utf8')))
      return {
        threadId: typeof data.threadId === 'string' ? data.threadId : '',
        ...(typeof data.identityHash === 'string' ? { identityHash: data.identityHash } : {}),
        ...(typeof data.resumeFailures === 'number' ? { resumeFailures: data.resumeFailures } : {}),
      }
    } catch {
      return { threadId: '' }
    }
  }

  /** Сохранить текущую нить: счётчик неудачных resume обнуляется. */
  private saveThread(): void {
    this.writeState({
      threadId: this.threadId,
      ...(this.identityHash !== undefined ? { identityHash: this.identityHash } : {}),
    })
  }

  private writeState(state: ThreadState): void {
    writeJsonAtomic(this.deps.stateFile, { ...state, savedAt: new Date(this.now()).toISOString() })
  }

  /**
   * Очередь входящих в файл — сквозь, на каждое изменение: переживает и SIGKILL/OOM, не только
   * штатную остановку. Входы с DeliveryHandle не пишутся: их копия — файл задачи.
   */
  private persistQueue(): void {
    const items: PersistedInput[] = this.queue
      .filter(q => q.handle === undefined)
      .map(q => ({ text: q.text, chatId: q.chatId, ...(q.messageId !== undefined ? { messageId: q.messageId } : {}) }))
    try {
      if (items.length === 0) rmSync(this.queueFile, { force: true })
      else writeJsonAtomic(this.queueFile, { items })
    } catch (err) {
      this.deps.log.warn('codex queue persist failed', { error: err instanceof Error ? err.message : String(err) })
    }
  }

  private restoreQueue(): void {
    let raw: string
    try {
      raw = readFileSync(this.queueFile, 'utf8')
    } catch {
      return
    }
    let items: unknown[] = []
    try {
      const data = record(JSON.parse(raw))
      items = Array.isArray(data.items) ? (data.items as unknown[]) : []
    } catch {
      this.deps.log.warn('codex queue file unreadable — dropped')
    }
    for (const it of items) {
      const r = record(it)
      if (typeof r.text !== 'string' || typeof r.chatId !== 'string' || r.chatId === '') continue
      this.queue.push({
        text: r.text,
        chatId: r.chatId,
        messageId: typeof r.messageId === 'number' ? r.messageId : undefined,
      })
    }
    if (this.queue.length > 0) this.deps.log.info('codex queue restored', { messages: this.queue.length })
    this.persistQueue()
  }

  private hookContext(chatId: string): HookContext {
    return { chatId, threadId: this.threadId, cwd: this.deps.workspace, transcriptPath: this.transcriptPath }
  }

  private async steer(turn: ActiveTurn, input: QueuedInput): Promise<boolean> {
    try {
      await this.conn!.request('turn/steer', {
        threadId: this.threadId,
        expectedTurnId: turn.id,
        input: [textInput(input.text)],
      })
      turn.inputs.push(input)
      if (input.messageId !== undefined) turn.messageIds.push(input.messageId)
      this.markRead(input)
      return true
    } catch (err) {
      // Ход успел закончиться — сообщение начнёт следующий.
      this.deps.log.info('codex steer refused — queued for the next turn', {
        error: err instanceof Error ? err.message : String(err),
      })
      return false
    }
  }

  /** Начать ход из очереди, если нить свободна. */
  private async pump(): Promise<void> {
    if (!this.ready || this.stopping || this.active !== undefined || this.queue.length === 0) return
    // Режим сменился — сначала переключиться: сообщение уйдёт уже в нужном режиме.
    if (this.desiredMode() !== this.appliedMode) {
      void this.maybeSwitchMode()
      return
    }
    const first = this.queue[0]!
    // В один ход идут все ожидающие сообщения того же чата: человек дописал несколько подряд.
    const batch = this.queue.filter(q => q.chatId === first.chatId)
    for (const q of batch) this.queue.splice(this.queue.indexOf(q), 1)
    this.persistQueue()
    const turn: ActiveTurn = {
      id: '',
      chatId: first.chatId,
      replies: new Set(),
      inputs: [...batch],
      lastAgentText: '',
      messageIds: [
        ...(this.replayMessageIds.get(first.chatId) ?? []),
        ...batch.flatMap(q => (q.messageId !== undefined ? [q.messageId] : [])),
      ],
    }
    this.replayMessageIds.delete(first.chatId)
    this.active = turn
    this.openItems.clear()
    this.lastTurnActivity = this.now()
    const input: Array<Record<string, unknown>> = []
    if (this.sessionContext !== '') {
      input.push(textInput(this.sessionContext))
      this.sessionContext = ''
    }
    for (const q of batch) input.push(textInput(q.text))
    void this.emitStatus(promptHook(this.hookContext(turn.chatId)))
    try {
      const res = record(await this.conn!.request('turn/start', { threadId: this.threadId, input }))
      const id = record(res.turn).id
      if (turn.id === '' && typeof id === 'string') turn.id = id
      for (const q of batch) this.markRead(q)
      await this.steerWaiting(turn)
    } catch (err) {
      this.deps.log.error('codex turn/start failed', {
        error: err instanceof Error ? err.message : String(err),
      })
      if (this.active === turn) this.active = undefined
      // Задачи отдаются папке-очереди обратно: повторит она (с пределом попыток).
      for (const q of turn.inputs) q.handle?.release()
      await this.safeDeliver(turn.chatId, '⚠️ Не удалось передать сообщение агенту, повторите позже.')
      void this.pump()
    }
  }

  /** Сообщения того же чата, пришедшие пока turn/start был в пути, — вдогонку. */
  private async steerWaiting(turn: ActiveTurn): Promise<void> {
    while (this.active === turn && turn.id !== '') {
      const idx = this.queue.findIndex(q => q.chatId === turn.chatId)
      if (idx < 0) return
      const next = this.queue[idx]!
      if (!(await this.steer(turn, next))) return
      this.queue.splice(this.queue.indexOf(next), 1)
      this.persistQueue()
    }
  }

  private onNotification(method: string, params: unknown): void {
    const p = record(params)
    if (typeof p.threadId === 'string' && p.threadId !== this.threadId) return
    // Признак жизни — только уведомление своей нити: глобальные (лимиты, статус MCP) могут
    // идти и при зависшем ходе.
    if (p.threadId === this.threadId) {
      this.lastTurnActivity = this.now()
      void this.heartbeat(false)
      this.trackItem(method, record(p.item))
    }
    const turn = this.active
    switch (method) {
      case 'turn/started': {
        const id = record(p.turn).id
        if (turn !== undefined && turn.id === '' && typeof id === 'string') {
          turn.id = id
          void this.steerWaiting(turn)
        }
        return
      }
      case 'item/started':
      case 'item/completed': {
        const item = record(p.item) as CodexItem
        if (typeof item.type !== 'string') return
        if (method === 'item/started' && item.type === 'contextCompaction') {
          void this.safeMemory('precompact', { hook_event_name: 'PreCompact', trigger: 'auto' })
          return
        }
        if (turn === undefined) return
        if (isAsyncAgentMessage(item)) {
          if (method === 'item/completed') this.onAsyncAgentMessage(turn, item)
          return
        }
        if (method === 'item/completed') {
          const reply = replyTextOf(item)
          if (reply !== undefined && item.status !== 'failed') turn.replies.add(normalizeForDedup(reply.text))
          if (item.type === 'agentMessage' && typeof item.text === 'string' && item.text.trim() !== '') {
            turn.lastAgentText = item.text
          }
        }
        const phase = method === 'item/started' ? 'PreToolUse' : 'PostToolUse'
        const payload = toolHook(phase, item, this.hookContext(turn.chatId))
        if (payload !== undefined) void this.emitStatus(payload)
        return
      }
      case 'turn/plan/updated': {
        if (turn === undefined || !Array.isArray(p.plan)) return
        const plan = (p.plan as unknown[]).map(s => {
          const step = record(s)
          return { step: String(step.step ?? ''), status: String(step.status ?? 'pending') } as PlanStep
        })
        void this.emitStatus(planHook(plan, String(p.turnId ?? turn.id), this.hookContext(turn.chatId)))
        return
      }
      case 'turn/completed':
        void this.finishTurn(record(p.turn))
        return
      default:
        return
    }
  }

  /**
   * Асинхронное сообщение агента посреди хода. Вопрос (questions) уходит обычным текстом в чат
   * хода (без кнопок); ответ оператора придёт обычным сообщением и начнёт/продолжит ход. Без
   * вопросов — просто текст в чат. Текст и заголовки вопросов запоминаются как уже
   * отправленные: финальное сообщение с тем же текстом не уйдёт второй раз.
   */
  private onAsyncAgentMessage(turn: ActiveTurn, item: CodexItem): void {
    if (this.asyncSeen.has(item.id)) return
    this.asyncSeen.add(item.id)
    if (this.asyncSeen.size > ASYNC_SEEN_LIMIT) {
      const oldest = this.asyncSeen.values().next().value
      if (oldest !== undefined) this.asyncSeen.delete(oldest)
    }
    const text = typeof item.text === 'string' ? item.text : ''
    const questions = asyncQuestionsOf(item)
    if (text.trim() !== '') turn.replies.add(normalizeForDedup(text))
    for (const q of questions) turn.replies.add(normalizeForDedup(q.title))
    // Вопрос — обычным текстом (заголовок + варианты списком), без кнопок: ответ оператора
    // придёт обычным сообщением и начнёт/продолжит ход. Без вопросов — просто текст сообщения.
    const out = questions.length > 0 ? questionsToText(text, questions) : text
    if (out.trim() !== '') {
      turn.replies.add(normalizeForDedup(out))
      void this.safeDeliver(turn.chatId, out)
    }
  }


  /** Учёт незавершённых элементов хода (любого типа: список типов у Codex растёт). */
  private trackItem(method: string, item: Record<string, unknown>): void {
    if (typeof item.id !== 'string' || item.id === '') return
    if (method === 'item/started') this.openItems.set(item.id, typeof item.type === 'string' ? item.type : '?')
    else if (method === 'item/completed') this.openItems.delete(item.id)
  }

  private async finishTurn(turnData: Record<string, unknown>): Promise<void> {
    const turn = this.active
    if (turn === undefined) return
    const id = typeof turnData.id === 'string' ? turnData.id : ''
    if (turn.id !== '' && id !== '' && id !== turn.id) return
    this.cancelPendingAsk()
    this.active = undefined
    this.openItems.clear()
    const status = String(turnData.status ?? '')

    // Ход прерван ради перехода напрямую или упал, пока прокси уже признан мёртвым: не ответ и
    // не ошибка для пользователя — вход повторится напрямую после смены app-server.
    const proxyDead = this.desiredMode() === 'direct' && this.appliedMode !== 'direct'
    const interrupted = this.interrupting === turn && status === 'interrupted'
    if (interrupted || (proxyDead && status === 'failed')) {
      this.requeueForReplay(turn)
      void this.pump()
      return
    }

    const items = Array.isArray(turnData.items) ? (turnData.items as unknown[]) : []
    const finalText = lastAgentMessage(items) || turn.lastAgentText
    // Ход закончился (любым статусом) — задачи, которые он взял, выполнены: удалить их файлы.
    for (const q of turn.inputs) q.handle?.ack()
    if (status === 'failed') {
      const message = String(record(turnData.error).message ?? 'неизвестная ошибка')
      this.deps.log.error('codex turn failed', { turn_id: id, error: message })
      await this.safeDeliver(turn.chatId, `⚠️ Ход агента завершился ошибкой: ${message}`)
    } else if (finalText.trim() !== '' && !turn.replies.has(normalizeForDedup(finalText))) {
      await this.safeDeliver(turn.chatId, finalText)
    }
    for (const messageId of turn.messageIds) this.markDone(turn.chatId, messageId)

    const ctx = this.hookContext(turn.chatId)
    await this.emitStatus(stopHook(ctx))
    void this.safeMemory('stop', {
      hook_event_name: 'Stop',
      session_id: this.threadId,
      transcript_path: this.transcriptPath,
      cwd: this.deps.workspace,
      last_assistant_message: finalText,
      last_user_message: turn.inputs.map(q => q.text).join('\n'),
    })
    void this.pump()
  }

  private async onServerRequest(method: string, params: unknown): Promise<unknown> {
    const p = record(params)
    switch (method) {
      case 'item/commandExecution/requestApproval':
      case 'item/fileChange/requestApproval':
        this.deps.log.warn('codex approval request declined (approval_policy=never expected)', { method })
        return { decision: 'decline' }
      case 'execCommandApproval':
      case 'applyPatchApproval':
        this.deps.log.warn('codex legacy approval request declined', { method })
        return { decision: 'denied' }
      case 'mcpServer/elicitation/request':
        return { action: 'decline', content: null, _meta: null }
      case 'item/tool/requestUserInput': {
        const chatId = this.active?.chatId ?? ''
        const questions = Array.isArray(p.questions) ? (p.questions as UserInputQuestion[]) : []
        if (chatId === '' || questions.length === 0) return { answers: {} }
        // Вопрос — обычным текстом, без кнопок; ответ оператора вернётся следующим сообщением.
        await this.safeDeliver(
          chatId,
          questionsToText('', questions.map(q => ({ title: q.question, options: q.options?.map(o => o.label) ?? null }))),
        )
        this.cancelPendingAsk()
        this.waitingOnUser += 1
        try {
          const answer = await new Promise<string | null>(resolve => {
            this.pendingAsk = { chatId, resolve }
          })
          if (answer === null || answer.trim() === '') return { answers: {} }
          return { answers: { [questions[0]!.id]: { answers: [answer] } } }
        } finally {
          this.waitingOnUser -= 1
          this.lastTurnActivity = this.now()
        }
      }
      default:
        throw new RpcError(method, RPC_METHOD_NOT_FOUND, `unsupported: ${method}`, null)
    }
  }

  private markRead(input: QueuedInput): void {
    if (input.messageId === undefined) return
    void this.deps.effects.markRead(input.chatId, input.messageId).catch((err: unknown) => {
      this.deps.log.debug('codex read reaction failed (ignored)', {
        error: err instanceof Error ? err.message : String(err),
      })
    })
  }

  private markDone(chatId: string, messageId: number): void {
    void this.deps.effects.markDone(chatId, messageId).catch((err: unknown) => {
      this.deps.log.debug('codex done reaction failed (ignored)', {
        error: err instanceof Error ? err.message : String(err),
      })
    })
  }

  private async emitStatus(payload: Record<string, unknown>): Promise<void> {
    try {
      await this.deps.effects.status(payload)
    } catch (err) {
      this.deps.log.warn('codex status event failed (ignored)', {
        error: err instanceof Error ? err.message : String(err),
      })
    }
  }

  private async safeDeliver(chatId: string, text: string): Promise<void> {
    try {
      await this.deps.effects.deliverFinal(chatId, text)
    } catch (err) {
      this.deps.log.error('codex final message delivery failed', {
        chat_id: chatId,
        error: err instanceof Error ? err.message : String(err),
      })
    }
  }

  private async safeMemory(hook: MemoryHook, payload: Record<string, unknown>): Promise<string> {
    try {
      return await this.deps.effects.memory(hook, {
        session_id: this.threadId,
        transcript_path: this.transcriptPath,
        cwd: this.deps.workspace,
        ...payload,
      })
    } catch (err) {
      this.deps.log.warn('codex memory hook failed (ignored)', {
        hook,
        error: err instanceof Error ? err.message : String(err),
      })
      return ''
    }
  }

  private async heartbeat(force: boolean): Promise<void> {
    const t = this.now()
    if (!force && t - this.lastHeartbeat < HEARTBEAT_MIN_INTERVAL_MS) return
    this.lastHeartbeat = t
    await this.safeMemory('heartbeat', { hook_event_name: 'Heartbeat' })
  }
}

/** Записать JSON атомарно (временный файл + rename), права 0600. */
function writeJsonAtomic(path: string, data: unknown): void {
  mkdirSync(dirname(path), { recursive: true })
  const tmp = `${path}.tmp`
  writeFileSync(tmp, `${JSON.stringify(data)}\n`, { mode: 0o600 })
  renameSync(tmp, path)
}
