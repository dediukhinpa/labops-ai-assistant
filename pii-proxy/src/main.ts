import { loadConfig } from './config';
import { stderrLogger } from './log';
import { PiiProxy } from './proxy';

/** Точка входа: конфиг из окружения, запуск прокси. */
function main(): void {
  const config = loadConfig(process.env);
  const proxy = new PiiProxy(config, { logger: stderrLogger }).start();
  stderrLogger.log('started', { code: `port_${proxy.port}` });
  const stop = (): void => {
    void proxy.stop().then(() => process.exit(0));
  };
  process.on('SIGTERM', stop);
  process.on('SIGINT', stop);
}

main();
