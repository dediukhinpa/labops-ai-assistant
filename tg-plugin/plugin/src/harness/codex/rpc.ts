// JSON-RPC клиент к `codex app-server` (stdio, одно JSON-сообщение на строку).
//
// Три направления трафика:
//   * наши запросы (initialize, thread/start, turn/start, ...) — ждём ответ по id;
//   * уведомления сервера (turn/started, item/completed, ...) — отдаём подписчику;
//   * запросы сервера к нам (подтверждения, вопрос пользователю) — отвечаем результатом
//     обработчика; без обработчика — ошибкой «метод не поддерживается», иначе ход повиснет.
//
// Транспорт вынесен в интерфейс, чтобы тесты гоняли драйвер против поддельного сервера
// без запуска codex.

import { spawn } from 'child_process'
import { createInterface } from 'readline'

/** Код JSON-RPC «метод не найден». */
export const RPC_METHOD_NOT_FOUND = -32601
/** Код JSON-RPC «внутренняя ошибка» (обработчик запроса сервера упал). */
export const RPC_INTERNAL_ERROR = -32603
/** Сколько ждать ответа на запрос по умолчанию. */
export const DEFAULT_REQUEST_TIMEOUT_MS = 60_000

/** Строчный транспорт: процесс app-server или подделка в тестах. */
export interface LineTransport {
  write(line: string): void
  onLine(cb: (line: string) => void): void
  onClose(cb: (code: number | null) => void): void
  kill(): void
}

/** Ошибка, которую вернул app-server в ответ на наш запрос. */
export class RpcError extends Error {
  readonly code: number
  readonly data: unknown
  constructor(method: string, code: number, message: string, data: unknown) {
    super(`${method}: ${message} (code ${code})`)
    this.name = 'RpcError'
    this.code = code
    this.data = data
  }
}

/** Обработчик запроса сервера: результат уходит в ответ, исключение — ошибкой. */
export type ServerRequestHandler = (method: string, params: unknown) => Promise<unknown>

interface Pending {
  method: string
  resolve: (value: unknown) => void
  reject: (err: Error) => void
  timer: ReturnType<typeof setTimeout>
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

/**
 * Соединение с app-server поверх строчного транспорта.
 */
export class AppServerConnection {
  private nextId = 0
  private readonly pending = new Map<number, Pending>()
  private readonly notificationListeners: Array<(method: string, params: unknown) => void> = []
  private readonly closeListeners: Array<(code: number | null) => void> = []
  private requestHandler: ServerRequestHandler | undefined
  private closed = false

  constructor(
    private readonly transport: LineTransport,
    private readonly onProtocolError: (message: string) => void = () => undefined,
  ) {
    transport.onLine(line => this.handleLine(line))
    transport.onClose(code => this.handleClose(code))
  }

  /** Подписка на уведомления сервера. */
  onNotification(cb: (method: string, params: unknown) => void): void {
    this.notificationListeners.push(cb)
  }

  /** Обработчик запросов сервера (один на соединение). */
  setServerRequestHandler(handler: ServerRequestHandler): void {
    this.requestHandler = handler
  }

  /** Подписка на завершение процесса app-server. */
  onClose(cb: (code: number | null) => void): void {
    this.closeListeners.push(cb)
  }

  get isClosed(): boolean {
    return this.closed
  }

  /**
   * Отправить запрос и дождаться результата.
   *
   * @param method Метод app-server.
   * @param params Параметры.
   * @param timeoutMs Сколько ждать ответа.
   * @returns Поле result ответа.
   */
  request<T = unknown>(
    method: string,
    params: unknown,
    timeoutMs: number = DEFAULT_REQUEST_TIMEOUT_MS,
  ): Promise<T> {
    if (this.closed) return Promise.reject(new Error(`${method}: app-server is not running`))
    this.nextId += 1
    const id = this.nextId
    return new Promise<T>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id)
        reject(new Error(`${method}: no answer in ${timeoutMs} ms`))
      }, timeoutMs)
      this.pending.set(id, {
        method,
        resolve: value => resolve(value as T),
        reject,
        timer,
      })
      this.send({ jsonrpc: '2.0', id, method, params })
    })
  }

  /** Отправить уведомление (без ответа). */
  notify(method: string, params?: unknown): void {
    if (this.closed) return
    this.send(params === undefined ? { jsonrpc: '2.0', method } : { jsonrpc: '2.0', method, params })
  }

  /** Завершить процесс app-server. */
  close(): void {
    if (this.closed) return
    this.transport.kill()
  }

  private send(message: Record<string, unknown>): void {
    this.transport.write(`${JSON.stringify(message)}\n`)
  }

  private handleLine(line: string): void {
    const trimmed = line.trim()
    if (trimmed === '') return
    let msg: unknown
    try {
      msg = JSON.parse(trimmed)
    } catch {
      this.onProtocolError('app-server printed a non-JSON line')
      return
    }
    if (!isRecord(msg)) return
    const hasMethod = typeof msg.method === 'string'
    const id = msg.id
    if (!hasMethod && typeof id === 'number') {
      this.handleResponse(id, msg)
      return
    }
    if (hasMethod && (typeof id === 'number' || typeof id === 'string')) {
      void this.handleServerRequest(id, msg.method as string, msg.params)
      return
    }
    if (hasMethod) {
      for (const cb of this.notificationListeners) {
        try {
          cb(msg.method as string, msg.params)
        } catch (err) {
          this.onProtocolError(
            `notification listener threw: ${err instanceof Error ? err.message : String(err)}`,
          )
        }
      }
    }
  }

  private handleResponse(id: number, msg: Record<string, unknown>): void {
    const pending = this.pending.get(id)
    if (pending === undefined) return
    this.pending.delete(id)
    clearTimeout(pending.timer)
    const error = msg.error
    if (isRecord(error)) {
      const code = typeof error.code === 'number' ? error.code : RPC_INTERNAL_ERROR
      const message = typeof error.message === 'string' ? error.message : 'error'
      pending.reject(new RpcError(pending.method, code, message, error.data))
      return
    }
    pending.resolve(msg.result)
  }

  private async handleServerRequest(id: number | string, method: string, params: unknown): Promise<void> {
    if (this.requestHandler === undefined) {
      this.send({
        jsonrpc: '2.0',
        id,
        error: { code: RPC_METHOD_NOT_FOUND, message: `unsupported: ${method}` },
      })
      return
    }
    try {
      const result = await this.requestHandler(method, params)
      this.send({ jsonrpc: '2.0', id, result: result ?? null })
    } catch (err) {
      const code = err instanceof RpcError ? err.code : RPC_INTERNAL_ERROR
      this.send({
        jsonrpc: '2.0',
        id,
        error: { code, message: err instanceof Error ? err.message : String(err) },
      })
    }
  }

  private handleClose(code: number | null): void {
    if (this.closed) return
    this.closed = true
    for (const [id, pending] of this.pending) {
      clearTimeout(pending.timer)
      pending.reject(new Error(`${pending.method}: app-server exited (code ${String(code)})`))
      this.pending.delete(id)
    }
    for (const cb of this.closeListeners) cb(code)
  }
}

/** Параметры запуска процесса app-server. */
export interface SpawnOptions {
  bin: string
  args: readonly string[]
  cwd: string
  env: NodeJS.ProcessEnv
  /** Строки stderr app-server (журнал codex) — в лог драйвера. */
  onStderr?: (line: string) => void
}

/**
 * Запустить `codex app-server` и вернуть его строчный транспорт.
 *
 * @param opts Бинарь, аргументы, каталог и окружение.
 * @returns Транспорт поверх stdin/stdout процесса.
 */
export function spawnAppServer(opts: SpawnOptions): LineTransport {
  const child = spawn(opts.bin, [...opts.args], {
    cwd: opts.cwd,
    env: opts.env,
    stdio: ['pipe', 'pipe', 'pipe'],
  })
  const stdout = createInterface({ input: child.stdout })
  if (opts.onStderr !== undefined) {
    const onStderr = opts.onStderr
    createInterface({ input: child.stderr }).on('line', line => onStderr(line))
  } else {
    child.stderr.resume()
  }
  const closeCbs: Array<(code: number | null) => void> = []
  let exited = false
  const fireClose = (code: number | null): void => {
    if (exited) return
    exited = true
    for (const cb of closeCbs) cb(code)
  }
  child.on('exit', code => fireClose(code))
  child.on('error', () => fireClose(null))
  // Запись в закрытую трубу не должна ронять драйвер: о смерти сообщит 'exit'.
  child.stdin.on('error', () => undefined)
  return {
    write: line => {
      if (!exited) child.stdin.write(line)
    },
    onLine: cb => {
      stdout.on('line', cb)
    },
    onClose: cb => {
      closeCbs.push(cb)
    },
    kill: () => {
      if (!exited) child.kill('SIGTERM')
    },
  }
}
