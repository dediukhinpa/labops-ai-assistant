import { describe, expect, test } from 'bun:test';
import { loadConfig } from '../src/config';

// Деление текста, буфер границы токена, кэш и SSE переехали в ts/tests библиотеки @labops/pii
describe('конфиг', () => {
  const base = { PII_PROXY_PORT: '6300', PII_PROXY_AGENT_ID: 'dev', PSEUDONYMIZER_API_TOKEN: 'x',
    MEDIA_MASKER_API_TOKEN: 'm' };
  test('значения по умолчанию', () => {
    const c = loadConfig(base);
    expect(c.host).toBe('127.0.0.1');
    expect(c.upstream).toBe('https://api.anthropic.com');
    expect(c.imagePolicy).toBe('mask');
    expect(c.timeoutMs).toBe(10_000);
  });
  test('mask без токена media-masker - ошибка (fail closed)', () => {
    const { MEDIA_MASKER_API_TOKEN: _t, ...noToken } = base;
    expect(() => loadConfig(noToken)).toThrow(/MEDIA_MASKER_API_TOKEN/);
    expect(loadConfig({ ...noToken, PII_PROXY_IMAGE_POLICY: 'strip' }).imagePolicy).toBe('strip');
  });
  test('нет обязательных - ошибка без значений', () => {
    expect(() => loadConfig({ PII_PROXY_PORT: '1' })).toThrow(/AGENT_ID/);
    try {
      loadConfig({ ...base, PSEUDONYMIZER_API_TOKEN: '', PII_PROXY_IMAGE_POLICY: 'bad' });
    } catch (e) {
      expect(String(e)).not.toContain('bad');
    }
  });
});
