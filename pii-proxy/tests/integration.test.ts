import { afterAll, beforeAll, describe, expect, test } from 'bun:test';
import { existsSync, readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { randomBytes } from 'node:crypto';
import { join } from 'node:path';
import { PiiProxy } from '../src/proxy';
import {
  memoryLogger, startFakeUpstream, testConfig, textStream, collectText, post,
} from './helpers';

/**
 * Сквозной тест на настоящем сервисе псевдонимизации - вендоренной labops-pii (профиль labops).
 * Python берётся из PII_TEST_PYTHON либо из venv, который строит pii-setup.sh host; без него
 * тест пропускается (как и при PII_SKIP_INTEGRATION=1). Корпус - tests/fixtures/pii_corpus.json
 * (снимок корпуса прежнего pseudonymizer/tests/pii_corpus.py).
 */
const REPO_DIR = join(import.meta.dir, '..', '..');
const LIB_DIR = join(REPO_DIR, 'vendor', 'labops-pii');
const DEFAULT_VENV_PYTHON = join(homedir(), 'labops-pii-runtime', 'labops-pii', '.venv', 'bin',
  'python');
const PYTHON = process.env.PII_TEST_PYTHON ?? DEFAULT_VENV_PYTHON;
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
    proc = Bun.spawn([PYTHON, '-m', 'labops_pii'], { cwd: LIB_DIR, stdout: 'ignore',
      stderr: 'ignore', env: { PATH: process.env.PATH ?? '', PYTHONPATH: LIB_DIR,
        PSEUDONYMIZER_API_TOKEN: token,
        // Маршруты, которые нужны прокси; так же их включает юнит pseudonymizer
        PSEUDONYMIZER_ENABLE_DELETE_THREADS: 'on', PSEUDONYMIZER_ENABLE_EXPOSE_BOOT_ID: 'on',
        PSEUDONYMIZER_ENABLE_CASE_LABELS: 'on',
        // Адреса маскируются по решению владельца; так же пишет pii-setup.sh
        PSEUDONYMIZER_ADDRESS_MASK: 'true',
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
      const corpus = JSON.parse(readFileSync(
        join(import.meta.dir, 'fixtures', 'pii_corpus.json'), 'utf8')) as Case[];
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

  test('адрес маскируется в [ADDRESS_N] и восстанавливается в ответе', async () => {
    const street = 'ул. Ленина, д. 5, кв. 12';
    const text = `Отправьте на г. Екатеринбург, ${street} до пятницы`;
    const upstream = startFakeUpstream(textStream(['']));
    upstream.replyFor = (hit) => {
      const body = JSON.parse(hit.body) as { messages: { content: string }[] };
      return textStream([body.messages.at(-1)?.content ?? '']);
    };
    const config = testConfig({ upstream: upstream.url, pseudonymizerUrl: serviceUrl,
      pseudonymizerToken: token, timeoutMs: 10_000 });
    const proxy = new PiiProxy(config, { logger: memoryLogger() }).start();
    try {
      const res = await post(`http://127.0.0.1:${proxy.port}`, '/v1/messages',
        { messages: [{ role: 'user', content: text }] },
        { 'x-claude-code-session-id': 'address-case' });
      expect(res.status).toBe(200);
      const hit = upstream.hits.at(-1)?.body ?? '';
      expect(hit).toContain('[ADDRESS_');
      expect(hit).not.toContain('Ленина');
      expect((await collectText(res)).text).toBe(text);
    } finally {
      await proxy.stop();
      await upstream.stop();
    }
  });
});
