import { afterAll, beforeAll, describe, expect, test } from 'bun:test';
import { existsSync } from 'node:fs';
import { randomBytes } from 'node:crypto';
import { join } from 'node:path';
import { PiiProxy } from '../src/proxy';
import {
  memoryLogger, startFakeUpstream, testConfig, textStream, collectText, post,
} from './helpers';

/**
 * Сквозной тест на настоящем сервисе псевдонимизации. Пропускается, если нет
 * pseudonymizer/.venv (python3.12 -m venv .venv && .venv/bin/pip install -e ".[dev]")
 * или задано PII_SKIP_INTEGRATION=1.
 */
const SERVICE_DIR = join(import.meta.dir, '..', '..', 'pseudonymizer');
const PYTHON = join(SERVICE_DIR, '.venv', 'bin', 'python');
const RUN = existsSync(PYTHON) && process.env.PII_SKIP_INTEGRATION !== '1';
const BOOT_WAIT_MS = 120_000;
const MIN_DIGITS_TAIL = 10;

interface Case { text: string; kind: string }

/** Только цифры текста (NFKC приводит полноширинные к ASCII). */
function digitsOf(s: string): string {
  return s.normalize('NFKC').replace(/\D/g, '');
}

/** Значение ПДн, которое не должно уйти наружу: хвост цифр либо адрес почты. */
function secretOf(c: Case): { digits?: string; email?: string } {
  const norm = c.text.normalize('NFKC');
  const email = /[^\s@]+@[^\s]+/.exec(norm);
  if (c.kind === 'email' && email !== null) return { email: email[0].toLowerCase() };
  const d = digitsOf(c.text);
  return { digits: d.slice(-MIN_DIGITS_TAIL) };
}

let proc: ReturnType<typeof Bun.spawn> | undefined;
let serviceUrl = '';
const token = randomBytes(16).toString('hex');

async function freePort(): Promise<number> {
  const s = Bun.serve({ port: 0, hostname: '127.0.0.1', fetch: () => new Response('') });
  const port = s.port ?? 0;
  await s.stop(true);
  return port;
}

describe.skipIf(!RUN)('сквозной тест с настоящим сервисом', () => {
  beforeAll(async () => {
    const port = await freePort();
    serviceUrl = `http://127.0.0.1:${port}`;
    proc = Bun.spawn([PYTHON, '-m', 'pseudonymizer'], { cwd: SERVICE_DIR, stdout: 'ignore',
      stderr: 'ignore', env: { PATH: process.env.PATH ?? '', PSEUDONYMIZER_API_TOKEN: token,
        PSEUDONYMIZER_PORT: String(port), PSEUDONYMIZER_HOST: '127.0.0.1' } });
    const until = Date.now() + BOOT_WAIT_MS;
    for (;;) {
      try {
        if ((await fetch(`${serviceUrl}/health`)).ok) break;
      } catch { /* ещё не поднялся */ }
      if (Date.now() > until) throw new Error('сервис не поднялся');
      await Bun.sleep(300);
    }
  }, BOOT_WAIT_MS + 5_000);

  afterAll(() => { proc?.kill(); });

  test('в upstream не доходит ни одного значения корпуса, ответ возвращается с оригиналами',
    async () => {
      const dump = Bun.spawn([PYTHON, '-I', '-c',
        'import sys,json;sys.path.insert(0,".");from tests.pii_corpus import POSITIVE;'
        + 'print(json.dumps([{"text":t,"kind":k} for t,k in POSITIVE]))'],
      { cwd: SERVICE_DIR, stdout: 'pipe' });
      const corpus = JSON.parse(await new Response(dump.stdout).text()) as Case[];
      expect(corpus.length).toBeGreaterThan(40);

      const upstream = startFakeUpstream(textStream(['']));
      // Эхо: модель повторяет последнее (замаскированное) сообщение пользователя.
      upstream.replyFor = (hit) => {
        const body = JSON.parse(hit.body) as { messages: { content: string }[] };
        return textStream([body.messages.at(-1)?.content ?? '']);
      };
      const config = testConfig({ upstream: upstream.url, pseudonymizerUrl: serviceUrl,
        pseudonymizerToken: token, timeoutMs: 10_000 });
      const proxy = new PiiProxy(config, { logger: memoryLogger() }).start();
      const base = `http://127.0.0.1:${proxy.port}`;
      let forwarded = 0;
      let blocked = 0;
      try {
        for (const [i, c] of corpus.entries()) {
          const res = await post(base, '/v1/messages',
            { messages: [{ role: 'user', content: c.text }] },
            { 'x-claude-code-session-id': `corpus-${i}` });
          if (res.status === 422) {
            blocked++; // вторая линия остановила: наружу ничего не ушло
            await res.text();
            continue;
          }
          expect(res.status).toBe(200);
          const hit = upstream.hits.at(-1)?.body ?? '';
          const secret = secretOf(c);
          if (secret.email !== undefined) expect(hit.toLowerCase()).not.toContain(secret.email);
          if (secret.digits !== undefined) expect(digitsOf(hit)).not.toContain(secret.digits);
          const { text } = await collectText(res);
          expect(text).toBe(c.text);
          forwarded++;
        }
      } finally {
        await proxy.stop();
        await upstream.stop();
      }
      expect(forwarded + blocked).toBe(corpus.length);
      // Основная масса корпуса маскируется, а не блокируется.
      expect(forwarded).toBeGreaterThan(corpus.length / 2);
      console.log(`корпус: ${forwarded} замаскировано и возвращено, ${blocked} заблокировано`);
    }, 300_000);
});
