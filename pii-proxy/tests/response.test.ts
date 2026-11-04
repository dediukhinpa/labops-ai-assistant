import { afterEach, describe, expect, test } from 'bun:test';
import { startRig, post, sse, textStream, collectText, type Rig } from './helpers';

const DICT = { 'Иван Петров': '[PERSON_1]', 'Мария Сидорова': '[PERSON_2]' };
let rig: Rig;
afterEach(async () => { await rig.stop(); });
const REQ = { messages: [{ role: 'user', content: 'Иван Петров' }] };

/** Разрезать строку на куски по n символов. */
function slices(s: string, n: number): string[] {
  const out: string[] = [];
  for (let i = 0; i < s.length; i += n) out.push(s.slice(i, i + n));
  return out;
}

describe('текст в SSE', () => {
  for (const n of [1, 2, 3, 4, 5]) {
    test(`токен разрезан по ${n} символ(ов) на событие`, async () => {
      rig = startRig(DICT, textStream(slices('Звоните [PERSON_1], а также [PERSON_2]. Конец', n)));
      const res = await post(rig.base, '/v1/messages', REQ);
      const { text } = await collectText(res);
      expect(text).toBe('Звоните Иван Петров, а также Мария Сидорова. Конец');
      expect(text).not.toContain('[PERSON');
    });
  }

  test('токен с меткой разрезан на «|»', async () => {
    rig = startRig(DICT, textStream(['Письмо [PERSON_1', '|', 'da', 'tv] ок']));
    const { text } = await collectText(await post(rig.base, '/v1/messages', REQ));
    expect(text).toBe('Письмо Иван Петров ок');
  });

  test('скобки, не похожие на токен, и хвост в конце блока не теряются', async () => {
    rig = startRig(DICT, textStream(['a[0] и [x', ' конец [PE']));
    const { text } = await collectText(await post(rig.base, '/v1/messages', REQ));
    expect(text).toBe('a[0] и [x конец [PE');
  });

  test('ping, message_start и порядок событий сохранены', async () => {
    rig = startRig(DICT, {
      contentType: 'text/event-stream',
      chunks: [
        sse('message_start', { type: 'message_start', message: { usage: { input_tokens: 1 } } }),
        sse('ping', { type: 'ping' }),
        sse('content_block_start', { type: 'content_block_start', index: 0,
          content_block: { type: 'thinking', thinking: '' } }),
        sse('content_block_delta', { type: 'content_block_delta', index: 0,
          delta: { type: 'thinking_delta', thinking: 'модель видела [PERSON_1]' } }),
        sse('content_block_delta', { type: 'content_block_delta', index: 0,
          delta: { type: 'signature_delta', signature: 'SIG' } }),
        sse('content_block_stop', { type: 'content_block_stop', index: 0 }),
        sse('content_block_start', { type: 'content_block_start', index: 1,
          content_block: { type: 'text', text: '' } }),
        sse('content_block_delta', { type: 'content_block_delta', index: 1,
          delta: { type: 'text_delta', text: 'Привет, [PERSON_1]!' } }),
        sse('content_block_stop', { type: 'content_block_stop', index: 1 }),
        sse('message_delta', { type: 'message_delta', delta: {}, usage: { output_tokens: 2 } }),
        sse('message_stop', { type: 'message_stop' }),
      ],
    });
    const raw = await (await post(rig.base, '/v1/messages', REQ)).text();
    const names = [...raw.matchAll(/^event: (.*)$/gm)].map((m) => m[1]);
    expect(names).toEqual(['message_start', 'ping', 'content_block_start', 'content_block_delta',
      'content_block_delta', 'content_block_stop', 'content_block_start', 'content_block_delta',
      'content_block_stop', 'message_delta', 'message_stop']);
    // thinking_delta и signature_delta - как есть (токен внутри thinking не восстанавливается)
    expect(raw).toContain('"thinking":"модель видела [PERSON_1]"');
    expect(raw).toContain('"signature":"SIG"');
    expect(raw).toContain('Привет, Иван Петров!');
  });

  test('ошибка /restore посреди потока: событие error, токены не отдаются', async () => {
    rig = startRig(DICT, textStream(['Первое [PERSON_1].\n', 'Второе [PERSON_2] и [PERSON_1].\n',
      'Третье [PERSON_1].\n']));
    rig.service.state.restoreFailAfter = 1;
    const raw = await (await post(rig.base, '/v1/messages', REQ)).text();
    expect(raw).toContain('event: error');
    expect(raw).not.toContain('"type":"message_stop"');
    expect(raw).not.toContain('[PERSON_2]');
    expect(raw).toContain('Первое Иван Петров.');
  });
});

describe('tool_use', () => {
  test('токены в нескольких листьях восстанавливаются одним input_json_delta', async () => {
    const json = JSON.stringify({ file_path: '/tmp/a.txt',
      content: 'Для [PERSON_1]', list: ['x', 'Контакт [PERSON_2]'], n: 7 });
    rig = startRig(DICT, {
      contentType: 'text/event-stream',
      chunks: [
        sse('content_block_start', { type: 'content_block_start', index: 0,
          content_block: { type: 'tool_use', id: 't1', name: 'Write', input: {} } }),
        ...slices(json, 4).map((p) => sse('content_block_delta', { type: 'content_block_delta',
          index: 0, delta: { type: 'input_json_delta', partial_json: p } })),
        sse('content_block_stop', { type: 'content_block_stop', index: 0 }),
        sse('message_stop', { type: 'message_stop' }),
      ],
    });
    const raw = await (await post(rig.base, '/v1/messages', REQ)).text();
    const deltas = [...raw.matchAll(/^data: (.*)$/gm)].map((m) => JSON.parse(m[1] as string))
      .filter((j) => j.delta?.type === 'input_json_delta');
    expect(deltas.length).toBe(1);
    expect(JSON.parse(deltas[0].delta.partial_json)).toEqual({ file_path: '/tmp/a.txt',
      content: 'Для Иван Петров', list: ['x', 'Контакт Мария Сидорова'], n: 7 });
    expect(raw.indexOf('input_json_delta')).toBeLessThan(raw.indexOf('content_block_stop'));
  });
});

describe('нестриминговый ответ', () => {
  test('text и tool_use восстановлены, thinking не тронут', async () => {
    const reply = { content: [
      { type: 'thinking', thinking: 'видел [PERSON_1]', signature: 's' },
      { type: 'text', text: 'Здравствуйте, [PERSON_1]' },
      { type: 'tool_use', id: 'a', name: 'W', input: { who: '[PERSON_2]' } },
    ] };
    rig = startRig(DICT, { contentType: 'application/json', chunks: [JSON.stringify(reply)] });
    const res = await post(rig.base, '/v1/messages', REQ);
    const j = (await res.json()) as typeof reply;
    expect(j.content[0]).toEqual(reply.content[0]!);
    expect(j.content[1]).toEqual({ type: 'text', text: 'Здравствуйте, Иван Петров' });
    expect((j.content[2] as any).input).toEqual({ who: 'Мария Сидорова' });
  });

  test('ошибка upstream передаётся как есть', async () => {
    rig = startRig(DICT, { status: 429, contentType: 'application/json', chunks: ['{"e":1}'] });
    const res = await post(rig.base, '/v1/messages', REQ);
    expect(res.status).toBe(429);
    expect(await res.json()).toEqual({ e: 1 });
  });
});
