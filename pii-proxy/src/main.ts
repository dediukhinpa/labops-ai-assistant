import { appendFileSync } from 'node:fs';
import { loadConfig } from './config';
import { stderrLogger } from './stderr-logger';
import { PiiProxy } from './proxy';
import type { StuckSignal } from './session-stuck';

/** Точка входа: конфиг из окружения, запуск прокси. */
function main(): void {
  const config = loadConfig(process.env);
  const alertFile = config.alertFile;
  // Событие для watchdog: он шлёт оператору алерт. Только отпечаток сессии, счётчик и код.
  const onStuck = alertFile === undefined ? undefined : (s: StuckSignal): void => {
    try {
      appendFileSync(alertFile, `${JSON.stringify({ ts: new Date().toISOString(), ...s })}\n`);
    } catch {
      stderrLogger.log('alert_file_failed', { code: 'append' });
    }
  };
  const proxy = new PiiProxy(config, {
    logger: stderrLogger,
    ...(onStuck !== undefined ? { onStuck } : {}),
  }).start();
  stderrLogger.log('started', { code: `port_${proxy.port}` });
  const stop = (): void => {
    void proxy.stop().then(() => process.exit(0));
  };
  process.on('SIGTERM', stop);
  process.on('SIGINT', stop);
}

main();
