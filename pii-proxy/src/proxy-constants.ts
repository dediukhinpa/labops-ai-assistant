/** Константы HTTP-прокси (общие константы ядра - в @labops/pii). */

/** Предел тела запроса, байт (вложения base64 бывают большими). */
export const MAX_REQUEST_BODY_BYTES = 256 * 1024 * 1024;
/** Таймаут простоя соединения Bun.serve, секунд (долгие SSE-ответы). */
export const SERVER_IDLE_TIMEOUT_S = 255;

/** Заголовок сессии Claude Code. */
export const SESSION_HEADER = 'x-claude-code-session-id';
/**
 * Заголовки нити Codex CLI (по живому трафику 0.171.0): thread-id постоянен для нити и
 * переживает перезапуск процесса (thread/resume), session-id — запасной.
 */
export const CODEX_SESSION_HEADERS: readonly string[] = ['thread-id', 'session-id'];

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
/**
 * Сколько мс /health прокси доверяет последней проверке сервиса псевдонимизации. Короче
 * прохода watchdog (~30 с), чтобы каждая его проверка видела свежее состояние, и достаточно
 * долго, чтобы частые /health не нагружали сервис.
 */
export const PSEUDONYMIZER_HEALTH_CACHE_MS = 5_000;
/** Таймаут проверки сервиса из /health, мс: меньше 3 с, которые /health ждёт оркестрация. */
export const PSEUDONYMIZER_HEALTH_TIMEOUT_MS = 1_500;
/** HTTP-код /health, когда прокси жив, а сервис псевдонимизации нет (маскировать нечем). */
export const HEALTH_DEGRADED_STATUS = 503;
/** Причина в ответе /health при недоступном сервисе (по ней оркестрация пишет оператору). */
export const HEALTH_REASON_PSEUDONYMIZER = 'pseudonymizer_unavailable';

/** Текст служебной пробы квоты, которую claude шлёт первым запросом сессии под подпиской. */
export const QUOTA_PROBE_TEXT = 'quota';
/** max_tokens пробы квоты. */
export const QUOTA_PROBE_MAX_TOKENS = 1;
/** Заголовки ответа upstream, которые пишутся в журнал при отказе (без cookie и прочего). */
export const UPSTREAM_LOG_HEADER =
  /^(?:request-id|x-oai-request-id|x-request-id|retry-after|x-should-retry|anthropic-ratelimit-.+|x-codex-(?:primary|secondary|active|plan|credits)-.+)$/;
/** Сколько байт тела отказа upstream читается ради поля error.type. */
export const UPSTREAM_ERROR_BODY_MAX_BYTES = 4_096;
