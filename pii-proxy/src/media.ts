import { createHash } from 'node:crypto';
import { MEDIA_CACHE_MAX_CHARS } from './constants';
import { BoundedCache } from './mask-cache';
import type { ExtractedDocument, MaskedImage, MediaMasker } from './media-client';

/** Разделитель частей значения кэша (ни base64, ни media_type его не содержат). */
const SEP = '\n';

/**
 * Вложения через media-masker с кэшем результата по sha256 исходных данных.
 * Кэш нужен, чтобы история с картинками не перегонялась через OCR на каждом запросе и чтобы
 * замаскированные байты были одинаковыми (иначе ломается кэш промпта Anthropic).
 */
export class MediaProcessor {
  private readonly cache = new BoundedCache(MEDIA_CACHE_MAX_CHARS);
  /** Сколько раз результат взят из кэша (для журнала и тестов). */
  cacheHits = 0;
  /** Сколько вызовов ушло в media-masker. */
  serviceCalls = 0;

  constructor(private readonly service: MediaMasker) {}

  /** Замаскировать картинку (base64). */
  async maskImage(mediaType: string, data: string): Promise<MaskedImage> {
    const key = cacheKey('image', mediaType, data);
    const hit = this.cache.get(key);
    if (hit !== undefined) {
      this.cacheHits++;
      const [type = '', payload = ''] = hit.split(SEP);
      return { mediaType: type, data: payload };
    }
    this.serviceCalls++;
    const r = await this.service.maskImage(mediaType, data);
    this.cache.set(key, `${r.mediaType}${SEP}${r.data}`);
    return r;
  }

  /** Разобрать PDF (base64): текстовый слой или замаскированные страницы-картинки. */
  async extractDocument(data: string): Promise<ExtractedDocument> {
    const key = cacheKey('pdf', 'application/pdf', data);
    const hit = this.cache.get(key);
    if (hit !== undefined) {
      this.cacheHits++;
      return JSON.parse(hit) as ExtractedDocument;
    }
    this.serviceCalls++;
    const r = await this.service.extractDocument(data);
    this.cache.set(key, JSON.stringify(r));
    return r;
  }
}

function cacheKey(kind: string, mediaType: string, data: string): string {
  return createHash('sha256').update(`${kind}\u0000${mediaType}\u0000${data}`).digest('hex');
}
