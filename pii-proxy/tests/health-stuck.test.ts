import { afterEach, describe, expect, test } from 'bun:test';
import { STUCK_FAILURE_THRESHOLD, SESSION_HEADER } from '../src/proxy-constants';
import { SessionStuckTracker } from '../src/session-stuck';
import { PiiProxy } from '../src/proxy';
import { PseudonymizerHealth } from '../src/pseudonymizer-health';
import type { Pseudonymizer } from '@labops/pii';
import {
  memoryLogger, startFakeService, startFakeUpstream, testConfig, textStream,
  type FakeService, type FakeUpstream,
} from './helpers';

describe('SessionStuckTracker', () => {
  test('сигнал на пороге, не чаще раза в интервал, успех обнуляет серию', () => {
    let now = 0;
    const t = new SessionStuckTracker(3, 1_000, () => now);
    expect(t.recordFailure('s', 'a')).toBeUndefined();
    expect(t.recordFailure('s', 'a')).toBeUndefined();
    expect(t.recordFailure('s', 'a')?.count).toBe(3);
    // следующий отказ внутри интервала - без повторного сигнала
    expect(t.recordFailure('s', 'a')).toBeUndefined();
    now = 1_500;
    expect(t.recordFailure('s', 'a')?.count).toBe(5);
    t.recordSuccess('s');
    now = 10_000;
    expect(t.recordFailure('s', 'a')).toBeUndefined();
  });

  test('сессии считаются раздельно', () => {
    const t = new SessionStuckTracker(2, 1_000, () => 0);
    expect(t.recordFailure('a', 'x')).toBeUndefined();
    expect(t.recordFailure('b', 'x')).toBeUndefined();
    expect(t.recordFailure('a', 'x')?.session).toBe('a');
  });
});

describe('прокси: /health и session_stuck', () => {
  let service: FakeService;
  let upstream: FakeUpstream;
  afterEach(async () => { await service.stop(); await upstream.stop(); });

  test('/health отвечает без токена и не ходит в upstream', async () => {
    service = startFakeService();
    upstream = startFakeUpstream(textStream(['ок']));
    const logger = memoryLogger();
    const cfg = testConfig({ upstream: upstream.url, pseudonymizerUrl: service.url });
    const proxy = new PiiProxy(cfg, { logger }).start();
    const res = await fetch(`http://127.0.0.1:${proxy.port}/health`);
    expect(res.status).toBe(200);
    expect(upstream.hits.length).toBe(0);
    await proxy.stop();
  });

  test('/health при живом сервисе: 200 и status ok, как раньше', async () => {
    service = startFakeService();
    upstream = startFakeUpstream(textStream(['ок']));
    const cfg = testConfig({ upstream: upstream.url, pseudonymizerUrl: service.url });
    const proxy = new PiiProxy(cfg, { logger: memoryLogger() }).start();
    const res = await fetch(`http://127.0.0.1:${proxy.port}/health`);
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ status: 'ok', pseudonymizer: 'ok' });
    await proxy.stop();
  });

  test('/health при мёртвом сервисе: 503 с причиной, без обращения к upstream', async () => {
    service = startFakeService();
    upstream = startFakeUpstream(textStream(['ок']));
    const deadService = startFakeService();
    const deadUrl = deadService.url;
    await deadService.stop();
    const cfg = testConfig({ upstream: upstream.url, pseudonymizerUrl: deadUrl });
    const proxy = new PiiProxy(cfg, { logger: memoryLogger() }).start();
    const res = await fetch(`http://127.0.0.1:${proxy.port}/health`);
    expect(res.status).toBe(503);
    expect(await res.json()).toEqual({
      status: 'degraded', pseudonymizer: 'down', reason: 'pseudonymizer_unavailable',
    });
    expect(upstream.hits.length).toBe(0);
    await proxy.stop();
  });

  test('/health: сервис отвечает 500 — тоже недоступен', async () => {
    service = startFakeService();
    service.state.mode = 'http500';
    upstream = startFakeUpstream(textStream(['ок']));
    const cfg = testConfig({ upstream: upstream.url, pseudonymizerUrl: service.url });
    const proxy = new PiiProxy(cfg, { logger: memoryLogger() }).start();
    const res = await fetch(`http://127.0.0.1:${proxy.port}/health`);
    expect(res.status).toBe(503);
    await proxy.stop();
  });

  test('N отказов 503 подряд в сессии - одно событие session_stuck без ПДн', async () => {
    service = startFakeService({ 'Иван Петров': '[PERSON_1]' });
    service.state.mode = 'http500';
    upstream = startFakeUpstream(textStream(['ок']));
    const logger = memoryLogger();
    const signals: unknown[] = [];
    const cfg = testConfig({ upstream: upstream.url, pseudonymizerUrl: service.url });
    const proxy = new PiiProxy(cfg, { logger, onStuck: (s) => void signals.push(s) }).start();
    for (let i = 0; i < STUCK_FAILURE_THRESHOLD + 2; i++) {
      const res = await fetch(`http://127.0.0.1:${proxy.port}/v1/messages`, {
        method: 'POST',
        headers: { 'content-type': 'application/json', [SESSION_HEADER]: 'sess-1' },
        body: JSON.stringify({ model: 'm', messages: [{ role: 'user', content: 'Иван Петров' }] }),
      });
      expect(res.status).toBe(503);
    }
    expect(signals.length).toBe(1);
    const events = logger.lines.filter((l) => l.event === 'session_stuck');
    expect(events.length).toBe(1);
    expect(JSON.stringify(events)).not.toContain('Иван');
    expect(upstream.hits.length).toBe(0);
    await proxy.stop();
  });
});

/** Подмена сервиса: health() по сценарию, счётчик вызовов. */
function scriptedService(
  health: () => Promise<string>,
): { service: Pseudonymizer; calls: () => number } {
  let n = 0;
  const unused = (): Promise<never> => Promise.reject(new Error('не нужен'));
  const service: Pseudonymizer = {
    health: () => { n++; return health(); },
    pseudonymizeBatch: unused, restore: unused, check: unused, deleteThread: unused,
  };
  return { service, calls: () => n };
}

describe('PseudonymizerHealth', () => {
  test('кэш: повтор в пределах окна не ходит в сервис, после окна — ходит', async () => {
    let now = 0;
    const s = scriptedService(() => Promise.resolve('boot'));
    const h = new PseudonymizerHealth(s.service, 1_000, 500, () => now);
    expect(await h.state()).toBe('ok');
    now = 999;
    expect(await h.state()).toBe('ok');
    expect(s.calls()).toBe(1);
    now = 1_000;
    expect(await h.state()).toBe('ok');
    expect(s.calls()).toBe(2);
  });

  test('ошибка сервиса — down; восстановление видно после окна кэша', async () => {
    let now = 0;
    let fail = true;
    const s = scriptedService(() => (fail ? Promise.reject(new Error('x')) : Promise.resolve('b')));
    const h = new PseudonymizerHealth(s.service, 1_000, 500, () => now);
    expect(await h.state()).toBe('down');
    fail = false;
    expect(await h.state()).toBe('down');
    now = 2_000;
    expect(await h.state()).toBe('ok');
  });

  test('зависший сервис — down по таймауту, параллельные запросы делят одну проверку', async () => {
    const s = scriptedService(() => new Promise<string>(() => undefined));
    const h = new PseudonymizerHealth(s.service, 1_000, 50);
    const started = performance.now();
    const states = await Promise.all([h.state(), h.state(), h.state()]);
    expect(states).toEqual(['down', 'down', 'down']);
    expect(performance.now() - started).toBeLessThan(1_000);
    expect(s.calls()).toBe(1);
  });
});
