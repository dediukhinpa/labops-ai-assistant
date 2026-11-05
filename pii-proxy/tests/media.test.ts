import { afterEach, describe, expect, test } from 'bun:test';
import { loadConfig } from '../src/config';
import { attachmentBlockedText, SYSTEM_INSERT_TEXT } from '@labops/pii';
import { MEDIA_TOKEN, fakeMaskedData, post, startRig, textStream, type Rig } from './helpers';

const DICT = { 'Иван Петров': '[PERSON_1]', '+7 900 000-00-01': '[PHONE_1]' };
const PNG_DATA = 'QUFBQUFBQUFBQQ==';
let rig: Rig;
afterEach(async () => { await rig.stop(); });

const maskRig = (over = {}): Rig =>
  startRig(DICT, textStream(['ок']), { imagePolicy: 'mask', ...over });
const upstreamBody = (r: Rig, i = 0): Record<string, any> =>
  JSON.parse(r.upstream.hits[i]?.body ?? '{}');
const image = (data = PNG_DATA, extra = {}): Record<string, unknown> =>
  ({ type: 'image', source: { type: 'base64', media_type: 'image/png', data }, ...extra });
const pdf = (spec: string, extra = {}): Record<string, unknown> => ({ type: 'document',
  source: { type: 'base64', media_type: 'application/pdf',
    data: Buffer.from(spec).toString('base64') }, ...extra });
const user = (content: unknown[]): unknown => ({ messages: [{ role: 'user', content }] });

describe('политика mask', () => {
  test('image: данные заменены закрашенными, остальное сохранено, оригинал не ушёл', async () => {
    rig = maskRig();
    const res = await post(rig.base, '/v1/messages', user([
      image(PNG_DATA, { cache_control: { type: 'ephemeral' } })]));
    expect(res.status).toBe(200);
    const raw = rig.upstream.hits[0]?.body ?? '';
    expect(raw).not.toContain(PNG_DATA);
    const block = upstreamBody(rig).messages[0].content[0];
    expect(block.source).toEqual({ type: 'base64', media_type: 'image/png',
      data: fakeMaskedData(PNG_DATA) });
    expect(block.cache_control).toEqual({ type: 'ephemeral' });
    expect(rig.media.state.tokenSeen[0]).toBe(`Bearer ${MEDIA_TOKEN}`);
  });

  test('image в tool_result тоже маскируется', async () => {
    rig = maskRig();
    await post(rig.base, '/v1/messages', user([{ type: 'tool_result', tool_use_id: 'x',
      content: [image()] }]));
    expect(rig.upstream.hits[0]?.body).not.toContain(PNG_DATA);
    expect(rig.media.state.calls).toEqual(['/mask_image']);
  });

  test('image по url: пометка вместо блока, запрос уходит, сервис не вызван', async () => {
    rig = maskRig();
    const res = await post(rig.base, '/v1/messages', user([
      { type: 'image', source: { type: 'url', url: 'https://example.com/a.png' },
        cache_control: { type: 'ephemeral' } }]));
    expect(res.status).toBe(200);
    expect(upstreamBody(rig).messages[0].content[0]).toEqual({ type: 'text',
      text: attachmentBlockedText('not_base64'), cache_control: { type: 'ephemeral' } });
    expect(rig.upstream.hits[0]?.body).not.toContain('example.com');
    expect(rig.media.state.calls.length).toBe(0);
  });

  test('pdf с текстовым слоем: text-блоки, ПДн из текста маскируются токенами', async () => {
    rig = maskRig();
    const res = await post(rig.base, '/v1/messages', user([
      { type: 'text', text: 'Вот файл' },
      pdf('TEXT:Клиент Иван Петров|Тел +7 900 000-00-01', { cache_control: { type: 'ephemeral' } }),
    ]));
    expect(res.status).toBe(200);
    const raw = rig.upstream.hits[0]?.body ?? '';
    expect(raw).not.toContain('Иван Петров');
    expect(raw).not.toContain('+7 900 000-00-01');
    const content = upstreamBody(rig).messages[0].content;
    expect(content.map((b: any) => b.type)).toEqual(['text', 'text', 'text']);
    expect(content[1].text).toBe('Клиент [PERSON_1]');
    expect(content[2].text).toBe('Тел [PHONE_1]');
    expect(content[1].cache_control).toBeUndefined();
    expect(content[2].cache_control).toEqual({ type: 'ephemeral' });
  });

  test('pdf-скан: image-блоки страниц', async () => {
    rig = maskRig();
    await post(rig.base, '/v1/messages', user([pdf('SCAN:2'), { type: 'text', text: 'и всё' }]));
    const content = upstreamBody(rig).messages[0].content;
    expect(content.map((b: any) => b.type)).toEqual(['image', 'image', 'text']);
    expect(content[0].source.media_type).toBe('image/jpeg');
    expect(content[0].source.data).toBe(fakeMaskedData('page0'));
    expect(rig.upstream.hits[0]?.body).not.toContain(Buffer.from('SCAN:2').toString('base64'));
  });

  test('токены в тексте PDF и в сообщении согласованы, вставка system на месте', async () => {
    rig = maskRig();
    await post(rig.base, '/v1/messages', {
      messages: [{ role: 'user', content: [pdf('TEXT:Иван Петров')] },
        { role: 'user', content: 'Иван Петров' }] });
    const body = upstreamBody(rig);
    expect(body.messages[0].content[0].text).toBe('[PERSON_1]');
    expect(body.messages[1].content).toBe('[PERSON_1]');
    expect(body.system[body.system.length - 1].text).toBe(SYSTEM_INSERT_TEXT);
  });

  test('второй линией проверяется и текст из PDF', async () => {
    rig = maskRig();
    rig.service.state.checkOnly.push('СЕКРЕТ');
    const res = await post(rig.base, '/v1/messages', user([pdf('TEXT:СЕКРЕТ в файле')]));
    expect(res.status).toBe(422);
    expect(rig.upstream.hits.length).toBe(0);
  });

  test('документ не-PDF и документ по url: пометки с причинами', async () => {
    rig = maskRig();
    const docx = { type: 'document', source: { type: 'base64',
      media_type: 'application/msword', data: 'AAAA' } };
    const byUrl = { type: 'document', source: { type: 'url', url: 'https://x.test/a.pdf' } };
    const res = await post(rig.base, '/v1/messages', user([docx, byUrl]));
    expect(res.status).toBe(200);
    const c = upstreamBody(rig).messages[0].content;
    expect(c[0].text).toBe(attachmentBlockedText('unsupported_type'));
    expect(c[1].text).toBe(attachmentBlockedText('not_base64'));
    expect(rig.media.state.calls.length).toBe(0);
  });

  test('отказ media-masker по файлу: пометка, оригинал не ушёл, счётчик по причине', async () => {
    rig = maskRig();
    rig.media.state.mode = 'refuse422';
    const res = await post(rig.base, '/v1/messages', user([image(), image('QkJCQg==')]));
    expect(res.status).toBe(200);
    const raw = rig.upstream.hits[0]?.body ?? '';
    expect(raw).not.toContain(PNG_DATA);
    const c = upstreamBody(rig).messages[0].content;
    expect(c.map((b: { text: string }) => b.text)).toEqual(
      [attachmentBlockedText('unreadable'), attachmentBlockedText('unreadable')]);
    // запись журнала появляется после конца потока ответа
    await Bun.sleep(100);
    const fields = rig.logger.lines.map((l) => l.fields).find((f) => f.blocked_attachments);
    expect(fields?.blocked_attachments).toEqual({ unreadable: 2 });
  });

  test('отказ по файлу кэшируется: повтор не ходит в сервис', async () => {
    rig = maskRig();
    rig.media.state.mode = 'refuse422';
    await post(rig.base, '/v1/messages', user([image()]));
    await post(rig.base, '/v1/messages', user([image()]));
    expect(rig.media.state.calls.length).toBe(1);
    expect(upstreamBody(rig, 1).messages[0].content[0].text)
      .toBe(attachmentBlockedText('unreadable'));
  });

  test('сбой и таймаут media-masker: пометка (fail closed), без кэша сбоя', async () => {
    const expected = { http500: 'service_unavailable', hang: 'timeout' } as const;
    for (const mode of ['http500', 'hang'] as const) {
      rig = maskRig();
      rig.media.state.mode = mode;
      const res = await post(rig.base, '/v1/messages', user([image(), pdf('SCAN:1')]));
      expect(res.status).toBe(200);
      const raw = rig.upstream.hits[0]?.body ?? '';
      expect(raw).not.toContain(PNG_DATA);
      const c = upstreamBody(rig).messages[0].content;
      expect(c.map((b: { text: string }) => b.text)).toEqual(
        [attachmentBlockedText(expected[mode]), attachmentBlockedText(expected[mode])]);
      // сервис ожил: то же вложение обрабатывается заново
      rig.media.state.mode = 'ok';
      await post(rig.base, '/v1/messages', user([image()]));
      expect(upstreamBody(rig, 1).messages[0].content[0].source.data)
        .toBe(fakeMaskedData(PNG_DATA));
      await rig.stop();
    }
    rig = maskRig();
  }, 15_000);

  test('media-masker остановлен: пометка, запрос уходит', async () => {
    rig = maskRig();
    await rig.media.stop();
    const res = await post(rig.base, '/v1/messages', user([image()]));
    expect(res.status).toBe(200);
    expect(upstreamBody(rig).messages[0].content[0].text)
      .toBe(attachmentBlockedText('service_unavailable'));
    expect(rig.upstream.hits[0]?.body).not.toContain(PNG_DATA);
  });

  test('утечки нет: в upstream нет ни исходных байтов, ни ПДн из PDF и подписей', async () => {
    rig = maskRig();
    const secret = pdf('TEXT:Клиент Иван Петров|Тел +7 900 000-00-01', { title: 'Иван Петров' });
    await post(rig.base, '/v1/messages', user([image(), secret, pdf('SCAN:2')]));
    const raw = rig.upstream.hits[0]?.body ?? '';
    for (const forbidden of [PNG_DATA, 'Иван', 'Петров', '+7 900', secret.source as never]) {
      if (typeof forbidden === 'string') expect(raw).not.toContain(forbidden);
    }
    expect(raw).not.toContain(Buffer.from('TEXT:Клиент').toString('base64'));
    expect(raw).not.toContain('"application/pdf"');
    expect(raw).toContain('[PERSON_1]');
  });

  test('детерминизм: одинаковая история даёт побайтово одинаковый префикс', async () => {
    rig = maskRig();
    const history = [image(), pdf('TEXT:Иван Петров|стр2'), pdf('SCAN:2'), image('QkJCQg==')];
    await post(rig.base, '/v1/messages', user(history));
    await post(rig.base, '/v1/messages', user([...history, { type: 'text', text: 'ещё' }]));
    const a = upstreamBody(rig, 0).messages[0].content;
    const b = upstreamBody(rig, 1).messages[0].content;
    expect(b.slice(0, a.length)).toEqual(a);
    expect(rig.media.state.calls.length).toBe(4);
  });

  test('pdf: предел страниц сервиса даёт пометку too_many_pages', async () => {
    rig = maskRig();
    rig.media.state.mode = 'refuse413';
    await post(rig.base, '/v1/messages', user([pdf('SCAN:99')]));
    expect(upstreamBody(rig).messages[0].content[0].text)
      .toBe(attachmentBlockedText('too_many_pages'));
  });

  test('кэш по sha256: одна картинка в истории - один вызов, байты одинаковы', async () => {
    rig = maskRig();
    const body = user([image(), image('QkJCQg=='), image()]);
    await post(rig.base, '/v1/messages', body);
    expect(rig.media.state.calls.length).toBe(2);
    await post(rig.base, '/v1/messages', user([image(), image('QkJCQg==')]));
    expect(rig.media.state.calls.length).toBe(2);
    const a = upstreamBody(rig, 0).messages[0].content[0];
    const b = upstreamBody(rig, 1).messages[0].content[0];
    expect(a).toEqual(b);
  });

  test('кэш PDF: повторный документ не разбирается заново', async () => {
    rig = maskRig();
    await post(rig.base, '/v1/messages', user([pdf('TEXT:абв')]));
    await post(rig.base, '/v1/messages', user([pdf('TEXT:абв')]));
    expect(rig.media.state.calls).toEqual(['/extract_document']);
  });

  test('count_tokens тоже маскирует вложения', async () => {
    rig = startRig(DICT, { contentType: 'application/json', chunks: ['{"input_tokens":5}'] },
      { imagePolicy: 'mask' });
    await post(rig.base, '/v1/messages/count_tokens', user([image()]));
    expect(rig.upstream.hits[0]?.body).not.toContain(PNG_DATA);
  });
});

describe('конфиг политики вложений', () => {
  const base = { PII_PROXY_PORT: '6300', PII_PROXY_AGENT_ID: 'dev', PSEUDONYMIZER_API_TOKEN: 'x' };
  test('по умолчанию mask: адрес по умолчанию, токен обязателен', () => {
    const c = loadConfig({ ...base, MEDIA_MASKER_API_TOKEN: 't' });
    expect(c.imagePolicy).toBe('mask');
    expect(c.mediaMaskerUrl).toBe('http://127.0.0.1:8320');
    const c2 = loadConfig({ ...base, MEDIA_MASKER_URL: 'http://127.0.0.1:9/',
      MEDIA_MASKER_API_TOKEN: 't' });
    expect(c2.mediaMaskerUrl).toBe('http://127.0.0.1:9');
  });
  test('пустые значения из EnvironmentFile = не заданы', () => {
    expect(() => loadConfig({ ...base, MEDIA_MASKER_API_TOKEN: '', PII_PROXY_IMAGE_POLICY: '' }))
      .toThrow(/MEDIA_MASKER_API_TOKEN/);
    const c = loadConfig({ ...base, MEDIA_MASKER_URL: '', MEDIA_MASKER_API_TOKEN: 't',
      PII_PROXY_IMAGE_POLICY: '' });
    expect(c.imagePolicy).toBe('mask');
  });
  test('mask без токена - ошибка без значений, strip работает без media-masker', () => {
    expect(() => loadConfig({ ...base, PII_PROXY_IMAGE_POLICY: 'mask' }))
      .toThrow(/MEDIA_MASKER_API_TOKEN/);
    expect(loadConfig({ ...base, PII_PROXY_IMAGE_POLICY: 'strip' }).imagePolicy).toBe('strip');
  });
  test('strip и reject остаются', () => {
    expect(loadConfig({ ...base, PII_PROXY_IMAGE_POLICY: 'reject' }).imagePolicy).toBe('reject');
  });
});
