import type { ImagePolicy } from './config';
import {
  CHECK_OVERLAP_CHARS,
  MASK_CACHE_MAX_CHARS,
  MAX_TEXT_CHARS,
  STATUS_PII_FOUND,
  SERVICE_CONCURRENCY,
  SYSTEM_INSERT_TEXT,
} from './constants';
import { RequestRejectedError } from './errors';
import { isObject, setLeaf, type JsonObject } from './json-leaves';
import { BoundedCache, BootTracker, maskCacheKey, textKey } from './mask-cache';
import type { Pseudonymizer } from './pseudonymizer-client';
import { RequestWalker } from './request-walker';
import { chunkBatches, mapLimited, splitText } from './text-split';

/** Предел числа записей кэша «текст проверен, ПДн нет» (стоимость 0, ключ - sha256). */
const CLEAN_CACHE_MAX_ENTRIES = 200_000;
const CLEAN_COST = 1;

/** Счётчики маскирования одного запроса (без значений). */
export interface MaskStats {
  readonly leaves: number;
  readonly cacheHits: number;
  readonly strippedAttachments: number;
}

/** Маскирует тело запроса к модели и проверяет результат второй линией (/check). */
export class RequestMasker {
  private readonly maskCache = new BoundedCache(MASK_CACHE_MAX_CHARS);
  private readonly cleanCache = new BoundedCache(CLEAN_CACHE_MAX_ENTRIES * CLEAN_COST, () => 0);
  private readonly boot: BootTracker;

  constructor(
    private readonly service: Pseudonymizer,
    private readonly imagePolicy: ImagePolicy,
  ) {
    this.boot = new BootTracker(service, () => this.maskCache.clear());
  }

  /** Размер кэша маскирования в символах (для тестов и метрик). */
  get cacheChars(): number {
    return this.maskCache.cost;
  }

  /**
   * Замаскировать тело на месте: листья, вложения, вставка в system.
   * @throws PseudonymizerError при сбое сервиса, RequestRejectedError при ПДн после маски.
   */
  async mask(body: JsonObject, threadId: string): Promise<MaskStats> {
    const walker = new RequestWalker(this.imagePolicy);
    walker.walk(body);
    const bootId = await this.boot.current();
    const keys = walker.leaves.map((l) => maskCacheKey(threadId, bootId, l.text));
    // Уже известные маски снимаем сразу: запись кэша может быть вытеснена новыми.
    const resolved = new Map<string, string>();
    // Новые листья: уникальные, в порядке первого появления.
    const missing: { key: string; text: string }[] = [];
    const seen = new Set<string>();
    let cacheHits = 0;
    walker.leaves.forEach((leaf, i) => {
      const key = keys[i] as string;
      const cached = this.maskCache.get(key);
      if (cached !== undefined) {
        resolved.set(key, cached);
        cacheHits++;
      } else if (!seen.has(key)) {
        seen.add(key);
        missing.push({ key, text: leaf.text });
      }
    });
    for (const [key, value] of await this.pseudonymizeMissing(threadId, missing)) {
      resolved.set(key, value);
      this.maskCache.set(key, value);
    }
    const maskedTexts: string[] = [];
    walker.leaves.forEach((leaf, i) => {
      const masked = resolved.get(keys[i] as string) as string;
      setLeaf(leaf, masked);
      maskedTexts.push(masked);
    });
    await this.secondLine(maskedTexts);
    insertSystemNote(body);
    return {
      leaves: walker.leaves.length,
      cacheHits,
      strippedAttachments: walker.strippedAttachments,
    };
  }

  /** Маскирует новые листья строго по порядку (порядок задаёт нумерацию токенов). */
  private async pseudonymizeMissing(
    threadId: string,
    missing: readonly { key: string; text: string }[],
  ): Promise<Map<string, string>> {
    const pieces: string[] = [];
    const owners: number[] = [];
    missing.forEach((m, i) => {
      for (const piece of splitText(m.text)) {
        pieces.push(piece);
        owners.push(i);
      }
    });
    const maskedPieces: string[] = [];
    for (const chunk of chunkBatches(pieces)) {
      maskedPieces.push(...(await this.service.pseudonymizeBatch(threadId, chunk)));
    }
    const joined = missing.map(() => '');
    maskedPieces.forEach((piece, i) => {
      joined[owners[i] as number] += piece;
    });
    return new Map(missing.map((m, i) => [m.key, joined[i] as string]));
  }

  /** Вторая линия: /check каждого замаскированного листа без thread_id. */
  private async secondLine(maskedTexts: readonly string[]): Promise<void> {
    const todo = [...new Set(maskedTexts)].filter((t) => this.cleanCache.get(textKey(t)) === undefined);
    const found = new Set<string>();
    await mapLimited(todo, SERVICE_CONCURRENCY, async (text) => {
      let dirty = false;
      for (const window of checkWindows(text)) {
        const r = await this.service.check(window);
        if (r.hasPii) {
          dirty = true;
          r.types.forEach((t) => found.add(t));
        }
      }
      if (!dirty) this.cleanCache.set(textKey(text), '1');
    });
    if (found.size > 0) {
      const types = [...found].sort();
      throw new RequestRejectedError(
        STATUS_PII_FOUND,
        `Запрос не отправлен: после маскирования в тексте остались персональные данные `
          + `(виды: ${types.join(', ')}).`,
        'pii_after_mask',
        types,
      );
    }
  }
}

/** Окна проверки длинного листа: не длиннее предела сервиса, соседние перекрываются. */
export function checkWindows(text: string): string[] {
  const step = MAX_TEXT_CHARS - CHECK_OVERLAP_CHARS;
  const windows: string[] = [];
  for (let start = 0; ; start += step) {
    windows.push(text.slice(start, start + MAX_TEXT_CHARS));
    if (start + MAX_TEXT_CHARS >= text.length) return windows;
  }
}

/**
 * Добавляет в конец system неизменную вставку про токены. Строка system превращается в
 * список блоков; cache_control у блоков списка не трогается.
 */
export function insertSystemNote(body: JsonObject): void {
  const note: JsonObject = { type: 'text', text: SYSTEM_INSERT_TEXT };
  const system = body.system;
  if (typeof system === 'string') {
    body.system = system === '' ? [note] : [{ type: 'text', text: system }, note];
  } else if (Array.isArray(system)) {
    system.push(note);
  } else if (system === undefined || system === null) {
    body.system = [note];
  } else if (isObject(system)) {
    body.system = [system, note];
  }
}
