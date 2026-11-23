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
// пишутся в журнал. Вопрос пользователю (request_user_input) уходит кнопками в Telegram.

import { mkdirSync, readFileSync, renameSync, writeFileSync } from 'fs'
import { dirname } from 'path'

import type { Logger } from '../../log.js'
import type { ChannelEvent } from '../../channel/notify.js'
import { formatChannelInbound } from '../../channel/notify.js'
import { AppServerConnection, RPC_METHOD_NOT_FOUND, RpcError, type LineTransport } from './rpc.js'
import {
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
/** Версия клиента в initialize. */
const CLIENT_INFO = { name: 'labops-codex-driver', version: '1.0.0' }

/**
 * Режим относительно pii-proxy: через прокси (норма) или напрямую (прокси не отвечает, решение
 * владельца 23.11.2026). Выбирает watchdog, драйвер только применяет.
 */
export type PiiMode = 'proxy' | 'direct'

/** Хук памяти рабочей папки агента. */
export type MemoryHook = 'session-start' | 'stop' | 'precompact' | 'heartbeat' | 'session-end'

/** Вопрос request_user_input от Codex. */
export interface UserInputQuestion {
  id: string
  header: string
  question: string
  isOther: boolean
  isSecret: boolean
  options: Array<{ label: string; description: string }> | null
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
  /** Спросить оператора кнопками; null — ответа нет (таймаут, чат недоступен). */
  askUser(chatId: string, questions: UserInputQuestion[], requestId: string): Promise<UserInputAnswers | null>
  /** Запустить хук памяти; вернуть его stdout (session-start даёт контекст для первого хода). */
  memory(hook: MemoryHook, payload: Record<string, unknown>): Promise<string>
  /** Пересобрать AGENTS.md из AGENTS.src.md и файлов памяти. */
  rebuildIdentity(): Promise<void>
  /** Отметить сообщение Telegram прочитанным (реакция). */
  markRead(chatId: string, messageId: number): Promise<void>
  /** Отметить сообщение Telegram обработанным: ход, взявший его, закончился (реакция). */
  markDone(chatId: string, messageId: number): Promise<void>
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
}

interface QueuedInput {
  text: string
  chatId: string
  /** message_id сообщения Telegram (для реакции «прочитано»); у задач и webhook его нет. */
  messageId: number | undefined
}

interface ActiveTurn {
  /** Id хода; пусто, пока turn/start не ответил и turn/started не пришло. */
  id: string
  chatId: string
  replies: Set<string>
  userTexts: string[]
  lastAgentText: string
  /** message_id сообщений Telegram, взятых ходом: на конце хода им ставится 👌. */
  messageIds: number[]
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

  constructor(private readonly deps: CodexDriverDeps) {
    this.now = deps.now ?? Date.now
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

    const saved = this.readSavedThread()
    let resumed = false
    if (saved !== '') {
      try {
        const res = record(
          await conn.request('thread/resume', { threadId: saved, excludeTurns: true }, THREAD_START_TIMEOUT_MS),
        )
        this.adoptThread(record(res.thread))
        resumed = true
      } catch (err) {
        this.deps.log.warn('codex thread resume failed — starting a new thread', {
          thread_id: saved,
          error: err instanceof Error ? err.message : String(err),
        })
      }
    }
    if (!resumed) await this.startNewThread('startup')
    this.saveThread()
    this.ready = true
    this.deps.log.info('codex thread ready', { thread_id: this.threadId, resumed })
    void this.heartbeat(true)
    this.heartbeatTimer = setInterval(() => void this.heartbeat(false), IDLE_HEARTBEAT_INTERVAL_MS)
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
      for (const cb of this.exitListeners) cb(code)
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
      for (const cb of this.exitListeners) cb(null)
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
    const inputs = turn.userTexts.map(text => ({ text, chatId: turn.chatId, messageId: undefined }))
    this.queue.unshift(...inputs)
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
   * @returns true — принято (доставлено вдогонку или поставлено в очередь).
   */
  async deliver(event: ChannelEvent): Promise<boolean> {
    const chatId = event.meta.chat_id ?? ''
    if (chatId === '') {
      this.deps.log.error('codex inbound without chat_id dropped')
      return false
    }
    if (this.stopping) return false
    // /stop из Telegram: прервать текущий ход, а не дописывать «/stop» модели.
    if (event.meta.command === 'stop') {
      await this.interrupt()
      return true
    }
    const rawId = Number.parseInt(event.meta.message_id ?? '', 10)
    const input: QueuedInput = {
      text: formatChannelInbound(event),
      chatId,
      messageId: Number.isFinite(rawId) ? rawId : undefined,
    }
    if (this.ready && this.active !== undefined && this.active.id !== '' && this.active.chatId === chatId) {
      if (await this.steer(this.active, input)) return true
    }
    this.queue.push(input)
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

  /** Прервать текущий ход (команда /stop). */
  async interrupt(): Promise<void> {
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
   * Остановить драйвер: хук конца сессии, затем app-server.
   */
  async stop(): Promise<void> {
    if (this.stopping) return
    this.stopping = true
    await this.safeMemory('session-end', { hook_event_name: 'SessionEnd', reason: 'driver-stop' })
    this.conn?.close()
  }

  private adoptThread(thread: Record<string, unknown>): void {
    const id = typeof thread.id === 'string' ? thread.id : ''
    if (id === '') throw new Error('app-server returned a thread without id')
    this.threadId = id
    this.transcriptPath = typeof thread.path === 'string' && thread.path !== '' ? thread.path : this.deps.stateFile
  }

  private readSavedThread(): string {
    try {
      const data = record(JSON.parse(readFileSync(this.deps.stateFile, 'utf8')))
      return typeof data.threadId === 'string' ? data.threadId : ''
    } catch {
      return ''
    }
  }

  private saveThread(): void {
    mkdirSync(dirname(this.deps.stateFile), { recursive: true })
    const tmp = `${this.deps.stateFile}.tmp`
    writeFileSync(tmp, `${JSON.stringify({ threadId: this.threadId, savedAt: new Date(this.now()).toISOString() })}\n`, {
      mode: 0o600,
    })
    renameSync(tmp, this.deps.stateFile)
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
      turn.userTexts.push(input.text)
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
    const turn: ActiveTurn = {
      id: '',
      chatId: first.chatId,
      replies: new Set(),
      userTexts: batch.map(q => q.text),
      lastAgentText: '',
      messageIds: [
        ...(this.replayMessageIds.get(first.chatId) ?? []),
        ...batch.flatMap(q => (q.messageId !== undefined ? [q.messageId] : [])),
      ],
    }
    this.replayMessageIds.delete(first.chatId)
    this.active = turn
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
    }
  }

  private onNotification(method: string, params: unknown): void {
    const p = record(params)
    if (typeof p.threadId === 'string' && p.threadId !== this.threadId) return
    void this.heartbeat(false)
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

  private async finishTurn(turnData: Record<string, unknown>): Promise<void> {
    const turn = this.active
    if (turn === undefined) return
    const id = typeof turnData.id === 'string' ? turnData.id : ''
    if (turn.id !== '' && id !== '' && id !== turn.id) return
    this.active = undefined
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
      last_user_message: turn.userTexts.join('\n'),
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
        const answers =
          chatId === '' || questions.length === 0
            ? null
            : await this.deps.effects.askUser(chatId, questions, String(p.itemId ?? `${this.now()}`))
        return answers ?? { answers: {} }
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
