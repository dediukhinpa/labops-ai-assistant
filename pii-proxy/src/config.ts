import { z } from 'zod';

/**
 * Что делать с фото и PDF в запросе: mask - через media-masker (OCR, закраска ПДн; по умолчанию),
 * strip - заменить заглушкой, reject - отказать (422), passthrough - отправить как есть
 * (небезопасно: ПДн на картинках уйдут в модель; только по явному решению владельца).
 */
export type ImagePolicy = 'passthrough' | 'mask' | 'strip' | 'reject';

const DEFAULT_HOST = '127.0.0.1';
const DEFAULT_UPSTREAM = 'https://api.anthropic.com';
const DEFAULT_PSEUDONYMIZER_URL = 'http://127.0.0.1:8300';
const DEFAULT_TIMEOUT_MS = 10_000;
const DEFAULT_MEDIA_TIMEOUT_MS = 120_000;
const DEFAULT_MEDIA_MASKER_URL = 'http://127.0.0.1:8320';
const MAX_PORT = 65_535;

const OPTIONAL_WHEN_EMPTY: readonly string[] = [
  'PII_PROXY_IMAGE_POLICY', 'MEDIA_MASKER_URL', 'MEDIA_MASKER_API_TOKEN',
];

const envSchema = z.object({
  PII_PROXY_PORT: z.coerce.number().int().min(0).max(MAX_PORT),
  PII_PROXY_HOST: z.string().min(1).default(DEFAULT_HOST),
  PII_PROXY_UPSTREAM: z.string().url().default(DEFAULT_UPSTREAM),
  PII_PROXY_AGENT_ID: z.string().min(1).regex(/^[^/:\s]+$/, 'без «/», «:» и пробелов'),
  PSEUDONYMIZER_URL: z.string().url().default(DEFAULT_PSEUDONYMIZER_URL),
  PSEUDONYMIZER_API_TOKEN: z.string().min(1),
  PSEUDONYMIZER_TIMEOUT_MS: z.coerce.number().int().positive().default(DEFAULT_TIMEOUT_MS),
  // Маскирование вложений включено по умолчанию (решение владельца 05.11.2026)
  PII_PROXY_IMAGE_POLICY: z.enum(['passthrough', 'mask', 'strip', 'reject']).default('mask'),
  // Падежные метки во входе: просим сервис ставить [PERSON_N|падеж] у ФИО в косвенном падеже.
  // По умолчанию включено (решение владельца); false не шлёт поле: совместимо со старым
  // сервисом.
  PII_PROXY_CASE_LABELS: z.enum(['true', 'false']).default('true').transform((v) => v === 'true'),
  MEDIA_MASKER_URL: z.string().url().default(DEFAULT_MEDIA_MASKER_URL),
  MEDIA_MASKER_API_TOKEN: z.string().min(1).optional(),
  MEDIA_MASKER_TIMEOUT_MS: z.coerce.number().int().positive().default(DEFAULT_MEDIA_TIMEOUT_MS),
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
  /** Адрес и токен media-masker; токен задан всегда при imagePolicy = mask. */
  readonly mediaMaskerUrl: string;
  readonly mediaMaskerToken?: string;
  readonly mediaMaskerTimeoutMs: number;
}

/**
 * Разобрать конфиг из переменных окружения.
 * @throws Error с перечнем неверных переменных (значения в сообщение не попадают).
 */
export function loadConfig(env: Record<string, string | undefined>): ProxyConfig {
  // Пустое значение в EnvironmentFile (`MEDIA_MASKER_URL=`) = переменная не задана
  const cleaned = Object.fromEntries(Object.entries(env).filter(([k, v]) => v !== ''
    || !OPTIONAL_WHEN_EMPTY.includes(k)));
  const parsed = envSchema.safeParse(cleaned);
  if (!parsed.success) {
    const names = parsed.error.issues.map((i) => i.path.join('.')).join(', ');
    throw new Error(`Неверная конфигурация pii-proxy: ${names}`);
  }
  const v = parsed.data;
  const policy: ImagePolicy = v.PII_PROXY_IMAGE_POLICY;
  if (policy === 'mask' && v.MEDIA_MASKER_API_TOKEN === undefined) {
    // Fail closed: без токена media-masker вложения не замаскировать, а пускать их нельзя
    throw new Error('Неверная конфигурация pii-proxy: MEDIA_MASKER_API_TOKEN');
  }
  return {
    port: v.PII_PROXY_PORT,
    host: v.PII_PROXY_HOST,
    upstream: v.PII_PROXY_UPSTREAM.replace(/\/+$/, ''),
    agentId: v.PII_PROXY_AGENT_ID,
    pseudonymizerUrl: v.PSEUDONYMIZER_URL.replace(/\/+$/, ''),
    pseudonymizerToken: v.PSEUDONYMIZER_API_TOKEN,
    timeoutMs: v.PSEUDONYMIZER_TIMEOUT_MS,
    imagePolicy: policy,
    caseLabels: v.PII_PROXY_CASE_LABELS,
    mediaMaskerUrl: v.MEDIA_MASKER_URL.replace(/\/+$/, ''),
    ...(v.MEDIA_MASKER_API_TOKEN === undefined
      ? {} : { mediaMaskerToken: v.MEDIA_MASKER_API_TOKEN }),
    mediaMaskerTimeoutMs: v.MEDIA_MASKER_TIMEOUT_MS,
  };
}
