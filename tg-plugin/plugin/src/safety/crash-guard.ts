// Страховка обработчиков аварий и лога от «мёртвого» stderr.
//
// Когда консоль процесса исчезает, запись в stderr падает асинхронно: у Claude Code это
// EPIPE (родитель закрыл socketpair), у Codex — EIO (tmux kill-session удалил pty панели,
// а драйвер — главный процесс панели). Ошибка записи приходит как uncaughtException, обработчик
// снова пишет в тот же stderr — и процесс-сирота (ppid=1) крутит CPU, не доходя до таймеров
// остановки, и держит webhook-порт (прогон 23.11.2026). Поэтому: мёртвый stderr больше не
// трогаем вовсе, а дальше — выход (Claude Code) или штатная остановка (Codex: перед выходом
// драйвер сбрасывает память в общий мозг, её срок ограничен дедлайном shutdown).

/** Коды ошибок записи, означающие, что приёмника лога больше нет. */
const BROKEN_SINK_CODES: ReadonlySet<string> = new Set([
  'EPIPE',
  'EIO',
  'ENXIO',
  'ECONNRESET',
  'ERR_STREAM_DESTROYED',
  'ERR_STREAM_WRITE_AFTER_END',
])

/**
 * Признак ошибки «приёмника лога больше нет» (stderr закрыт или pty удалён).
 * @param err - что угодно, пришедшее в обработчик ошибок.
 * @returns true для EPIPE/EIO и родственных кодов.
 */
export function isBrokenSink(err: unknown): boolean {
  if (err === null || typeof err !== 'object') return false
  const code = (err as { code?: unknown }).code
  return typeof code === 'string' && BROKEN_SINK_CODES.has(code)
}

/** Приёмник строк лога: достаточно метода write. */
export interface LineSink {
  write(chunk: string): unknown
}

/** Обёртка над stderr, которая после поломки молча глотает запись. */
export interface GuardedSink extends LineSink {
  /** Приёмник признан мёртвым: дальше write ничего не делает. */
  readonly dead: boolean
  /** Пометить приёмник мёртвым. */
  markDead(): void
}

/**
 * Обернуть приёмник так, чтобы после markDead() (или синхронной ошибки записи «приёмника нет»)
 * запись в него прекращалась.
 * @param target - настоящий приёмник (process.stderr).
 * @returns охраняемый приёмник.
 */
export function guardSink(target: LineSink): GuardedSink {
  let dead = false
  return {
    get dead(): boolean {
      return dead
    },
    markDead(): void {
      dead = true
    },
    write(chunk: string): unknown {
      if (dead) return false
      try {
        return target.write(chunk)
      } catch (err) {
        if (isBrokenSink(err)) dead = true
        throw err
      }
    },
  }
}

/** Зависимости обработчика аварий (внедряются ради тестов). */
export interface CrashHandlerDeps {
  sink: GuardedSink
  /** Отредактировать строку перед записью (секреты). */
  redact: (line: string) => string
  /** Немедленный выход процесса. */
  exit: (code: number) => void
  /**
   * Штатная остановка, если она уже доступна и уместна (Codex), иначе undefined — тогда
   * при пропаже приёмника процесс просто выходит, как раньше при EPIPE.
   */
  gracefulStop: () => (() => void) | undefined
}

/**
 * Собрать обработчик uncaughtException/unhandledRejection, который не может зациклиться.
 * @param deps - приёмник, редактор, выход и штатная остановка.
 * @returns функция (вид, ошибка) для process.on(...).
 */
export function createCrashHandler(deps: CrashHandlerDeps): (kind: string, err: unknown) => void {
  let handling = false
  return (kind: string, err: unknown): void => {
    if (isBrokenSink(err)) {
      // Консоли больше нет: писать некуда и незачем, иначе — цикл ошибок записи.
      deps.sink.markDead()
      const stop = deps.gracefulStop()
      if (stop === undefined) {
        deps.exit(1)
        return
      }
      stop()
      return
    }
    // Повторный вход (запись ниже упала синхронно и снова вызвала нас) — выходим, а не крутимся.
    if (handling) {
      deps.exit(1)
      return
    }
    if (deps.sink.dead) return
    handling = true
    try {
      deps.sink.write(deps.redact(`telegram channel: ${kind}: ${String(err)}\n`))
    } catch {
      deps.exit(1)
      return
    } finally {
      handling = false
    }
  }
}
