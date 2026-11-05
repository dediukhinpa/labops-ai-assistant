import { z } from 'zod';

/** Политика для вложений (image, PDF), пока маскирование картинок не готово. */
/**
 * Что делать с фото и PDF (base64/url) в запросе: passthrough - отправить как есть (решение
 * владельца 04.11.2026: маскирование изображений отложено, ПДн на картинках - осознанное
 * исключение), strip - заменить заглушкой, reject - отказать (422).
 */
export type ImagePolicy = 'passthrough' | 'strip' | 'reject';

const DEFAULT_HOST = '127.0.0.1';
const DEFAULT_UPSTREAM = 'https://api.anthropic.com';
const DEFAULT_PSEUDONYMIZER_URL = 'http://127.0.0.1:8300';
const DEFAULT_TIMEOUT_MS = 10_000;
const MAX_PORT = 65_535;

const envSchema = z.object({
  PII_PROXY_PORT: z.coerce.number().int().min(0).max(MAX_PORT),
  PII_PROXY_HOST: z.string().min(1).default(DEFAULT_HOST),
  PII_PROXY_UPSTREAM: z.string().url().default(DEFAULT_UPSTREAM),
  PII_PROXY_AGENT_ID: z.string().min(1).regex(/^[^/:\s]+$/, 'без «/», «:» и пробелов'),
  PSEUDONYMIZER_URL: z.string().url().default(DEFAULT_PSEUDONYMIZER_URL),
  PSEUDONYMIZER_API_TOKEN: z.string().min(1),
  PSEUDONYMIZER_TIMEOUT_MS: z.coerce.number().int().positive().default(DEFAULT_TIMEOUT_MS),
  PII_PROXY_IMAGE_POLICY: z.enum(['passthrough', 'strip', 'reject']).default('passthrough'),
  // Падежные метки во входе: просим сервис ставить [PERSON_N|падеж] у ФИО в косвенном падеже.
  // По умолчанию включено (решение владельца); false не шлёт поле: совместимо со старым
  // сервисом.
  // Файл событий session_stuck для watchdog (JSON-строки без ПДн). Пусто - не писать.
  PII_PROXY_ALERT_FILE: z.string().min(1).optional(),
  PII_PROXY_CASE_LABELS: z.enum(['true', 'false']).default('true').transform((v) => v === 'true'),
});

/** Настройки прокси. Токен сервиса нельзя выводить в журнал. */
export interface ProxyConfig {
  readonly port: number;
  readonly host: string;
  readonly upstream: string;
  readonly agentId: string;
  readonly pseudonymizerUrl: string;
  readonly pseudonymizerToken: string;
  readonly timeoutMs: number;
  readonly imagePolicy: ImagePolicy;
  /** Просить у сервиса падежные метки у ФИО во входе (`case_labels`). */
  readonly caseLabels: boolean;
  /** Файл, куда дописывается событие session_stuck (читает watchdog). */
  readonly alertFile?: string;
}

/**
 * Разобрать конфиг из переменных окружения.
 * @throws Error с перечнем неверных переменных (значения в сообщение не попадают).
 */
export function loadConfig(env: Record<string, string | undefined>): ProxyConfig {
  const parsed = envSchema.safeParse(env);
  if (!parsed.success) {
    const names = parsed.error.issues.map((i) => i.path.join('.')).join(', ');
    throw new Error(`Неверная конфигурация pii-proxy: ${names}`);
  }
  const v = parsed.data;
  return {
    port: v.PII_PROXY_PORT,
    host: v.PII_PROXY_HOST,
    upstream: v.PII_PROXY_UPSTREAM.replace(/\/+$/, ''),
    agentId: v.PII_PROXY_AGENT_ID,
    pseudonymizerUrl: v.PSEUDONYMIZER_URL.replace(/\/+$/, ''),
    pseudonymizerToken: v.PSEUDONYMIZER_API_TOKEN,
    timeoutMs: v.PSEUDONYMIZER_TIMEOUT_MS,
    imagePolicy: v.PII_PROXY_IMAGE_POLICY,
    caseLabels: v.PII_PROXY_CASE_LABELS,
    ...(v.PII_PROXY_ALERT_FILE !== undefined ? { alertFile: v.PII_PROXY_ALERT_FILE } : {}),
  };
}
