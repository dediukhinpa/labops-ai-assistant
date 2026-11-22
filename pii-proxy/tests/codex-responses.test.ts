import { afterEach, describe, expect, test } from 'bun:test';
import { post, sse, startRig, type Rig } from './helpers';

/**
 * Маршрут Codex CLI: OpenAI Responses через бэкенд ChatGPT (`/backend-api/codex/responses`).
 * Форма запроса и событий — как в живом трафике Codex 0.171.0 (22.11.2026).
 */
const DICT = { 'Иван Петров': '[PERSON_1]', '+7 913 555-12-34': '[PHONE_1]' };
const ROUTE = '/backend-api/codex/responses';
// Заголовка сессии Claude у Codex нет: post() подставляет его по умолчанию — гасим пустым.
const CODEX_HEADERS = {
  'x-claude-code-session-id': '', 'thread-id': 'thread-abc', 'session-id': 'thread-abc',
};

let rig: Rig;
afterEach(async () => { await rig.stop(); });

/** Запрос как у Codex: developer-сообщения, пользователь, история с вызовом инструмента. */
function codexRequest(): Record<string, unknown> {
  return {
    model: 'gpt-6.2-sol',
    stream: true,
    store: false,
    input: [
      { type: 'additional_tools', role: 'developer', tools: [{ type: 'custom', name: 'exec' }] },
      { type: 'message', role: 'developer', content: [{ type: 'input_text', text: 'Ты Codex.' }] },
      { type: 'message', role: 'user', content: [
        { type: 'input_text', text: 'Позвони Иван Петров, тел. +7 913 555-12-34' },
      ] },
      { type: 'custom_tool_call', call_id: 'c1', name: 'exec',
        input: 'text("Иван Петров, +7 913 555-12-34")' },
      { type: 'custom_tool_call_output', call_id: 'c1', output: [
        { type: 'input_text', text: 'Иван Петров, +7 913 555-12-34' },
      ] },
      { type: 'reasoning', summary: [], encrypted_content: 'gAAAA-opaque' },
    ],
  };
}

/** Поток ответа как у бэкенда ChatGPT: текст с разрезанным токеном и код инструмента кусками. */
function codexStream(): string[] {
  const base = { item_id: 'msg_1', output_index: 0, content_index: 0 };
  const code = 'text("[PERSON_1] [PHONE_1]")';
  return [
    sse('response.created', { type: 'response.created', response: { id: 'r1' } }),
    sse('response.output_item.added', { type: 'response.output_item.added', output_index: 0,
      item: { type: 'message', id: 'msg_1', role: 'assistant', content: [] } }),
    sse('response.output_text.delta', { type: 'response.output_text.delta', ...base,
      delta: 'Звоню [PERS' }),
    sse('response.output_text.delta', { type: 'response.output_text.delta', ...base,
      delta: 'ON_1].' }),
    sse('response.output_text.done', { type: 'response.output_text.done', ...base,
      text: 'Звоню [PERSON_1].' }),
    sse('response.output_item.done', { type: 'response.output_item.done', output_index: 0,
      item: { type: 'message', id: 'msg_1', role: 'assistant',
        content: [{ type: 'output_text', text: 'Звоню [PERSON_1].' }] } }),
    ...[code.slice(0, 9), code.slice(9, 17), code.slice(17)].map((delta) =>
      sse('response.custom_tool_call_input.delta', {
        type: 'response.custom_tool_call_input.delta', item_id: 'ctc_1', output_index: 1, delta,
      })),
    sse('response.custom_tool_call_input.done', {
      type: 'response.custom_tool_call_input.done', item_id: 'ctc_1', output_index: 1,
      input: code,
    }),
    sse('response.completed', { type: 'response.completed', response: { id: 'r1', output: [] } }),
  ];
}

/** События ответа прокси (данные JSON). */
async function events(res: Response): Promise<Record<string, unknown>[]> {
  const raw = await res.text();
  return raw.split('\n\n').filter((e) => e !== '').map((e) => {
    const m = /^data: (.*)$/m.exec(e);
    return JSON.parse((m?.[1] ?? '{}')) as Record<string, unknown>;
  });
}

describe('pii-proxy: маршрут Codex (Responses через бэкенд ChatGPT)', () => {
  test('запрос уходит без ПДн, авторизация ChatGPT передаётся как есть', async () => {
    rig = startRig(DICT, { contentType: '', chunks: codexStream() });
    const res = await post(rig.base, ROUTE, codexRequest(), {
      ...CODEX_HEADERS, authorization: 'Bearer chatgpt-token', 'chatgpt-account-id': 'acc-1',
    });
    expect(res.status).toBe(200);
    await res.text();
    const hit = rig.upstream.hits[0];
    expect(hit?.path).toBe(ROUTE);
    expect(hit?.body).not.toContain('Иван Петров');
    expect(hit?.body).not.toContain('+7 913 555-12-34');
    expect(hit?.body).toContain('[PERSON_1]');
    expect(hit?.body).toContain('gAAAA-opaque');
    expect(hit?.headers.get('authorization')).toBe('Bearer chatgpt-token');
    expect(hit?.headers.get('chatgpt-account-id')).toBe('acc-1');
  });

  test('поток БЕЗ content-type (как у chatgpt.com) всё равно восстанавливается', async () => {
    rig = startRig(DICT, { contentType: '', chunks: codexStream() });
    const out = await events(await post(rig.base, ROUTE, codexRequest(), CODEX_HEADERS));
    const text = out.filter((j) => j.type === 'response.output_text.delta')
      .map((j) => j.delta).join('');
    expect(text).toBe('Звоню Иван Петров.');
    const code = out.filter((j) => j.type === 'response.custom_tool_call_input.delta');
    expect(code.length).toBe(1);
    expect(code[0]?.delta).toBe('text("Иван Петров +7 913 555-12-34")');
    expect(JSON.stringify(out)).not.toContain('[PERSON_1]');
    expect(JSON.stringify(out)).not.toContain('[PHONE_1]');
  });

  test('тред — по thread-id Codex, а не эфемерный на запрос', async () => {
    rig = startRig(DICT, { contentType: '', chunks: codexStream() });
    await (await post(rig.base, ROUTE, codexRequest(), CODEX_HEADERS)).text();
    const threads = new Set(rig.service.state.batches.map((b) => b.threadId));
    expect([...threads]).toEqual(['dev:thread-abc']);
    expect(rig.service.state.deleted).toEqual([]);
  });

  test('справка о токенах встаёт после ведущих developer-сообщений', async () => {
    rig = startRig(DICT, { contentType: '', chunks: codexStream() });
    await (await post(rig.base, ROUTE, codexRequest(), CODEX_HEADERS)).text();
    const body = JSON.parse(rig.upstream.hits[0]?.body ?? '{}') as { input: { role?: string;
      type?: string; content?: { text?: string }[] }[] };
    expect(body.input[2]?.role).toBe('developer');
    expect(body.input[2]?.content?.[0]?.text).toContain('[PERSON_1]');
    expect(body.input[3]?.role).toBe('user');
  });

  test('неизвестный элемент — 422, в upstream ничего не уходит', async () => {
    rig = startRig(DICT, { contentType: '', chunks: codexStream() });
    const req = { ...codexRequest(), input: [{ type: 'hologram', text: 'Иван Петров' }] };
    const res = await post(rig.base, ROUTE, req, CODEX_HEADERS);
    expect(res.status).toBe(422);
    expect(rig.upstream.hits.length).toBe(0);
  });

  test('список моделей (GET) проходит без маскирования', async () => {
    rig = startRig(DICT, { contentType: 'application/json', chunks: ['{"models":[]}'] });
    const res = await fetch(`${rig.base}/backend-api/codex/models?client_version=0.171.0`);
    expect(res.status).toBe(200);
    expect(await res.text()).toBe('{"models":[]}');
    expect(rig.upstream.hits[0]?.path).toBe('/backend-api/codex/models');
  });

  test('прежний маршрут Claude не изменился', async () => {
    rig = startRig(DICT, { contentType: 'application/json', chunks: [JSON.stringify({
      content: [{ type: 'text', text: 'Это [PERSON_1]' }] })] });
    const res = await post(rig.base, '/v1/messages', {
      messages: [{ role: 'user', content: 'Иван Петров' }] });
    expect(JSON.stringify(await res.json())).toContain('Иван Петров');
    expect(rig.upstream.hits[0]?.body).toContain('"system"');
  });
});
