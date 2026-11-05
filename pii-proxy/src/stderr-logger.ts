import type { LogFields, Logger } from '@labops/pii';

/** Журнал в stderr: одна JSON-строка на событие. */
export const stderrLogger: Logger = {
  log(event: string, fields: LogFields = {}): void {
    process.stderr.write(`${JSON.stringify({ ts: new Date().toISOString(), event, ...fields })}\n`);
  },
};
