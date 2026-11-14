/** Константы HTTP-прокси (общие константы ядра - в @labops/pii). */

/** Предел тела запроса, байт (вложения base64 бывают большими). */
export const MAX_REQUEST_BODY_BYTES = 256 * 1024 * 1024;
/** Таймаут простоя соединения Bun.serve, секунд (долгие SSE-ответы). */
export const SERVER_IDLE_TIMEOUT_S = 255;

/** Заголовок сессии Claude Code. */
export const SESSION_HEADER = 'x-claude-code-session-id';

/**
 * Сколько отказов 422/503 подряд в одной сессии считаются «агент застрял». Три: одиночный
 * отказ бывает честным (в запросе нашлись ПДн, модель переформулирует), три подряд - петля.
 */
export const STUCK_FAILURE_THRESHOLD = 3;
/** Не чаще раза в час сигнал «сессия застряла» на одну сессию, мс. */
export const STUCK_ALERT_INTERVAL_MS = 60 * 60 * 1_000;
/** Сколько сессий помнит счётчик застревания (память ограничена). */
export const STUCK_TRACKER_MAX_SESSIONS = 1_000;
/** Маршрут проверки живости (без авторизации; прокси слушает только 127.0.0.1). */
export const HEALTH_ROUTE = '/health';

/** Текст служебной пробы квоты, которую claude шлёт первым запросом сессии под подпиской. */
export const QUOTA_PROBE_TEXT = 'quota';
/** max_tokens пробы квоты. */
export const QUOTA_PROBE_MAX_TOKENS = 1;
/** Заголовки ответа upstream, которые пишутся в журнал при отказе (без cookie и прочего). */
export const UPSTREAM_LOG_HEADER = /^(?:request-id|retry-after|x-should-retry|anthropic-ratelimit-.+)$/;
/** Сколько байт тела отказа upstream читается ради поля error.type. */
export const UPSTREAM_ERROR_BODY_MAX_BYTES = 4_096;
