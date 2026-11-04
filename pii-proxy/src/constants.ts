/** Общие константы pii-proxy: пределы сервиса, таймеры, коды отказов. */

/** Предел длины одного текста сервиса (PSEUDONYMIZER_MAX_TEXT_CHARS по умолчанию). */
export const MAX_TEXT_CHARS = 70_000;
/** Сколько текстов клиент кладёт в одну пачку /pseudonymize_batch (ограничение клиента). */
export const BATCH_MAX_ITEMS = 100;
/** Поправка длины на каждый текст пачки, кроме первого (BATCH_ITEM_COST_CHARS сервиса). */
export const BATCH_ITEM_COST_CHARS = 100;
/** Доля окна, раньше которой граница разреза ищется «дальше» (иначе жёсткий разрез). */
export const SPLIT_SEARCH_MIN_SHARE = 0.5;
/** Перекрытие окон /check для длинного листа, символов (хватает на любой токен/значение). */
export const CHECK_OVERLAP_CHARS = 200;
/** Параллельных вызовов /check и /restore одного запроса. */
export const SERVICE_CONCURRENCY = 6;

/** Не чаще раза в столько мс опрашивается /health сервиса. */
export const HEALTH_POLL_MS = 5_000;
/** Бюджет кэша маскирования, символов (ключи плюс значения), как MASK_CACHE_MAX_CHARS. */
export const MASK_CACHE_MAX_CHARS = 4_000_000;
/** Длина шестнадцатеричного ключа кэша (sha256). */
export const CACHE_KEY_CHARS = 64;

/** Предел длины недописанного токена в потоке. */
export const MAX_PENDING_TOKEN_CHARS = 32;
/** Через сколько мс хвост, не похожий на начало токена, отдаётся как есть. */
export const PENDING_FLUSH_MS = 1_000;
/** Окно склейки восстановления в потоке, мс. */
export const RESTORE_WINDOW_MS = 300;
/** Сколько символов копится до восстановления независимо от окна. */
export const RESTORE_MAX_CHARS = 4_000;

/** Сколько символов sha256 session id попадает в журнал. */
export const SESSION_HASH_CHARS = 8;

/** HTTP-коды ответов прокси. */
export const STATUS_BAD_REQUEST = 400;
export const STATUS_UNSUPPORTED_ENCODING = 415;
export const STATUS_PII_FOUND = 422;
export const STATUS_BAD_GATEWAY = 502;
export const STATUS_UNAVAILABLE = 503;

/** Предел тела запроса, байт (вложения base64 бывают большими). */
export const MAX_REQUEST_BODY_BYTES = 256 * 1024 * 1024;
/** Таймаут простоя соединения Bun.serve, секунд (долгие SSE-ответы). */
export const SERVER_IDLE_TIMEOUT_S = 255;

/** Заголовок сессии Claude Code. */
export const SESSION_HEADER = 'x-claude-code-session-id';

/** Текст замены вложения при политике strip. */
export const ATTACHMENT_STRIPPED_TEXT =
  '[вложение скрыто: маскирование изображений и PDF ещё не включено]';

/** Системная вставка про токены (неизменная строка: иначе ломается кэш промпта). */
export const SYSTEM_INSERT_TEXT =
  'Служебная справка. В тексте встречаются токены вида [PERSON_1], [PHONE_2], [EMAIL_1]: '
  + 'это настоящие значения (имена, телефоны, почта), скрытые от тебя. Используй их как '
  + 'обычные имена и номера: не называй их заглушками, не обсуждай маскирование и не проси '
  + '«настоящие» данные. Если имя нужно в косвенном падеже, допиши код падежа в токене: '
  + '[PERSON_1|datv]. Коды: nomn, gent, datv, accs, ablt, loct.';
