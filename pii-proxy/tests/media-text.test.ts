import { afterEach, describe, expect, test } from 'bun:test';
import {
  RECOGNIZED_HEADER, RECOGNIZED_HIDDEN_NOTE,
} from '../src/constants';
import { recognizedBlockText } from '../src/media-text';
import { NOTHING_RECOGNIZED } from '../src/media-client';
import { collectText, post, startRig, textStream, type Rig } from './helpers';

const PERSON = 'Иванов Пётр Сергеевич';
const PHONE = '+7 912 345-67-89';
const EMAIL = 'petr.ivanov@example.com';
const DICT = { [PERSON]: '[PERSON_1]', [PHONE]: '[PHONE_1]', [EMAIL]: '[EMAIL_1]' };
const PNG_DATA = 'QUFBQUFBQUFBQQ==';
const CARD_TEXT = `${PERSON}\nДиректор по закупкам\n${PHONE}`;
const QR_TEXT = `ФИО: ${PERSON}; Телефон: ${PHONE}; Эл. почта: ${EMAIL}`;

let rig: Rig;
afterEach(async () => { await rig.stop(); });

const maskRig = (reply = textStream(['ок'])): Rig =>
  startRig(DICT, reply, { imagePolicy: 'mask' });
const image = (data = PNG_DATA, extra = {}): Record<string, unknown> =>
  ({ type: 'image', source: { type: 'base64', media_type: 'image/png', data }, ...extra });
const user = (content: unknown[]): unknown => ({ messages: [{ role: 'user', content }] });
const sentContent = (r: Rig, i = 0): any[] => JSON.parse(r.upstream.hits[i]?.body ?? '{}')
  .messages[0].content;

describe('текст с изображения токенами', () => {
  test('модель получает токены, а не значения; картинка закрашена', async () => {
    rig = maskRig();
    rig.media.state.recognized = { text: CARD_TEXT, codes: [], hidden_text: false };
    const res = await post(rig.base, '/v1/messages', user([image()]));
    expect(res.status).toBe(200);
    const raw = rig.upstream.hits[0]?.body ?? '';
    for (const secret of [PERSON, PHONE, 'Иванов', '912 345', PNG_DATA]) {
      expect(raw).not.toContain(secret);
    }
    const content = sentContent(rig);
    expect(content.map((b) => b.type)).toEqual(['image', 'text']);
    expect(content[1].text).toBe(
      `${RECOGNIZED_HEADER}\n[PERSON_1]\nДиректор по закупкам\n[PHONE_1]`);
    // сервису маскирования ушёл именно этот блок, тем же тредом, что и остальное
    const sentTexts = rig.service.state.batches.flatMap((b) => b.texts);
    expect(sentTexts.some((t) => t.includes(PERSON))).toBe(true);
    expect(new Set(rig.service.state.batches.map((b) => b.threadId)).size).toBe(1);
  });

  test('в ответе модели токены восстанавливаются в настоящие значения', async () => {
    rig = maskRig(textStream(['Это визитка ', '[PERSON_1], тел. [PHONE_1].']));
    rig.media.state.recognized = { text: CARD_TEXT, codes: [], hidden_text: false };
    const res = await post(rig.base, '/v1/messages', user([image()]));
    const { text } = await collectText(res);
    expect(text).toBe(`Это визитка ${PERSON}, тел. ${PHONE}.`);
  });

  test('QR: содержимое токенами, область закрашена, пометка о нерасшифрованном', async () => {
    rig = maskRig();
    rig.media.state.recognized = { text: '', codes: [{ kind: 'qr', text: QR_TEXT },
      { kind: 'barcode', text: '4601234567893' }, { kind: 'qr', text: '' }], hidden_text: false };
    await post(rig.base, '/v1/messages', user([image()]));
    const raw = rig.upstream.hits[0]?.body ?? '';
    for (const secret of [PERSON, PHONE, EMAIL]) expect(raw).not.toContain(secret);
    const note = sentContent(rig)[1].text as string;
    expect(note).toBe([
      RECOGNIZED_HEADER,
      'QR-код: ФИО: [PERSON_1]; Телефон: [PHONE_1]; Эл. почта: [EMAIL_1]',
      'Штрихкод: 4601234567893',
      'QR-код: не расшифрован, область на изображении закрашена',
    ].join('\n'));
  });

  test('рукопись: модель получает пометку о скрытом тексте', async () => {
    rig = maskRig();
    rig.media.state.recognized = { text: '', codes: [], hidden_text: true };
    await post(rig.base, '/v1/messages', user([image()]));
    expect(sentContent(rig)[1].text).toBe(RECOGNIZED_HIDDEN_NOTE);
  });

  test('ничего не распознано (фото без текста): блок не добавляется', async () => {
    rig = maskRig();
    await post(rig.base, '/v1/messages', user([image(), { type: 'text', text: 'что это' }]));
    expect(sentContent(rig).map((b) => b.type)).toEqual(['image', 'text']);
    expect(sentContent(rig)[1].text).toBe('что это');
    rig.media.state.recognized = { text: '', codes: [], hidden_text: false };
    await post(rig.base, '/v1/messages', user([image('QkJCQg==')]));
    expect(sentContent(rig, 1).length).toBe(1);
  });

  test('cache_control переносится на блок с распознанным текстом', async () => {
    rig = maskRig();
    rig.media.state.recognized = { text: CARD_TEXT, codes: [], hidden_text: false };
    await post(rig.base, '/v1/messages', user([image(PNG_DATA,
      { cache_control: { type: 'ephemeral' } })]));
    const content = sentContent(rig);
    expect(content[0].cache_control).toBeUndefined();
    expect(content[1].cache_control).toEqual({ type: 'ephemeral' });
  });

  test('картинка внутри tool_result: блок встаёт рядом, а не в корень', async () => {
    rig = maskRig();
    rig.media.state.recognized = { text: CARD_TEXT, codes: [], hidden_text: false };
    await post(rig.base, '/v1/messages', user([{ type: 'tool_result', tool_use_id: 'x',
      content: [image(), { type: 'text', text: 'конец' }] }]));
    const inner = sentContent(rig)[0].content as any[];
    expect(inner.map((b) => b.type)).toEqual(['image', 'text', 'text']);
    expect(inner[1].text).toContain('[PERSON_1]');
    expect(inner[2].text).toBe('конец');
  });

  test('детерминизм: два запроса - побайтно одинаковое тело, OCR один раз', async () => {
    rig = maskRig();
    rig.media.state.recognized = { text: CARD_TEXT, codes: [{ kind: 'qr', text: QR_TEXT }],
      hidden_text: true };
    await post(rig.base, '/v1/messages', user([image()]));
    await post(rig.base, '/v1/messages', user([image()]));
    expect(rig.upstream.hits[1]?.body).toBe(rig.upstream.hits[0]?.body ?? '');
    expect(rig.media.state.calls.length).toBe(1);
  });

  test('токены в тексте картинки и в сообщении пользователя согласованы', async () => {
    rig = maskRig();
    rig.media.state.recognized = { text: PERSON, codes: [], hidden_text: false };
    await post(rig.base, '/v1/messages', user([image(), { type: 'text', text: PERSON }]));
    const content = sentContent(rig);
    expect(content[1].text).toContain('[PERSON_1]');
    expect(content[2].text).toBe('[PERSON_1]');
  });

  test('вторая линия проверяет и распознанный текст (остаток ПДн - отказ)', async () => {
    rig = maskRig();
    rig.service.state.checkOnly.push('Сабина');
    rig.media.state.recognized = { text: 'Подпись: Сабина', codes: [], hidden_text: false };
    const res = await post(rig.base, '/v1/messages', user([image()]));
    expect(res.status).toBe(422);
    expect(rig.upstream.hits.length).toBe(0);
  });

  test('pdf-скан: после каждой страницы-картинки блок с её текстом', async () => {
    rig = maskRig();
    rig.media.state.recognized = { text: PERSON, codes: [], hidden_text: false };
    const spec = Buffer.from('SCAN:2').toString('base64');
    await post(rig.base, '/v1/messages', user([{ type: 'document',
      source: { type: 'base64', media_type: 'application/pdf', data: spec },
      cache_control: { type: 'ephemeral' } }]));
    const content = sentContent(rig);
    expect(content.map((b) => b.type)).toEqual(['image', 'text', 'image', 'text']);
    expect(content[1].text).toBe(`${RECOGNIZED_HEADER}\n[PERSON_1]`);
    expect(content[3].cache_control).toEqual({ type: 'ephemeral' });
    expect(rig.upstream.hits[0]?.body).not.toContain(PERSON);
  });

  test('сбой media-masker по-прежнему даёт пометку вместо вложения', async () => {
    rig = maskRig();
    rig.media.state.mode = 'http500';
    rig.media.state.recognized = { text: PERSON, codes: [], hidden_text: false };
    await post(rig.base, '/v1/messages', user([image()]));
    const content = sentContent(rig);
    expect(content.length).toBe(1);
    expect(content[0].text).toContain('вложение скрыто');
    expect(rig.upstream.hits[0]?.body).not.toContain(PERSON);
  });
});

describe('recognizedBlockText', () => {
  test('пусто - null', () => {
    expect(recognizedBlockText(NOTHING_RECOGNIZED)).toBeNull();
    expect(recognizedBlockText({ text: '  \n', codes: [], hiddenText: false })).toBeNull();
  });

  test('текст и пометка: заголовок, текст, пометка', () => {
    expect(recognizedBlockText({ text: 'а', codes: [], hiddenText: true }))
      .toBe(`${RECOGNIZED_HEADER}\nа\n${RECOGNIZED_HIDDEN_NOTE}`);
  });
});
