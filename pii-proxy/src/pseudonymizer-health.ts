import type { Pseudonymizer } from '@labops/pii';
import { PSEUDONYMIZER_HEALTH_CACHE_MS, PSEUDONYMIZER_HEALTH_TIMEOUT_MS } from './proxy-constants';

/** Состояние сервиса псевдонимизации для /health прокси. */
export type PseudonymizerState = 'ok' | 'down';

/**
 * Кэшированная проверка живости сервиса псевдонимизации.
 *
 * Зачем: без сервиса прокси отвечает 503 на каждый запрос модели (mask() бросает
 * PseudonymizerError), а его собственный /health оставался ok — оркестрация считала прокси
 * живым, и переход на прямую работу (решение владельца 23.11.2026) не срабатывал: агент стоял.
 * Теперь /health прокси отражает и сервис. Проверка кэшируется (watchdog, listener и doctor
 * спрашивают /health часто) и ограничена коротким таймаутом: /health прокси не должен висеть
 * дольше, чем его ждёт оркестрация (PII_HEALTH_TIMEOUT_SEC = 3 с в lib/pii.sh).
 */
export class PseudonymizerHealth {
  private cached: { state: PseudonymizerState; at: number } | undefined;
  private inflight: Promise<PseudonymizerState> | undefined;

  constructor(
    private readonly service: Pseudonymizer,
    private readonly cacheMs: number = PSEUDONYMIZER_HEALTH_CACHE_MS,
    private readonly timeoutMs: number = PSEUDONYMIZER_HEALTH_TIMEOUT_MS,
    private readonly now: () => number = Date.now,
  ) {}

  /** Состояние сервиса: из кэша, если он свежий, иначе одна общая проверка на всех. */
  async state(): Promise<PseudonymizerState> {
    const c = this.cached;
    if (c !== undefined && this.now() - c.at < this.cacheMs) return c.state;
    if (this.inflight !== undefined) return this.inflight;
    this.inflight = this.probe().then((state) => {
      this.cached = { state, at: this.now() };
      this.inflight = undefined;
      return state;
    });
    return this.inflight;
  }

  /** Одна проверка /health сервиса с таймаутом; любой сбой — down. */
  private async probe(): Promise<PseudonymizerState> {
    let timer: ReturnType<typeof setTimeout> | undefined;
    const timeout = new Promise<PseudonymizerState>((resolve) => {
      timer = setTimeout(() => resolve('down'), this.timeoutMs);
    });
    const check = this.service.health().then(
      (): PseudonymizerState => 'ok',
      (): PseudonymizerState => 'down',
    );
    try {
      return await Promise.race([check, timeout]);
    } finally {
      if (timer !== undefined) clearTimeout(timer);
    }
  }
}
