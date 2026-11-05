import type { ProxyConfig } from '../src/config';
import type { LogFields, Logger } from '../src/log';
import { PiiProxy, type RunningProxy } from '../src/proxy';

export const TEST_TOKEN = 'test-token';

/** Режим отказа фейкового сервиса. */
export type FakeMode = 'ok' | 'http500' | 'hang' | 'http401';

/** Фейковый сервис псевдонимизации: словарь подстановок вместо NER. */
export interface FakeService {
  readonly url: string;
  readonly state: {
    mode: FakeMode;
    bootId: string;
    /** Подстановки оригинал -> токен. */
    dict: Record<string, string>;
    /** Тексты, которые /check считает ПДн, хотя /pseudonymize их не маскирует. */
    checkOnly: string[];
    /** Вызовы: метод путь. */
    calls: string[];
    batches: { threadId: string; texts: string[]; caseLabels: unknown }[];
    /** Тела /pseudonymize_batch как пришли (проверка набора полей). */
    batchBodies: Record<string, unknown>[];
    deleted: string[];
    restoreFailAfter: number;
    restoreCount: number;
    /** boot_id, которые сервис примет после очередных пачек (имитация перезапуска). */
    bootAfterBatch: string[];
  };
  stop(): Promise<void>;
}

/** Запустить фейковый сервис на свободном порту. */
export function startFakeService(dict: Record<string, string> = {}): FakeService {
  const state: FakeService['state'] = {
    mode: 'ok', bootId: 'boot-1', dict, checkOnly: [], calls: [], batches: [], batchBodies: [],
    deleted: [],
    restoreFailAfter: Number.POSITIVE_INFINITY, restoreCount: 0, bootAfterBatch: [],
  };
  const mask = (t: string): string => {
    let out = t;
    for (const [orig, tok] of Object.entries(state.dict)) out = out.split(orig).join(tok);
    return out;
  };
  const restore = (t: string): string => {
    let out = t;
    for (const [orig, tok] of Object.entries(state.dict)) {
      const bare = tok.slice(1, -1);
      out = out.split(tok).join(orig).replace(new RegExp(`\\[${bare}\\|[a-z]{4}\\]`, 'g'), orig);
    }
    return out;
  };
  const server = Bun.serve({
    port: 0,
    hostname: '127.0.0.1',
    async fetch(req): Promise<Response> {
      const path = new URL(req.url).pathname;
      state.calls.push(`${req.method} ${path}`);
      if (state.mode === 'hang') await new Promise((r) => setTimeout(r, 5_000));
      if (state.mode === 'http500') return new Response('boom', { status: 500 });
      if (path === '/health') return Response.json({ status: 'ok', boot_id: state.bootId });
      if (state.mode === 'http401' || req.headers.get('authorization') !== `Bearer ${TEST_TOKEN}`) {
        return new Response('no', { status: 401 });
      }
      if (req.method === 'DELETE') {
        state.deleted.push(decodeURIComponent(path.replace('/threads/', '')));
        return new Response(null, { status: 204 });
      }
      const body = (await req.json()) as {
        thread_id?: string; text?: string; texts?: string[]; case_labels?: unknown;
      };
      if (path === '/pseudonymize_batch') {
        const nextBoot = state.bootAfterBatch.shift();
        if (nextBoot !== undefined) state.bootId = nextBoot;
        state.batches.push({
          threadId: body.thread_id ?? '', texts: body.texts ?? [], caseLabels: body.case_labels,
        });
        state.batchBodies.push(body);
        return Response.json({ items: (body.texts ?? []).map((t) => ({ text: mask(t) })) });
      }
      if (path === '/restore') {
        state.restoreCount++;
        if (state.restoreCount > state.restoreFailAfter) return new Response('x', { status: 500 });
        return Response.json({ text: restore(body.text ?? '') });
      }
      if (path === '/check') {
        const text = body.text ?? '';
        const hit = Object.keys(state.dict).some((o) => text.includes(o))
          || state.checkOnly.some((o) => text.includes(o));
        return Response.json({ has_pii: hit, types: hit ? ['PERSON'] : [] });
      }
      return new Response('nf', { status: 404 });
    },
  });
  return { url: `http://127.0.0.1:${server.port}`, state, stop: async () => {
    await server.stop(true);
  } };
}

/** Режим отказа фейкового media-masker. */
export type FakeMediaMode = 'ok' | 'http500' | 'refuse422' | 'refuse413' | 'hang';

/** Фейковый media-masker: картинку «закрашивает» префиксом, PDF разбирает по тестовой разметке. */
export interface FakeMedia {
  readonly url: string;
  readonly state: {
    mode: FakeMediaMode;
    calls: string[];
    tokenSeen: string[];
    /** Что «распознано» на каждой картинке и странице скана (как поле recognized сервиса). */
    recognized?: { text: string; codes: { kind: string; text: string }[]; hidden_text: boolean };
  };
  stop(): Promise<void>;
}

/** Токен фейкового media-masker. */
export const MEDIA_TOKEN = 'media-token';

/** Как фейк «маскирует» base64-картинку: оригинал в ответе не виден. */
export function fakeMaskedData(data: string): string {
  return Buffer.from(`MASKED:${data.length}`).toString('base64');
}

/**
 * Запустить фейковый media-masker. PDF задаётся содержимым base64: `TEXT:стр1|стр2` - страницы
 * с текстовым слоем, `SCAN:n` - n страниц-растров.
 */
export function startFakeMedia(): FakeMedia {
  const state: FakeMedia['state'] = { mode: 'ok', calls: [], tokenSeen: [] };
  const withRecognized = (): object => state.recognized === undefined ? {}
    : { recognized: state.recognized };
  const server = Bun.serve({
    port: 0,
    hostname: '127.0.0.1',
    async fetch(req): Promise<Response> {
      const path = new URL(req.url).pathname;
      state.calls.push(path);
      state.tokenSeen.push(req.headers.get('authorization') ?? '');
      if (state.mode === 'hang') await new Promise((r) => setTimeout(r, 5_000));
      if (state.mode === 'http500') return new Response('boom', { status: 500 });
      if (state.mode === 'refuse422') return Response.json({ error: 'image_undecodable' },
        { status: 422 });
      if (state.mode === 'refuse413') return Response.json({ error: 'pdf_too_many_pages' },
        { status: 413 });
      const body = (await req.json()) as { media_type: string; data: string };
      if (path === '/mask_image') {
        return Response.json({ media_type: body.media_type, data: fakeMaskedData(body.data),
          ...withRecognized() });
      }
      const spec = Buffer.from(body.data, 'base64').toString('utf8');
      const pages = spec.startsWith('TEXT:')
        ? spec.slice(5).split('|').map((text, index) => ({ index, text, image: null }))
        : Array.from({ length: Number(spec.slice(5)) }, (_v, index) => ({ index, text: null,
          image: { media_type: 'image/jpeg', data: fakeMaskedData(`page${index}`) },
          ...withRecognized() }));
      return Response.json({ kind: spec.startsWith('TEXT:') ? 'text' : 'images', pages });
    },
  });
  return { url: `http://127.0.0.1:${server.port}`, state, stop: async () => {
    await server.stop(true);
  } };
}

/** Один принятый фейковым upstream запрос. */
export interface UpstreamHit {
  readonly method: string;
  readonly path: string;
  readonly headers: Headers;
  readonly body: string;
}

/** Ответ фейкового upstream. */
export interface UpstreamReply {
  readonly status?: number;
  readonly contentType: string;
  /** Куски тела; между ними небольшая пауза. */
  readonly chunks: string[];
}

/** Фейковый upstream: запоминает запросы, отдаёт заданный ответ. */
export interface FakeUpstream {
  readonly url: string;
  readonly hits: UpstreamHit[];
  reply: UpstreamReply;
  /** Ответ в зависимости от запроса (если задан, важнее `reply`). */
  replyFor?: (hit: UpstreamHit) => UpstreamReply;
  stop(): Promise<void>;
}

/** SSE-событие в текст. */
export function sse(name: string, data: unknown): string {
  return `event: ${name}\ndata: ${JSON.stringify(data)}\n\n`;
}

/** Запустить фейковый upstream. */
export function startFakeUpstream(reply: UpstreamReply): FakeUpstream {
  const hits: UpstreamHit[] = [];
  const self: FakeUpstream = { url: '', hits, reply, stop: async () => undefined };
  const server = Bun.serve({
    port: 0,
    hostname: '127.0.0.1',
    async fetch(req): Promise<Response> {
      hits.push({ method: req.method, path: new URL(req.url).pathname, headers: req.headers,
        body: await req.text() });
      const r = self.replyFor?.(hits[hits.length - 1] as UpstreamHit) ?? self.reply;
      const enc = new TextEncoder();
      const stream = new ReadableStream<Uint8Array>({
        async start(c): Promise<void> {
          for (const chunk of r.chunks) {
            c.enqueue(enc.encode(chunk));
            await new Promise((res) => setTimeout(res, 2));
          }
          c.close();
        },
      });
      return new Response(stream, { status: r.status ?? 200,
        headers: { 'content-type': r.contentType } });
    },
  });
  return Object.assign(self, {
    url: `http://127.0.0.1:${server.port}`,
    stop: async () => {
      await server.stop(true);
    },
  });
}

/** Журнал в память. */
export function memoryLogger(): Logger & { lines: { event: string; fields: LogFields }[] } {
  const lines: { event: string; fields: LogFields }[] = [];
  return { lines, log: (event, fields = {}) => void lines.push({ event, fields }) };
}

/** Собрать конфиг прокси для тестов. */
export function testConfig(over: Partial<ProxyConfig>): ProxyConfig {
  return {
    port: 0, host: '127.0.0.1', upstream: '', agentId: 'dev', pseudonymizerUrl: '',
    pseudonymizerToken: TEST_TOKEN, timeoutMs: 1_000, imagePolicy: 'strip', caseLabels: false,
    mediaMaskerUrl: '', mediaMaskerTimeoutMs: 1_000, ...over,
  };
}

/** Стенд: фейковые сервис и upstream плюс настоящий прокси. */
export interface Rig {
  readonly service: FakeService;
  readonly upstream: FakeUpstream;
  readonly proxy: RunningProxy;
  readonly logger: ReturnType<typeof memoryLogger>;
  readonly media: FakeMedia;
  readonly base: string;
  stop(): Promise<void>;
}

/** Поднять стенд. */
export function startRig(
  dict: Record<string, string>,
  reply: UpstreamReply,
  over: Partial<ProxyConfig> = {},
): Rig {
  const service = startFakeService(dict);
  const upstream = startFakeUpstream(reply);
  const media = startFakeMedia();
  const logger = memoryLogger();
  const config = testConfig({ upstream: upstream.url, pseudonymizerUrl: service.url,
    mediaMaskerUrl: media.url, mediaMaskerToken: MEDIA_TOKEN, ...over });
  const proxy = new PiiProxy(config, { logger }).start();
  return {
    service, upstream, proxy, logger, media, base: `http://127.0.0.1:${proxy.port}`,
    stop: async () => {
      await proxy.stop();
      await upstream.stop();
      await service.stop();
      await media.stop();
    },
  };
}

/** Ответ-сообщение (SSE) с заданными text_delta в одном блоке. */
export function textStream(deltas: string[]): UpstreamReply {
  const chunks = [
    sse('message_start', { type: 'message_start', message: { id: 'm', usage: {} } }),
    sse('content_block_start', { type: 'content_block_start', index: 0,
      content_block: { type: 'text', text: '' } }),
    ...deltas.map((text) => sse('content_block_delta', { type: 'content_block_delta', index: 0,
      delta: { type: 'text_delta', text } })),
    sse('content_block_stop', { type: 'content_block_stop', index: 0 }),
    sse('message_stop', { type: 'message_stop' }),
  ];
  return { contentType: 'text/event-stream', chunks };
}

/** Прочитать SSE-ответ прокси и собрать итоговый текст text_delta блока 0. */
export async function collectText(res: Response): Promise<{ text: string; events: string[] }> {
  const raw = await res.text();
  const events = raw.split('\n\n').filter((e) => e !== '');
  let text = '';
  for (const e of events) {
    const m = /^data: (.*)$/m.exec(e);
    if (m === null) continue;
    const j = JSON.parse(m[1] as string) as { delta?: { type?: string; text?: string } };
    if (j.delta?.type === 'text_delta') text += j.delta.text ?? '';
  }
  return { text, events };
}

/** Тело запроса с одним пользовательским сообщением. */
export function post(base: string, path: string, body: unknown, headers: HeadersInit = {}):
  Promise<Response> {
  return fetch(`${base}${path}`, { method: 'POST', body: JSON.stringify(body),
    headers: { 'content-type': 'application/json', 'x-claude-code-session-id': 's1',
      ...headers } });
}
