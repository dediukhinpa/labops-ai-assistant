import { afterAll, describe, expect, test } from 'bun:test';
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { post, startRig, textStream, type Rig } from './helpers';

/**
 * Сквозная проверка с настоящими media-masker и Tesseract. Пропускается без окружения:
 * MEDIA_E2E_URL, MEDIA_E2E_TOKEN, MEDIA_E2E_DIR (каталог после pii-proxy/scripts/
 * make_e2e_fixtures.py). Закрашенные картинки, ушедшие «модели», пишутся в MEDIA_E2E_DIR/out-*.png
 * для повторного OCR снаружи.
 */
const URL_ = process.env.MEDIA_E2E_URL;
const TOKEN = process.env.MEDIA_E2E_TOKEN;
const DIR = process.env.MEDIA_E2E_DIR;
const enabled = URL_ !== undefined && TOKEN !== undefined && DIR !== undefined;
const e2e = enabled ? describe : describe.skip;
const E2E_TIMEOUT_MS = 120_000;
const DICT = { 'Иванов Пётр Сергеевич': '[PERSON_1]', 'Peter Ivanov': '[PERSON_2]',
  '+7 912 345-67-89': '[PHONE_1]' };

let rig: Rig | undefined;
afterAll(async () => { await rig?.stop(); });

function b64(name: string): string {
  return readFileSync(join(DIR ?? '', name)).toString('base64');
}

e2e('сквозной прогон с настоящим OCR', () => {
  test('фото и PDF: исходные байты не уходят, картинка закрашена', async () => {
    rig = startRig(DICT, textStream(['ок']), { imagePolicy: 'mask', mediaMaskerUrl: URL_ ?? '',
      mediaMaskerToken: TOKEN ?? '', mediaMaskerTimeoutMs: E2E_TIMEOUT_MS });
    const files = ['person.png', 'passport.png'];
    const content: unknown[] = files.map((f) => ({ type: 'image', source: { type: 'base64',
      media_type: 'image/png', data: b64(f) } }));
    content.push({ type: 'image', source: { type: 'base64', media_type: 'image/jpeg',
      data: b64('phone.jpg') } });
    for (const f of ['scan.pdf', 'text.pdf']) {
      content.push({ type: 'document', source: { type: 'base64', media_type: 'application/pdf',
        data: b64(f) } });
    }
    const res = await post(rig.base, '/v1/messages', { messages: [{ role: 'user', content }] });
    expect(res.status).toBe(200);
    const raw = rig.upstream.hits[0]?.body ?? '';
    for (const f of [...files, 'phone.jpg', 'scan.pdf', 'text.pdf']) {
      expect(raw).not.toContain(b64(f));
    }
    expect(raw).not.toContain('"application/pdf"');
    expect(raw).not.toContain('Peter Ivanov');
    expect(raw).not.toContain('912 345');
    const sent = JSON.parse(raw).messages[0].content as { type: string; source?: { data: string } }[];
    const images = sent.filter((b) => b.type === 'image');
    expect(images.length).toBe(5); // три фото и две страницы скана
    images.forEach((b, i) => writeFileSync(join(DIR ?? '', `out-${i}.img`),
      Buffer.from(b.source?.data ?? '', 'base64')));
  }, E2E_TIMEOUT_MS);
});
