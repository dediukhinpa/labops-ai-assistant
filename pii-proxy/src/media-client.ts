import { z } from 'zod';
import { MediaMaskerError } from './errors';

/** Коды ответа media-masker, означающие «этот файл не обработать» (остальные - сбой сервиса). */
const REFUSAL_STATUSES: ReadonlySet<number> = new Set([413, 422]);
/** Сколько символов кода причины берётся из ответа в журнал. */
const MAX_CODE_CHARS = 40;

const imageSchema = z.object({ media_type: z.string().min(1), data: z.string().min(1) });
const extractSchema = z.object({
  kind: z.enum(['text', 'images', 'mixed']),
  pages: z.array(z.object({
    index: z.number().int(),
    text: z.string().nullable(),
    image: imageSchema.nullable(),
  })),
});
const errorSchema = z.object({ error: z.string() });

/** Закрашенная картинка. */
export interface MaskedImage {
  readonly mediaType: string;
  readonly data: string;
}

/** Страница PDF: либо текстовый слой, либо замаскированная картинка. */
export interface DocumentPage {
  readonly text: string | null;
  readonly image: MaskedImage | null;
}

/** Результат разбора PDF. */
export interface ExtractedDocument {
  readonly pages: readonly DocumentPage[];
}

/** Что нужно прокси от media-masker (в тестах подменяется). */
export interface MediaMasker {
  maskImage(mediaType: string, data: string): Promise<MaskedImage>;
  extractDocument(data: string): Promise<ExtractedDocument>;
}

/** Настройки HTTP-клиента media-masker. */
export interface MediaClientOptions {
  readonly baseUrl: string;
  readonly token: string;
  readonly timeoutMs: number;
}

/**
 * HTTP-клиент media-masker. Отказ по файлу (413/422) - MediaMaskerError('refused'),
 * любой другой сбой (сеть, таймаут, 5xx, 401, неверный ответ) - MediaMaskerError('unavailable').
 */
export class HttpMediaMasker implements MediaMasker {
  constructor(private readonly options: MediaClientOptions) {}

  async maskImage(mediaType: string, data: string): Promise<MaskedImage> {
    const raw = await this.post('/mask_image', { media_type: mediaType, data });
    const r = parseWith(imageSchema, raw);
    return { mediaType: r.media_type, data: r.data };
  }

  async extractDocument(data: string): Promise<ExtractedDocument> {
    const raw = await this.post('/extract_document', { media_type: 'application/pdf', data });
    const r = parseWith(extractSchema, raw);
    return {
      pages: r.pages.map((p) => ({
        text: p.text,
        image: p.image === null ? null : { mediaType: p.image.media_type, data: p.image.data },
      })),
    };
  }

  private async post(path: string, body: unknown): Promise<unknown> {
    let res: Response;
    try {
      res = await fetch(`${this.options.baseUrl}${path}`, {
        method: 'POST',
        headers: {
          authorization: `Bearer ${this.options.token}`,
          'content-type': 'application/json',
        },
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(this.options.timeoutMs),
      });
    } catch (e) {
      const timeout = e instanceof Error && e.name === 'TimeoutError';
      throw new MediaMaskerError('unavailable', timeout ? 'timeout' : 'unreachable');
    }
    if (!res.ok) {
      const code = await refusalCode(res);
      const kind = REFUSAL_STATUSES.has(res.status) ? 'refused' : 'unavailable';
      throw new MediaMaskerError(kind, code);
    }
    try {
      return (await res.json()) as unknown;
    } catch {
      throw new MediaMaskerError('unavailable', 'invalid_json');
    }
  }
}

async function refusalCode(res: Response): Promise<string> {
  try {
    const parsed = errorSchema.safeParse(await res.json());
    if (parsed.success) return parsed.data.error.slice(0, MAX_CODE_CHARS);
  } catch {
    // тело не JSON: остаётся код статуса
  }
  return `http_${res.status}`;
}

function parseWith<T>(schema: z.ZodType<T>, data: unknown): T {
  const r = schema.safeParse(data);
  if (!r.success) throw new MediaMaskerError('unavailable', 'invalid_response');
  return r.data;
}
