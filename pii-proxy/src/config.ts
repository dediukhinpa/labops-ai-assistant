import { z } from 'zod';
import type { ImagePolicy } from '@labops/pii';

// ImagePolicy живёт в библиотеке (там нет env); здесь повторно экспортируется для совместимости
export type { ImagePolicy };

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
  // Файл событий session_stuck для watchdog (JSON-строки без ПДн). Пусто - не писать.
  PII_PROXY_ALERT_FILE: z.string().min(1).optional(),
  PII_PROXY_CASE_LABELS: z.enum(['true', 'false']).default('true').transform((v) => v === 'true'),
  // Режим «оригинал, если чисто» для картинок этого агента (media-masker один на всех, режим
  // задаёт запрос прокси): без проверки лиц и QR, закрашиваются только находки детектора ПДн.
  // По умолчанию выключено; включать только по решению владельца для конкретного агента.
  PII_PROXY_MEDIA_ORIGINAL_IF_CLEAN: z.enum(['true', 'false']).default('false')
    .transform((v) => v === 'true'),
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
  /** Режим «оригинал, если чисто» для картинок (`PII_PROXY_MEDIA_ORIGINAL_IF_CLEAN`). */
  readonly mediaOriginalIfClean?: boolean;
  /** Файл, куда дописывается событие session_stuck (читает watchdog). */
  readonly alertFile?: string;
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
    ...(v.PII_PROXY_MEDIA_ORIGINAL_IF_CLEAN ? { mediaOriginalIfClean: true } : {}),
    ...(v.PII_PROXY_ALERT_FILE !== undefined ? { alertFile: v.PII_PROXY_ALERT_FILE } : {}),
  };
}
