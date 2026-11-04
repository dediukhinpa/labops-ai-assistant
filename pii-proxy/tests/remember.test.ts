import { afterEach, describe, expect, test } from 'bun:test';
import {
  startRig, post, sse, textStream, collectText, type Rig, type UpstreamReply,
} from './helpers';

const DICT = { 'Иван Петров': '[PERSON_1]', '+7 900 000-00-01': '[PHONE_1]' };
const FIRST = { messages: [{ role: 'user', content: 'Иван Петров' }] };
const MODEL_TEXT = 'Позвонить [PERSON_1|datv]: [PHONE_1]';
const SHOWN_TEXT = 'Позвонить Иван Петров: +7 900 000-00-01';
const MODEL_INPUT = {
  text: 'Позвонить [PERSON_1|datv]: [PHONE_1]',
  nested: { list: ['Письмо от [PERSON_1|gent]', 'без токенов', 7] },
};
const SHOWN_INPUT = {
  text: SHOWN_TEXT,
  nested: { list: ['Письмо от Иван Петров', 'без токенов', 7] },
};
let rig: Rig;
afterEach(async () => { await rig.stop(); });

/** Ответ модели: tool_use с input, разрезанным на куски; closed=false - поток оборван. */
function toolStream(input: unknown, closed = true): UpstreamReply {
  const json = JSON.stringify(input);
  const chunks = [
    sse('content_block_start', { type: 'content_block_start', index: 0,
      content_block: { type: 'tool_use', id: 'tu', name: 'reply', input: {} } }),
    ...[json.slice(0, 20), json.slice(20)].map((partial) => sse('content_block_delta',
      { type: 'content_block_delta', index: 0,
        delta: { type: 'input_json_delta', partial_json: partial } })),
    ...(closed ? [sse('content_block_stop', { type: 'content_block_stop', index: 0 })] : []),
  ];
  return { contentType: 'text/event-stream', chunks };
}

/** Собрать input из input_json_delta ответа прокси. */
async function toolInput(res: Response): Promise<unknown> {
  const raw = await res.text();
  let json = '';
  for (const m of raw.matchAll(/^data: (.*)$/gm)) {
    const j = JSON.parse(m[1] as string) as { delta?: { partial_json?: string } };
    json += j.delta?.partial_json ?? '';
  }
  return JSON.parse(json);
}

/** История в том виде, как её возвращает CLI: восстановленные text и input. */
function history(text: string | undefined, input: unknown): Record<string, unknown> {
  const content: unknown[] = [];
  if (text !== undefined) content.push({ type: 'text', text });
  if (input !== undefined) content.push({ type: 'tool_use', id: 'tu', name: 'reply', input });
  return { messages: [...FIRST.messages, { role: 'assistant', content },
    { role: 'user', content: 'дальше' }] };
}

function sentAssistant(i: number): Record<string, any> {
  const body = JSON.parse(rig.upstream.hits[i]?.body ?? '{}');
  return body.messages[1].content[0] ?? {};
}

describe('память восстановлений', () => {
  test('text-блок: в истории модель видит свой текст с меткой падежа', async () => {
    rig = startRig(DICT, textStream(['Позвонить [PERSON_1', '|datv]: ', '[PHONE_1]']));
    const first = await collectText(await post(rig.base, '/v1/messages', FIRST));
    expect(first.text).toBe(SHOWN_TEXT);
    await (await post(rig.base, '/v1/messages', history(first.text, undefined))).text();
    expect(sentAssistant(1).text).toBe(MODEL_TEXT);
    const line = rig.logger.lines.filter((l) => l.event === 'request').at(-1);
    expect(line?.fields.remembered_leaves).toBe(1);
  });

  test('text-блок в нестриминговом JSON', async () => {
    rig = startRig(DICT, { contentType: 'application/json',
      chunks: [JSON.stringify({ content: [{ type: 'text', text: MODEL_TEXT }] })] });
    const res = await post(rig.base, '/v1/messages', FIRST);
    const shown = ((await res.json()) as { content: { text: string }[] }).content[0]?.text;
    expect(shown).toBe(SHOWN_TEXT);
    await post(rig.base, '/v1/messages', history(shown, undefined));
    expect(sentAssistant(1).text).toBe(MODEL_TEXT);
  });

  test('tool_use: все листья, вложенный объект, числа не тронуты', async () => {
    rig = startRig(DICT, toolStream(MODEL_INPUT));
    const shown = await toolInput(await post(rig.base, '/v1/messages', FIRST));
    expect(shown).toEqual(SHOWN_INPUT);
    await post(rig.base, '/v1/messages', history(undefined, shown));
    expect(sentAssistant(1).input).toEqual(MODEL_INPUT);
  });

  test('смена boot_id: память сброшена, лист маскируется сервисом', async () => {
    rig = startRig(DICT, textStream([MODEL_TEXT]));
    const first = await collectText(await post(rig.base, '/v1/messages', FIRST));
    rig.service.state.bootId = 'boot-2';
    await post(rig.base, '/v1/messages', history(first.text, undefined));
    expect(sentAssistant(1).text).toBe('Позвонить [PERSON_1]: [PHONE_1]');
    expect(rig.service.state.batches.flatMap((b) => b.texts)).toContain(SHOWN_TEXT);
  });

  test('оборванный поток не запоминается', async () => {
    rig = startRig(DICT, toolStream(MODEL_INPUT, false));
    await (await post(rig.base, '/v1/messages', FIRST)).text();
    await post(rig.base, '/v1/messages', history(undefined, SHOWN_INPUT));
    expect(sentAssistant(1).input.text).toBe('Позвонить [PERSON_1]: [PHONE_1]');
  });

  test('оборванный text-поток не запоминается', async () => {
    const reply = textStream([MODEL_TEXT]);
    const chunks = reply.chunks.filter((c) => !c.includes('content_block_stop'));
    rig = startRig(DICT, { ...reply, chunks });
    await (await post(rig.base, '/v1/messages', FIRST)).text();
    await post(rig.base, '/v1/messages', history(SHOWN_TEXT, undefined));
    expect(sentAssistant(1).text).toBe('Позвонить [PERSON_1]: [PHONE_1]');
  });

  test('лист из памяти с ПДн по /check: 422', async () => {
    const leaked = 'Позвонить [PERSON_1|datv] СЕКРЕТ';
    rig = startRig(DICT, textStream([leaked]));
    rig.service.state.checkOnly = ['СЕКРЕТ'];
    const first = await collectText(await post(rig.base, '/v1/messages', FIRST));
    expect(first.text).toContain('СЕКРЕТ');
    const res = await post(rig.base, '/v1/messages', history(first.text, undefined));
    expect(res.status).toBe(422);
    expect(rig.upstream.hits.length).toBe(1);
  });

  test('детерминизм: два запроса подряд маскируют историю одинаково', async () => {
    rig = startRig(DICT, textStream([MODEL_TEXT]));
    const first = await collectText(await post(rig.base, '/v1/messages', FIRST));
    const body = history(first.text, SHOWN_INPUT);
    await post(rig.base, '/v1/messages', body);
    await post(rig.base, '/v1/messages', body);
    const a = JSON.parse(rig.upstream.hits[1]?.body ?? '{}').messages;
    const b = JSON.parse(rig.upstream.hits[2]?.body ?? '{}').messages;
    expect(JSON.stringify(a)).toBe(JSON.stringify(b));
    expect(a[1].content[0].text).toBe(MODEL_TEXT);
  });
});
