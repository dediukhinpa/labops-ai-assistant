import { MAX_TEXT_CHARS, SERVICE_CONCURRENCY } from './constants';
import { collectStringLeaves, setLeaf } from './json-leaves';
import type { Pseudonymizer } from './pseudonymizer-client';
import { mapLimited, splitText } from './text-split';

/** Полный токен с необязательной падежной меткой. */
export const TOKEN_PATTERN = /\[([A-Z]+)_(\d+)(?:\|(nomn|gent|datv|accs|ablt|loct))?\]/g;

/** Восстановление оригиналов через /restore для одного треда; считает токены. */
export class Restorer {
  /** Сколько полных токенов встретилось в восстановленных текстах. */
  restoredTokens = 0;

  constructor(
    private readonly service: Pseudonymizer,
    private readonly threadId: string,
  ) {}

  /** Восстановить текст (без «]» токенов нет - вызов сервиса не нужен). */
  async text(text: string): Promise<string> {
    if (!text.includes(']')) return text;
    this.restoredTokens += text.match(TOKEN_PATTERN)?.length ?? 0;
    let out = '';
    for (const piece of splitText(text, MAX_TEXT_CHARS)) {
      out += piece.includes(']') ? await this.service.restore(this.threadId, piece) : piece;
    }
    return out;
  }

  /** Восстановить все строковые листья значения на месте. */
  async leaves(value: unknown): Promise<void> {
    const leaves = collectStringLeaves(value).filter((l) => l.text.includes(']'));
    const restored = await mapLimited(leaves, SERVICE_CONCURRENCY, (l) => this.text(l.text));
    leaves.forEach((leaf, i) => setLeaf(leaf, restored[i] as string));
  }
}
