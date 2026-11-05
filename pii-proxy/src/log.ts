import { createHash } from 'node:crypto';
import { SESSION_HASH_CHARS } from './constants';

/** Поля записи журнала: только коды и счётчики, никаких текстов. */
export interface LogFields {
  readonly route?: string;
  readonly status?: number;
  readonly duration_ms?: number;
  readonly code?: string;
  readonly session?: string;
  readonly masked_leaves?: number;
  readonly cache_hits?: number;
  readonly remembered_leaves?: number;
  readonly forgotten_leaves?: number;
  readonly restored_tokens?: number;
  readonly pii_types?: readonly string[];
}

/** Приёмник журнала (в тестах подменяется). */
export interface Logger {
  log(event: string, fields?: LogFields): void;
}

/** Журнал в stderr: одна JSON-строка на событие. */
export const stderrLogger: Logger = {
  log(event: string, fields: LogFields = {}): void {
    process.stderr.write(`${JSON.stringify({ ts: new Date().toISOString(), event, ...fields })}\n`);
  },
};

/** Журнал-пустышка. */
export const nullLogger: Logger = { log(): void {} };

/** Короткий отпечаток session id для журнала (сам id не пишется). */
export function sessionFingerprint(sessionId: string): string {
  return createHash('sha256').update(sessionId).digest('hex').slice(0, SESSION_HASH_CHARS);
}
