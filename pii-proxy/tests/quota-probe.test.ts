import { afterEach, describe, expect, test } from 'bun:test';
import { SYSTEM_INSERT_TEXT } from '@labops/pii';
import { startRig, post, textStream, type Rig } from './helpers';

/**
 * Первый запрос каждой сессии Claude Code под подпиской - служебная проба квоты: без system,
 * max_tokens 1, единственное сообщение «quota». Через прокси эта проба стабильно получала 429:
 * маскер дописывал в неё system-вставку про токены, и запрос переставал быть тем, что шлёт сам
 * claude. Пробе нечего маскировать, поэтому она идёт в upstream без изменений.
 */
const DICT = { 'Иван Петров': '[PERSON_1]' };
let rig: Rig;
afterEach(async () => { await rig.stop(); });

function probeBody(over: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    model: 'claude-sonnet-5-5',
    max_tokens: 1,
    messages: [{ role: 'user', content: 'quota' }],
    metadata: { user_id: '{"device_id":"abc","account_uuid":"","session_id":"s"}' },
    ...over,
  };
}

describe('проба квоты claude', () => {
  test('уходит в upstream без system-вставки и без обращения к сервису', async () => {
    rig = startRig(DICT, textStream(['ок']));
    const body = probeBody();
    const res = await post(rig.base, '/v1/messages', body, { 'x-claude-code-session-id': 's1' });
    expect(res.status).toBe(200);
    await res.text(); // запись 'request' пишется по концу потока
    expect(JSON.parse(rig.upstream.hits[0]?.body ?? '{}')).toEqual(body);
    expect(rig.service.state.batches).toEqual([]);
    const events = rig.logger.lines.filter((l) => l.event === 'request');
    expect(events[0]?.fields).toMatchObject({ status: 200, masked_leaves: 0 });
  });

  test.each([
    ['со своим system', probeBody({ system: 'Инструкция' })],
    ['с max_tokens больше 1', probeBody({ max_tokens: 64 })],
    ['с другим текстом', probeBody({ messages: [{ role: 'user', content: 'quota Иван Петров' }] })],
    ['с инструментами', probeBody({ tools: [{ name: 't', description: 'd' }] })],
    ['с двумя сообщениями', probeBody({ messages: [
      { role: 'user', content: 'quota' }, { role: 'assistant', content: 'ok' }] })],
  ])('обычный запрос %s маскируется как раньше', async (_name, body) => {
    rig = startRig(DICT, textStream(['ок']));
    const res = await post(rig.base, '/v1/messages', body, { 'x-claude-code-session-id': 's2' });
    expect(res.status).toBe(200);
    const sent = JSON.parse(rig.upstream.hits[0]?.body ?? '{}');
    expect(JSON.stringify(sent.system)).toContain(SYSTEM_INSERT_TEXT.slice(0, 20));
    expect(rig.service.state.batches.length).toBeGreaterThan(0);
  });
});

describe('отказ upstream', () => {
  test('429 доходит клиенту как есть, в журнале - диагностика без тела и текстов', async () => {
    rig = startRig(DICT, {
      status: 429,
      contentType: 'application/json',
      headers: {
        'request-id': 'req_011TEST',
        'retry-after': '17',
        'anthropic-ratelimit-unified-status': 'rejected',
        'set-cookie': 'secret=1',
      },
      chunks: [JSON.stringify({ type: 'error', error: { type: 'rate_limit_error',
        message: 'Иван Петров превысил лимит' } })],
    });
    const res = await post(rig.base, '/v1/messages', probeBody(),
      { 'x-claude-code-session-id': 's3' });
    expect(res.status).toBe(429);
    expect(await res.json()).toMatchObject({ error: { type: 'rate_limit_error' } });
    const line = rig.logger.lines.find((l) => l.event === 'upstream_error');
    expect(line?.fields).toMatchObject({ route: '/v1/messages', status: 429,
      upstream_error_type: 'rate_limit_error', probe: true,
      upstream_headers: { 'request-id': 'req_011TEST', 'retry-after': '17',
        'anthropic-ratelimit-unified-status': 'rejected' } });
    const dump = JSON.stringify(line);
    expect(dump).not.toContain('secret');
    expect(dump).not.toContain('Иван');
  });

  test('успешный ответ записи upstream_error не даёт', async () => {
    rig = startRig(DICT, textStream(['ок']));
    await post(rig.base, '/v1/messages', probeBody());
    expect(rig.logger.lines.some((l) => l.event === 'upstream_error')).toBe(false);
  });
});
