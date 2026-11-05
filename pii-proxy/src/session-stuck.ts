import {
  STUCK_ALERT_INTERVAL_MS,
  STUCK_FAILURE_THRESHOLD,
  STUCK_TRACKER_MAX_SESSIONS,
} from './proxy-constants';

/** Сработавший сигнал «сессия застряла» (без значений ПДн: только отпечаток и счётчик). */
export interface StuckSignal {
  readonly session: string;
  readonly count: number;
  readonly code: string;
}

interface SessionState {
  failures: number;
  lastAlertMs: number;
}

/**
 * Считает подряд идущие отказы 422/503 внутри одной сессии.
 *
 * Зачем: 04-05.11.2026 агент молчал сутками из-за ложных 422 на собственный текст модели, и
 * заметили это только по молчанию. Успешный запрос обнуляет счётчик; сигнал не чаще раза в
 * STUCK_ALERT_INTERVAL_MS на сессию, чтобы застрявший цикл повторов не заваливал оператора.
 */
export class SessionStuckTracker {
  private readonly sessions = new Map<string, SessionState>();

  constructor(
    private readonly threshold: number = STUCK_FAILURE_THRESHOLD,
    private readonly intervalMs: number = STUCK_ALERT_INTERVAL_MS,
    private readonly now: () => number = Date.now,
  ) {}

  /** Запрос сессии прошёл: серия отказов прервана. */
  recordSuccess(session: string): void {
    const s = this.sessions.get(session);
    if (s !== undefined) s.failures = 0;
  }

  /** Запрос отклонён (422/503). Вернёт сигнал, когда пора сообщить оператору. */
  recordFailure(session: string, code: string): StuckSignal | undefined {
    const s = this.sessions.get(session) ?? { failures: 0, lastAlertMs: Number.NEGATIVE_INFINITY };
    s.failures += 1;
    this.sessions.delete(session);
    this.sessions.set(session, s);
    this.evict();
    const t = this.now();
    if (s.failures < this.threshold || t - s.lastAlertMs < this.intervalMs) return undefined;
    s.lastAlertMs = t;
    return { session, count: s.failures, code };
  }

  /** Держим не больше N сессий: вытесняются давно не трогавшиеся (первые в порядке вставки). */
  private evict(): void {
    while (this.sessions.size > STUCK_TRACKER_MAX_SESSIONS) {
      const oldest = this.sessions.keys().next();
      if (oldest.done === true) return;
      this.sessions.delete(oldest.value);
    }
  }
}
