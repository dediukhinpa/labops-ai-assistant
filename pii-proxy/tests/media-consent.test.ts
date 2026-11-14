import { afterEach, beforeEach, describe, expect, test } from 'bun:test';
import { mkdirSync, mkdtempSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { CONSENT_TTL_MS, consentOfferText, mediaFingerprint, mediaIdOf } from '@labops/pii';
import { loadConfig } from '../src/config';
import { fakeMaskedData, post, startRig, textStream, type Rig } from './helpers';

const AGENT = 'dev'; // agentId из testConfig
const BASE_ENV = {
  PII_PROXY_PORT: '0', PII_PROXY_AGENT_ID: AGENT, PSEUDONYMIZER_API_TOKEN: 't',
  MEDIA_MASKER_API_TOKEN: 'm',
};
// Синтетические байты «картинки», настоящих ПДн нет
const ORIGINAL = Buffer.from('synthetic-original-image-bytes').toString('base64');
const OTHER = Buffer.from('another-image-bytes').toString('base64');
const SHA = mediaFingerprint(ORIGINAL);

let rig: Rig;
let started = false;
let dir: string;

beforeEach(() => { dir = mkdtempSync(join(tmpdir(), 'proxy-consent-')); });
afterEach(async () => {
  if (started) await rig.stop();
  started = false;
  rmSync(dir, { recursive: true, force: true });
});

const consentRig = (): Rig => {
    const r = startRig({}, textStream(['ок']), { imagePolicy: 'mask', mediaConsentDir: dir });
  r.media.state.stats = { pii_kinds: ['PHONE', 'PERSON'] };
  rig = r;
  started = true;
  return r;
};
const image = (data: string): Record<string, unknown> =>
  ({ type: 'image', source: { type: 'base64', media_type: 'image/png', data } });
const body = (...data: string[]): unknown =>
  ({ messages: [{ role: 'user', content: data.map(image) }] });
const sent = (r: Rig): Record<string, any> => JSON.parse(r.upstream.hits[0]?.body ?? '{}');

/** Файл разрешения так, как его пишет канал мессенджера. */
function approve(sha256: string, now = Date.now(), over: Record<string, unknown> = {}): void {
  writeFileSync(join(dir, `${sha256}.json`), JSON.stringify({
    sha256, agent: AGENT, kinds: ['PHONE'], approved_by: 1,
    approved_at: new Date(now).toISOString(),
    expires_at: new Date(now + CONSENT_TTL_MS).toISOString(), ...over,
  }));
}

describe('PII_PROXY_MEDIA_CONSENT: конфиг', () => {
  test('по умолчанию выключено', () => {
    expect(loadConfig(BASE_ENV).mediaConsentDir).toBeUndefined();
  });
  test('true включает функцию, каталог по умолчанию в ~/.config/labops-pii/consent', () => {
    const cfg = loadConfig({ ...BASE_ENV, PII_PROXY_MEDIA_CONSENT: 'true' });
    expect(cfg.mediaConsentDir).toMatch(/\.config\/labops-pii\/consent$/);
  });
  test('каталог можно задать, мусор - ошибка', () => {
    expect(loadConfig({ ...BASE_ENV, PII_PROXY_MEDIA_CONSENT: 'true',
      PII_PROXY_MEDIA_CONSENT_DIR: '/x/y' }).mediaConsentDir).toBe('/x/y');
    expect(() => loadConfig({ ...BASE_ENV, PII_PROXY_MEDIA_CONSENT: 'maybe' }))
      .toThrow(/MEDIA_CONSENT/);
  });
});

describe('оригинал вложения по разрешению владельца', () => {
  test('нет разрешения: закрашенная версия, текст про запрос разрешения, предложение записано', async () => {
    consentRig();
    const res = await post(rig.base, '/v1/messages', body(ORIGINAL));
    expect(res.status).toBe(200);
    const raw = rig.upstream.hits[0]?.body ?? '';
    expect(raw).not.toContain(ORIGINAL);
    const content = sent(rig).messages[0].content;
    expect(content[0].source.data).toBe(fakeMaskedData(ORIGINAL));
    expect(content[1].text).toBe(consentOfferText(mediaIdOf(SHA), ['PERSON', 'PHONE']));
    expect(readdirSync(join(dir, 'offers'))).toEqual([`${mediaIdOf(SHA)}.json`]);
  });

  test('есть действующее разрешение: уходит оригинал, media-masker не вызван, событие в журнале', async () => {
    consentRig();
    approve(SHA);
    const res = await post(rig.base, '/v1/messages', body(ORIGINAL));
    expect(res.status).toBe(200);
    await res.text(); // ответ дочитан: журнал запроса пишется по завершении потока
    const content = sent(rig).messages[0].content;
    expect(content).toHaveLength(1);
    expect(content[0].source.data).toBe(ORIGINAL);
    expect(rig.media.state.calls).toEqual([]);
    const ev = rig.logger.lines.filter((l) => l.event === 'consent_original_sent');
    expect(ev).toHaveLength(1);
    expect(ev[0]?.fields.media_id).toBe(mediaIdOf(SHA));
    expect(JSON.stringify(rig.logger.lines)).not.toContain(ORIGINAL);
    const req = rig.logger.lines.find((l) => l.event === 'request');
    expect(req?.fields.consent_originals).toBe(1);
  });

  test('разрешение просрочено: снова закрашенная версия', async () => {
    consentRig();
    approve(SHA, Date.now() - CONSENT_TTL_MS - 5_000);
    await post(rig.base, '/v1/messages', body(ORIGINAL));
    expect(sent(rig).messages[0].content[0].source.data).toBe(fakeMaskedData(ORIGINAL));
    expect(rig.logger.lines.some((l) => l.event === 'consent_original_sent')).toBe(false);
  });

  test('отпечаток не совпал (разрешён другой файл): закрашенная версия', async () => {
    consentRig();
    approve(mediaFingerprint(OTHER));
    await post(rig.base, '/v1/messages', body(ORIGINAL));
    expect(sent(rig).messages[0].content[0].source.data).toBe(fakeMaskedData(ORIGINAL));
  });

  test('разрешение другого агента не действует', async () => {
    consentRig();
    approve(SHA, Date.now(), { agent: 'someone-else' });
    await post(rig.base, '/v1/messages', body(ORIGINAL));
    expect(sent(rig).messages[0].content[0].source.data).toBe(fakeMaskedData(ORIGINAL));
  });

  test('разрешение на один файл не открывает второй в том же запросе', async () => {
    consentRig();
    approve(SHA);
    await post(rig.base, '/v1/messages', body(ORIGINAL, OTHER));
    const content = sent(rig).messages[0].content;
    expect(content[0].source.data).toBe(ORIGINAL);
    expect(content[1].source.data).toBe(fakeMaskedData(OTHER));
  });

  test('без mediaConsentDir функция выключена: файлы разрешений игнорируются, текста нет', async () => {
    rig = startRig({}, textStream(['ок']), { imagePolicy: 'mask' });
    started = true;
    rig.media.state.stats = { pii_kinds: ['PHONE'] };
    mkdirSync(dir, { recursive: true });
    approve(SHA);
    await post(rig.base, '/v1/messages', body(ORIGINAL));
    const content = sent(rig).messages[0].content;
    expect(content).toHaveLength(1);
    expect(content[0].source.data).toBe(fakeMaskedData(ORIGINAL));
  });

  test('на вложении нет находок: текста про разрешение нет', async () => {
    consentRig();
    rig.media.state.stats = { pii_kinds: [] };
    await post(rig.base, '/v1/messages', body(ORIGINAL));
    expect(sent(rig).messages[0].content).toHaveLength(1);
  });
});
