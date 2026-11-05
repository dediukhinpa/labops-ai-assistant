import { afterEach, describe, expect, test } from 'bun:test';
import { ATTACHMENT_STRIPPED_TEXT, SYSTEM_INSERT_TEXT } from '@labops/pii';
import { startRig, post, textStream, type Rig } from './helpers';

const DICT = { 'Иван Петров': '[PERSON_1]', '+7 900 000-00-01': '[PHONE_1]' };
let rig: Rig;
afterEach(async () => { await rig.stop(); });

function upstreamBody(r: Rig, i = 0): Record<string, any> {
  return JSON.parse(r.upstream.hits[i]?.body ?? '{}');
}

describe('маскирование запроса', () => {
  test('все виды блоков; thinking, tools и cache_control не тронуты', async () => {
    rig = startRig(DICT, textStream(['ок']));
    const thinking = { type: 'thinking', thinking: 'Иван Петров думает', signature: 'SIG==' };
    const body = {
      model: 'm',
      system: [{ type: 'text', text: 'Система: Иван Петров',
        cache_control: { type: 'ephemeral' } }],
      tools: [{ name: 't', description: 'Иван Петров' }],
      messages: [
        { role: 'user', content: 'Привет, Иван Петров' },
        { role: 'assistant', content: [
          thinking,
          { type: 'text', text: 'Звоню +7 900 000-00-01' },
          { type: 'tool_use', id: 'tu', name: 'Write',
            input: { path: '/a', nested: { list: ['Иван Петров', 3] }, n: 5 } },
        ] },
        { role: 'user', content: [
          { type: 'tool_result', tool_use_id: 'tu', content: 'вывод: Иван Петров' },
          { type: 'tool_result', tool_use_id: 'tu2',
            content: [{ type: 'text', text: 'ещё Иван Петров' }] },
          { type: 'document', source: { type: 'text', media_type: 'text/plain',
            data: 'док: +7 900 000-00-01' } },
          { type: 'text', text: 'вопрос', cache_control: { type: 'ephemeral' } },
        ] },
      ],
    };
    const res = await post(rig.base, '/v1/messages', body);
    expect(res.status).toBe(200);
    const sent = upstreamBody(rig);
    expect(JSON.stringify(sent.messages.slice(0, 1))).not.toContain('Иван Петров');
    expect(JSON.stringify(sent.messages.slice(2))).not.toContain('+7 900');
    expect(sent.system[0]).toEqual({ type: 'text', text: 'Система: [PERSON_1]',
      cache_control: { type: 'ephemeral' } });
    expect(sent.system.at(-1).text).toBe(SYSTEM_INSERT_TEXT);
    expect(sent.tools).toEqual(body.tools);
    // thinking байт-в-байт
    expect(JSON.stringify(sent.messages[1].content[0])).toBe(JSON.stringify(thinking));
    expect(sent.messages[1].content[2].input)
      .toEqual({ path: '/a', nested: { list: ['[PERSON_1]', 3] }, n: 5 });
    expect(sent.messages[2].content[0].content).toBe('вывод: [PERSON_1]');
    expect(sent.messages[2].content[1].content[0].text).toBe('ещё [PERSON_1]');
    expect(sent.messages[2].content[2].source.data).toBe('док: [PHONE_1]');
    expect(sent.messages[2].content[3].cache_control).toEqual({ type: 'ephemeral' });
  });

  test('system строкой превращается в блоки, вставка в конце', async () => {
    rig = startRig(DICT, textStream(['ок']));
    await post(rig.base, '/v1/messages', { system: 'Инструкция', messages: [] });
    expect(upstreamBody(rig).system).toEqual([
      { type: 'text', text: 'Инструкция' }, { type: 'text', text: SYSTEM_INSERT_TEXT }]);
  });

  test('count_tokens маскируется', async () => {
    rig = startRig(DICT, { contentType: 'application/json', chunks: ['{"input_tokens":5}'] });
    const res = await post(rig.base, '/v1/messages/count_tokens',
      { messages: [{ role: 'user', content: 'Иван Петров' }] });
    expect(await res.json()).toEqual({ input_tokens: 5 });
    expect(rig.upstream.hits[0]?.path).toBe('/v1/messages/count_tokens');
    expect(rig.upstream.hits[0]?.body).not.toContain('Иван Петров');
  });

  test('image и pdf: passthrough отправляет как есть, подписи документа маскируются',
    async () => {
      rig = startRig(DICT, textStream(['ок']), { imagePolicy: 'passthrough' });
      const image = { type: 'image', source: { type: 'base64', media_type: 'image/png',
        data: 'AAAA' } };
      const pdf = { type: 'document', title: 'Иван Петров', source: { type: 'base64',
        media_type: 'application/pdf', data: 'BBBB' } };
      const res = await post(rig.base, '/v1/messages', { messages: [{ role: 'user', content: [
        image, pdf, { type: 'text', text: 'Иван Петров' }] }] });
      expect(res.status).toBe(200);
      const c = upstreamBody(rig).messages[0].content;
      expect(c[0]).toEqual(image);
      expect(c[1].source).toEqual(pdf.source);
      expect(c[1].title).not.toContain('Иван Петров');
      expect(c[2].text).not.toContain('Иван Петров');
    });

  test('image и pdf: strip заменяет заглушкой', async () => {
    rig = startRig(DICT, textStream(['ок']));
    await post(rig.base, '/v1/messages', { messages: [{ role: 'user', content: [
      { type: 'image', source: { type: 'base64', media_type: 'image/png', data: 'AAAA' } },
      { type: 'document', source: { type: 'base64', media_type: 'application/pdf', data: 'BBBB' } },
      { type: 'tool_result', tool_use_id: 'x', content: [
        { type: 'image', source: { type: 'base64', media_type: 'image/png', data: 'CCCC' } }] },
    ] }] });
    const raw = rig.upstream.hits[0]?.body ?? '';
    expect(raw).not.toContain('AAAA');
    expect(raw).not.toContain('BBBB');
    expect(raw).not.toContain('CCCC');
    const c = upstreamBody(rig).messages[0].content;
    expect(c[0]).toEqual({ type: 'text', text: ATTACHMENT_STRIPPED_TEXT });
    expect(c[1]).toEqual({ type: 'text', text: ATTACHMENT_STRIPPED_TEXT });
    expect(c[2].content[0]).toEqual({ type: 'text', text: ATTACHMENT_STRIPPED_TEXT });
  });

  test('image при policy reject: 422, upstream не вызван', async () => {
    rig = startRig(DICT, textStream(['ок']), { imagePolicy: 'reject' });
    const res = await post(rig.base, '/v1/messages', { messages: [{ role: 'user', content: [
      { type: 'image', source: { type: 'base64', media_type: 'image/png', data: 'AAAA' } }] }] });
    expect(res.status).toBe(422);
    expect((await res.json() as any).type).toBe('error');
    expect(rig.upstream.hits.length).toBe(0);
  });

  test('tool_addition (инструмент, подгруженный по ходу сессии) пропускается как есть',
    async () => {
      rig = startRig(DICT, textStream(['ок']));
      const addition = { type: 'tool_addition', tool: { type: 'tool_definition',
        definition: { name: 'x', description: 'd', input_schema: { type: 'object' } } } };
      const res = await post(rig.base, '/v1/messages', { messages: [
        { role: 'user', content: 'Иван Петров' }, { role: 'system', content: [addition] }] });
      expect(res.status).toBe(200);
      const sent = JSON.parse(rig.upstream.hits[0]?.body ?? '{}') as any;
      expect(sent.messages[1].content[0]).toEqual(addition);
    });

  test('tool_reference в результате поиска инструментов пропускается как есть', async () => {
    rig = startRig(DICT, textStream(['ок']));
    const ref = { type: 'tool_reference', tool_name: 'mcp__x__y' };
    const res = await post(rig.base, '/v1/messages', { messages: [{ role: 'user', content: [
      { type: 'tool_result', tool_use_id: 't1', content: [ref] }] }] });
    expect(res.status).toBe(200);
    expect(upstreamBody(rig).messages[0].content[0].content[0]).toEqual(ref);
  });

  test('неизвестный тип блока: 422, upstream не вызван', async () => {
    rig = startRig(DICT, textStream(['ок']));
    const res = await post(rig.base, '/v1/messages', { messages: [
      { role: 'user', content: [{ type: 'brand_new_block', text: 'Иван Петров' }] }] });
    expect(res.status).toBe(422);
    expect(rig.upstream.hits.length).toBe(0);
  });

  test('длинный лист режется по строкам, склеивается по порядку', async () => {
    rig = startRig(DICT, textStream(['ок']));
    const line = 'Иван Петров строка\n';
    const leaf = line.repeat(8_000); // ~152 000 символов
    await post(rig.base, '/v1/messages', { messages: [{ role: 'user', content: leaf }] });
    expect(rig.service.state.batches.length).toBeGreaterThan(1);
    const sent = upstreamBody(rig).messages[0].content as string;
    expect(sent).toBe('[PERSON_1] строка\n'.repeat(8_000));
  });
});

describe('детерминизм и кэш', () => {
  test('растущая история маскируется байт-в-байт одинаково', async () => {
    rig = startRig(DICT, textStream(['ок']));
    const m1 = { role: 'user', content: 'Иван Петров просит' };
    const m2 = { role: 'assistant', content: [{ type: 'text', text: 'ответ +7 900 000-00-01' }] };
    const m3 = { role: 'user', content: [{ type: 'tool_result', tool_use_id: 'a',
      content: 'вывод Иван Петров' }] };
    await post(rig.base, '/v1/messages', { system: 'S', messages: [m1] });
    await post(rig.base, '/v1/messages', { system: 'S', messages: [m1, m2, m3] });
    const a = upstreamBody(rig, 0);
    const b = upstreamBody(rig, 1);
    expect(JSON.stringify(b.messages[0])).toBe(JSON.stringify(a.messages[0]));
    expect(JSON.stringify(b.system)).toBe(JSON.stringify(a.system));
    // второй запрос: сервису ушли только новые листья
    const secondSent = rig.service.state.batches.slice(1).flatMap((x) => x.texts);
    expect(secondSent).not.toContain('Иван Петров просит');
    expect(secondSent).not.toContain('S');
  });

  test('смена boot_id сбрасывает кэш: история маскируется заново с начала', async () => {
    rig = startRig(DICT, textStream(['ок']));
    const body = { messages: [{ role: 'user', content: 'Иван Петров' }] };
    await post(rig.base, '/v1/messages', body);
    const before = rig.service.state.batches.length;
    await post(rig.base, '/v1/messages', body);
    expect(rig.service.state.batches.length).toBe(before); // из кэша
    rig.service.state.bootId = 'boot-2';
    await post(rig.base, '/v1/messages', body); // boot_id сверяется на каждом запросе
    expect(rig.service.state.batches.length).toBe(before + 1);
  });

  test('перезапуск сервиса во время маскирования: кэш сброшен, запрос замаскирован заново',
    async () => {
      rig = startRig(DICT, textStream(['ок']));
      rig.service.state.bootAfterBatch = ['boot-2'];
      const res = await post(rig.base, '/v1/messages',
        { messages: [{ role: 'user', content: 'Иван Петров' }] });
      expect(res.status).toBe(200);
      expect(rig.service.state.batches.length).toBe(2); // первый проход отброшен
      expect(JSON.stringify(rig.upstream.hits[0]?.body)).not.toContain('Иван Петров');
    });

  test('сервис перезапускается на каждом проходе: 503, upstream не вызван', async () => {
    rig = startRig(DICT, textStream(['ок']));
    rig.service.state.bootAfterBatch = ['boot-2', 'boot-3', 'boot-4'];
    const res = await post(rig.base, '/v1/messages',
      { messages: [{ role: 'user', content: 'Иван Петров' }] });
    expect(res.status).toBe(503);
    expect(rig.upstream.hits.length).toBe(0);
  });
});

describe('fail closed и вторая линия', () => {
  for (const mode of ['http500', 'http401', 'hang'] as const) {
    test(`сервис ${mode}: 503, upstream не вызван`, async () => {
      rig = startRig(DICT, textStream(['ок']), { timeoutMs: 300 });
      rig.service.state.mode = mode;
      const res = await post(rig.base, '/v1/messages',
        { messages: [{ role: 'user', content: 'Иван Петров' }] });
      expect(res.status).toBe(503);
      const j = (await res.json()) as any;
      expect(j.type).toBe('error');
      expect(j.error.type).toBe('api_error');
      expect(rig.upstream.hits.length).toBe(0);
    });
  }

  test('после маскирования /check нашёл ПДн: 422 с видами, без значений', async () => {
    rig = startRig(DICT, textStream(['ок']));
    rig.service.state.checkOnly = ['Сидоров'];
    const res = await post(rig.base, '/v1/messages',
      { messages: [{ role: 'user', content: 'пишет Сидоров' }] });
    expect(res.status).toBe(422);
    const j = (await res.json()) as any;
    expect(j.error.type).toBe('invalid_request_error');
    expect(j.error.message).toContain('PERSON');
    expect(j.error.message).not.toContain('Сидоров');
    expect(rig.upstream.hits.length).toBe(0);
    const logged = JSON.stringify(rig.logger.lines);
    expect(logged).not.toContain('Сидоров');
  });
});

describe('маршруты и треды', () => {
  test('эфемерный тред удаляется, сессионный остаётся', async () => {
    rig = startRig(DICT, textStream(['ок']));
    const body = { messages: [{ role: 'user', content: 'Иван Петров' }] };
    const r1 = await fetch(`${rig.base}/v1/messages`,
      { method: 'POST', body: JSON.stringify(body) });
    await r1.text();
    await Bun.sleep(50);
    expect(rig.service.state.deleted.length).toBe(1);
    expect(rig.service.state.deleted[0]).toMatch(/^dev:req-/);
    expect(rig.service.state.batches[0]?.threadId).toBe(rig.service.state.deleted[0] as string);
    await (await post(rig.base, '/v1/messages', body)).text();
    expect(rig.service.state.deleted.length).toBe(1);
    expect(rig.service.state.batches.at(-1)?.threadId).toBe('dev:s1');
  });

  test('GET проксируется как есть, заголовки авторизации доходят', async () => {
    rig = startRig(DICT, { contentType: 'application/json', chunks: ['{"data":[]}'] });
    const res = await fetch(`${rig.base}/v1/models?limit=1`,
      { headers: { authorization: 'Bearer o' } });
    expect(await res.json()).toEqual({ data: [] });
    expect(rig.upstream.hits[0]?.headers.get('authorization')).toBe('Bearer o');
    expect(rig.service.state.calls.filter((c) => c !== 'GET /health')).toEqual([]);
  });

  test('прочий POST с ПДн: 422; без ПДн: как есть', async () => {
    rig = startRig(DICT, { contentType: 'application/json', chunks: ['{"ok":1}'] });
    const bad = await post(rig.base, '/v1/other', { q: 'Иван Петров' });
    expect(bad.status).toBe(422);
    await bad.text();
    expect(rig.upstream.hits.length).toBe(0);
    const good = await post(rig.base, '/v1/other', { q: 'ничего' });
    expect(good.status).toBe(200);
    await good.text();
    expect(rig.upstream.hits[0]?.body).toBe('{"q":"ничего"}');
  });

  test('Content-Encoding кроме identity: 415', async () => {
    rig = startRig(DICT, textStream(['ок']));
    const res = await fetch(`${rig.base}/v1/messages`, { method: 'POST', body: 'x',
      headers: { 'content-encoding': 'gzip' } });
    expect(res.status).toBe(415);
    expect(rig.upstream.hits.length).toBe(0);
  });

  test('журнал не содержит текстов и токена', async () => {
    rig = startRig(DICT, textStream(['ок']));
    await post(rig.base, '/v1/messages', { messages: [{ role: 'user', content: 'Иван Петров' }] },
      { authorization: 'Bearer SECRETVALUE' });
    const logged = JSON.stringify(rig.logger.lines);
    expect(logged).not.toContain('Иван');
    expect(logged).not.toContain('SECRETVALUE');
    expect(logged).not.toContain('test-token');
    expect(logged).not.toContain('"s1"');
  });
});
