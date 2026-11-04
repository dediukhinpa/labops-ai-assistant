import { afterEach, describe, expect, test } from 'bun:test';
import { loadConfig } from '../src/config';
import { SYSTEM_INSERT_TEXT } from '../src/constants';
import { maskCacheKey } from '../src/mask-cache';
import { HttpPseudonymizer } from '../src/pseudonymizer-client';
import { startFakeService, startRig, post, textStream, TEST_TOKEN, type Rig } from './helpers';

const BASE_ENV = {
  PII_PROXY_PORT: '6300', PII_PROXY_AGENT_ID: 'dev', PSEUDONYMIZER_API_TOKEN: 'x',
};

describe('PII_PROXY_CASE_LABELS: конфиг', () => {
  test('по умолчанию включено', () => {
    expect(loadConfig(BASE_ENV).caseLabels).toBe(true);
  });
  test('false выключает, мусор - ошибка', () => {
    expect(loadConfig({ ...BASE_ENV, PII_PROXY_CASE_LABELS: 'false' }).caseLabels).toBe(false);
    expect(() => loadConfig({ ...BASE_ENV, PII_PROXY_CASE_LABELS: 'maybe' }))
      .toThrow(/CASE_LABELS/);
  });
});

describe('клиент сервиса: case_labels', () => {
  const services: ReturnType<typeof startFakeService>[] = [];
  afterEach(async () => { await Promise.all(services.splice(0).map((s) => s.stop())); });

  async function sentBody(caseLabels: boolean | undefined): Promise<Record<string, unknown>> {
    const service = startFakeService();
    services.push(service);
    const client = new HttpPseudonymizer({
      baseUrl: service.url, token: TEST_TOKEN, timeoutMs: 1_000,
      ...(caseLabels === undefined ? {} : { caseLabels }),
    });
    await client.pseudonymizeBatch('t', ['текст']);
    return service.state.batchBodies[0] as Record<string, unknown>;
  }

  test('true: флаг уходит в запрос', async () => {
    expect(await sentBody(true)).toEqual({ thread_id: 't', texts: ['текст'], case_labels: true });
  });
  test('false и не задан: поле не отправляется (совместимость со старым сервисом)', async () => {
    expect(await sentBody(false)).toEqual({ thread_id: 't', texts: ['текст'] });
    expect(await sentBody(undefined)).toEqual({ thread_id: 't', texts: ['текст'] });
  });
});

describe('ключ кэша маскирования', () => {
  test('различается по флагу, при false прежний', () => {
    const off = maskCacheKey('t', 'boot', 'текст');
    expect(maskCacheKey('t', 'boot', 'текст', false)).toBe(off);
    expect(maskCacheKey('t', 'boot', 'текст', true)).not.toBe(off);
  });
});

describe('прокси с падежными метками', () => {
  let rig: Rig;
  afterEach(async () => { await rig.stop(); });

  test('флаг конфига доходит до сервиса при маскировании запроса', async () => {
    rig = startRig({ 'Иван Петров': '[PERSON_1]' }, textStream(['ок']), { caseLabels: true });
    const body = { model: 'm', messages: [{ role: 'user', content: 'Иван Петров' }] };
    expect((await post(rig.base, '/v1/messages', body)).status).toBe(200);
    expect(rig.service.state.batches[0]?.caseLabels).toBe(true);
  });

  test('с выключенным флагом поле в сервис не уходит', async () => {
    rig = startRig({ 'Иван Петров': '[PERSON_1]' }, textStream(['ок']), { caseLabels: false });
    const body = { model: 'm', messages: [{ role: 'user', content: 'Иван Петров' }] };
    await post(rig.base, '/v1/messages', body);
    expect(rig.service.state.batchBodies[0]).not.toHaveProperty('case_labels');
  });
});

describe('вставка в system', () => {
  test('объясняет метку во входе и не противоречит правилу для ответа', () => {
    expect(SYSTEM_INSERT_TEXT).toContain('[PERSON_1|datv]');
    expect(SYSTEM_INSERT_TEXT).toContain('падеж, в котором имя стояло в исходном тексте');
  });
});
