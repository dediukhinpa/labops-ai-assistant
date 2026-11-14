import { randomUUID } from 'node:crypto';
import type { ProxyConfig } from './config';
import {
  HEALTH_ROUTE, MAX_REQUEST_BODY_BYTES, QUOTA_PROBE_MAX_TOKENS, QUOTA_PROBE_TEXT,
  SERVER_IDLE_TIMEOUT_S, SESSION_HEADER, UPSTREAM_ERROR_BODY_MAX_BYTES, UPSTREAM_LOG_HEADER,
} from './proxy-constants';
import {
  FileConsentGate, HttpMediaMasker, HttpPseudonymizer, MediaMaskerError, MediaProcessor, PseudonymizerError,
  RequestMasker, RequestRejectedError, Restorer, STATUS_BAD_GATEWAY, STATUS_BAD_REQUEST,
  STATUS_PII_FOUND, STATUS_UNAVAILABLE, STATUS_UNSUPPORTED_ENCODING, checkWindows, errorResponse,
  formatSse, isObject, parseSse, restoreMessageJson, restoreSse, sessionFingerprint,
  type JsonObject, type LogFields, type Logger, type Pseudonymizer, type SseEvent,
} from '@labops/pii';
import { SessionStuckTracker, type StuckSignal } from './session-stuck';

const MASKED_ROUTES: ReadonlySet<string> = new Set(['/v1/messages', '/v1/messages/count_tokens']);
const DROP_REQUEST_HEADERS = ['host', 'content-length', 'accept-encoding'];
const DROP_RESPONSE_HEADERS = ['content-encoding', 'content-length', 'transfer-encoding'];

/** Зависимости прокси (в тестах подменяются). */
export interface ProxyDeps {
  readonly logger: Logger;
  readonly service?: Pseudonymizer;
  /** Приёмник сигнала «сессия застряла» (файл для watchdog); без него только журнал. */
  readonly onStuck?: (signal: StuckSignal) => void;
  /** Счётчик застревания (в тестах - с малым порогом и своими часами). */
  readonly stuckTracker?: SessionStuckTracker;
}

/** Запущенный прокси. */
export interface RunningProxy {
  readonly port: number;
  stop(): Promise<void>;
}

/** Контекст одного запроса. */
interface RequestContext {
  readonly threadId: string;
  readonly ephemeral: boolean;
  readonly route: string;
  readonly session: string;
  readonly started: number;
  /** Тред использовался сервисом (иначе удалять нечего). */
  used: boolean;
}

/** Прокси CLI -> API: маскирует запросы, восстанавливает ответы. */
export class PiiProxy {
  private readonly service: Pseudonymizer;
  private readonly masker: RequestMasker;
  private readonly stuck: SessionStuckTracker;

  constructor(
    private readonly config: ProxyConfig,
    private readonly deps: ProxyDeps,
  ) {
    this.service =
      deps.service
      ?? new HttpPseudonymizer({
        baseUrl: config.pseudonymizerUrl,
        token: config.pseudonymizerToken,
        timeoutMs: config.timeoutMs,
        caseLabels: config.caseLabels,
      });
    // logger нужен, чтобы событие pii_after_mask_fixed (дозамаскирование/скрытие листа вместо
    // 422) попадало в журнал прокси: иначе оператор не увидит, что лист был закрыт заглушкой.
    this.masker = new RequestMasker(
      this.service, config.imagePolicy, config.caseLabels, this.mediaProcessor(),
      { logger: deps.logger });
    this.stuck = deps.stuckTracker ?? new SessionStuckTracker();
  }

  /** Клиент media-masker с кэшем: только при политике mask (конфиг гарантирует токен). */
  private mediaProcessor(): MediaProcessor | undefined {
    const {
      imagePolicy, mediaMaskerUrl, mediaMaskerToken, mediaMaskerTimeoutMs, mediaOriginalIfClean,
      mediaConsentDir, agentId,
    } = this.config;
    if (imagePolicy !== 'mask' || mediaMaskerToken === undefined) return undefined;
    return new MediaProcessor(new HttpMediaMasker({
      baseUrl: mediaMaskerUrl, token: mediaMaskerToken, timeoutMs: mediaMaskerTimeoutMs,
      // Только при явном включении: иначе запрос к media-masker прежний
      ...(mediaOriginalIfClean === true ? { originalIfClean: true } : {}),
    }), {
      logger: this.deps.logger,
      // Разрешение владельца на оригинал: только при включённой функции, только для своего агента
      ...(mediaConsentDir !== undefined
        ? { consent: new FileConsentGate({ dir: mediaConsentDir, agentId }) } : {}),
    });
  }

  /** Запустить HTTP-сервер. */
  start(): RunningProxy {
    const server = Bun.serve({
      port: this.config.port,
      hostname: this.config.host,
      idleTimeout: SERVER_IDLE_TIMEOUT_S,
      maxRequestBodySize: MAX_REQUEST_BODY_BYTES,
      fetch: (req) => this.handle(req),
    });
    return {
      port: server.port ?? this.config.port,
      stop: async (): Promise<void> => {
        await server.stop(true);
      },
    };
  }

  /** Обработать один запрос. */
  async handle(req: Request): Promise<Response> {
    const url = new URL(req.url);
    // Проверка живости для watchdog: без авторизации и без обращения к API. Это не маршрут
    // API, поэтому в upstream он не уходит; прокси слушает только 127.0.0.1.
    if (req.method === 'GET' && url.pathname === HEALTH_ROUTE) {
      return Response.json({ status: 'ok' });
    }
    const sessionId = req.headers.get(SESSION_HEADER);
    const ephemeral = sessionId === null || sessionId === '';
    const ctx: RequestContext = {
      threadId: `${this.config.agentId}:${ephemeral ? `req-${randomUUID()}` : sessionId}`,
      ephemeral,
      route: url.pathname,
      session: ephemeral ? 'none' : sessionFingerprint(sessionId),
      started: performance.now(),
      used: false,
    };
    let keepThread = false;
    try {
      const res = await this.route(req, url, ctx);
      keepThread = res.deferredCleanup;
      // Дошёл до upstream: серия отказов этой сессии прервана.
      if (!ctx.ephemeral) this.stuck.recordSuccess(ctx.session);
      return res.response;
    } catch (e) {
      return this.failure(e, ctx);
    } finally {
      if (ctx.ephemeral && ctx.used && !keepThread) await this.dropThread(ctx);
    }
  }

  private async route(
    req: Request,
    url: URL,
    ctx: RequestContext,
  ): Promise<{ response: Response; deferredCleanup: boolean }> {
    const hasBody = req.method !== 'GET' && req.method !== 'HEAD' && req.body !== null;
    let body: string | undefined;
    if (hasBody) {
      const enc = req.headers.get('content-encoding');
      if (enc !== null && enc.trim().toLowerCase() !== 'identity' && enc.trim() !== '') {
        throw new RequestRejectedError(
          STATUS_UNSUPPORTED_ENCODING,
          'Сжатое тело запроса не поддерживается: проверить его на ПДн нельзя.',
          'unsupported_content_encoding',
        );
      }
      body = await req.text();
    }
    const masked = req.method === 'POST' && MASKED_ROUTES.has(url.pathname);
    let outBody = body;
    let stats: LogFields = {};
    let remember: ((restored: string, original: string) => void) | undefined;
    let probe = false;
    if (masked && body !== undefined) {
      const parsed = parseJsonBody(body);
      if (isQuotaProbe(parsed)) {
        // Проба квоты: константный текст, ПДн в нём нет. Маскер дописал бы в неё system-вставку,
        // и upstream отвечал на такую пробу 429 (в норме claude шлёт её без system). Уходит
        // байт-в-байт как пришла.
        probe = true;
        stats = { masked_leaves: 0 };
      } else {
        ctx.used = true;
        const s = await this.masker.mask(parsed, ctx.threadId);
        stats = { masked_leaves: s.leaves, cache_hits: s.cacheHits,
          remembered_leaves: s.rememberedLeaves, forgotten_leaves: s.forgottenLeaves,
          masked_attachments: s.maskedAttachments,
          ...(s.consentOriginals > 0 ? { consent_originals: s.consentOriginals } : {}),
          ...(Object.keys(s.blockedReasons).length > 0
            ? { blocked_attachments: s.blockedReasons } : {}) };
        // Эфемерный тред живёт один запрос: его историю никто не вернёт, помнить нечего.
        if (!ctx.ephemeral) {
          remember = (restored, original): void =>
            this.masker.remember(ctx.threadId, s.bootId, restored, original);
        }
        outBody = JSON.stringify(parsed);
      }
    } else if (body !== undefined && body !== '') {
      await this.checkRaw(body);
    }
    const upstream = await this.callUpstream(req, url, outBody);
    const restorer = new Restorer(this.service, ctx.threadId, remember);
    const type = upstream.headers.get('content-type') ?? '';
    const headers = new Headers(upstream.headers);
    DROP_RESPONSE_HEADERS.forEach((h) => headers.delete(h));
    const ok = upstream.status >= 200 && upstream.status < 300;
    // Отказ upstream проходит клиенту как есть; в журнал - только то, чем его можно опознать
    // (тип ошибки, request-id, лимиты), без тела и текстов запроса.
    if (!ok) await this.logUpstreamError(upstream, ctx, probe);
    const finish = (extra: LogFields = {}): void =>
      this.deps.logger.log('request', {
        route: ctx.route,
        status: upstream.status,
        duration_ms: Math.round(performance.now() - ctx.started),
        session: ctx.session,
        ...stats,
        ...extra,
      });
    if (masked && ok && type.includes('text/event-stream') && upstream.body !== null) {
      const events = restoreSse(parseSse(upstream.body), restorer);
      const stream = this.sseBody(events, restorer, ctx, finish);
      return { response: new Response(stream, { status: upstream.status, headers }),
        deferredCleanup: true };
    }
    if (masked && ok && type.includes('application/json')) {
      const parsed: unknown = await upstream.json();
      const restored = isObject(parsed) ? await restoreMessageJson(parsed, restorer) : parsed;
      finish({ restored_tokens: restorer.restoredTokens });
      const response = new Response(JSON.stringify(restored), { status: upstream.status, headers });
      return { response, deferredCleanup: false };
    }
    finish();
    return { response: new Response(upstream.body, { status: upstream.status, headers }),
      deferredCleanup: false };
  }

  /** Событие `upstream_error`: статус, error.type, request-id и заголовки лимитов. */
  private async logUpstreamError(
    upstream: Response,
    ctx: RequestContext,
    probe: boolean,
  ): Promise<void> {
    const headers: Record<string, string> = {};
    upstream.headers.forEach((value, name) => {
      if (UPSTREAM_LOG_HEADER.test(name)) headers[name] = value;
    });
    let errorType: string | undefined;
    try {
      const raw = (await upstream.clone().text()).slice(0, UPSTREAM_ERROR_BODY_MAX_BYTES);
      const parsed: unknown = JSON.parse(raw);
      const error = isObject(parsed) ? parsed.error : undefined;
      if (isObject(error) && typeof error.type === 'string') errorType = error.type;
    } catch {
      // тело не JSON или оборвано: тип ошибки в журнал не попадёт
    }
    const fields: LogFields & UpstreamErrorFields = {
      route: ctx.route,
      status: upstream.status,
      session: ctx.session,
      probe,
      upstream_headers: headers,
      ...(errorType === undefined ? {} : { upstream_error_type: errorType }),
    };
    this.deps.logger.log('upstream_error', fields);
  }

  private sseBody(
    events: AsyncGenerator<SseEvent>,
    restorer: Restorer,
    ctx: RequestContext,
    finish: (extra?: LogFields) => void,
  ): ReadableStream<Uint8Array> {
    const enc = new TextEncoder();
    let closed = false;
    const done = async (): Promise<void> => {
      if (closed) return;
      closed = true;
      finish({ restored_tokens: restorer.restoredTokens });
      if (ctx.ephemeral && ctx.used) await this.dropThread(ctx);
    };
    return new ReadableStream<Uint8Array>({
      async pull(controller): Promise<void> {
        const r = await events.next();
        if (r.done === true) {
          controller.close();
          await done();
          return;
        }
        controller.enqueue(enc.encode(formatSse(r.value)));
      },
      async cancel(): Promise<void> {
        await events.return(undefined);
        await done();
      },
    });
  }

  private async callUpstream(req: Request, url: URL, body: string | undefined): Promise<Response> {
    const headers = new Headers(req.headers);
    DROP_REQUEST_HEADERS.forEach((h) => headers.delete(h));
    try {
      return await fetch(`${this.config.upstream}${url.pathname}${url.search}`, {
        method: req.method,
        headers,
        body: body ?? null,
        redirect: 'manual',
        signal: req.signal,
      });
    } catch {
      throw new RequestRejectedError(STATUS_BAD_GATEWAY, 'Upstream недоступен.', 'upstream_error');
    }
  }

  /** Прочие POST с телом: /check, находка - 422, иначе тело идёт как есть. */
  private async checkRaw(body: string): Promise<void> {
    const types = new Set<string>();
    for (const w of checkWindows(body)) {
      const r = await this.service.check(w);
      if (r.hasPii) r.types.forEach((t) => types.add(t));
    }
    if (types.size > 0) {
      const list = [...types].sort();
      throw new RequestRejectedError(
        STATUS_PII_FOUND,
        `Запрос не отправлен: в теле найдены персональные данные (виды: ${list.join(', ')}).`,
        'pii_in_passthrough',
        list,
      );
    }
  }

  private failure(e: unknown, ctx: RequestContext): Response {
    const base = { route: ctx.route, duration_ms: Math.round(performance.now() - ctx.started),
      session: ctx.session };
    if (e instanceof RequestRejectedError) {
      this.deps.logger.log('request_rejected', {
        ...base,
        status: e.status,
        code: e.code,
        ...(e.piiTypes.length > 0 ? { pii_types: e.piiTypes } : {}),
      });
      if (e.status === STATUS_PII_FOUND) this.noteFailure(ctx, e.code);
      const type = e.status === STATUS_BAD_GATEWAY ? 'api_error' : 'invalid_request_error';
      return errorResponse(e.status, type, e.message);
    }
    if (e instanceof PseudonymizerError) {
      this.deps.logger.log('pseudonymizer_failure', { ...base, status: STATUS_UNAVAILABLE,
        code: e.code });
      this.noteFailure(ctx, e.code);
      return errorResponse(STATUS_UNAVAILABLE, 'api_error',
        'Сервис маскирования данных недоступен: запрос не отправлен.');
    }
    if (e instanceof MediaMaskerError) {
      this.deps.logger.log('media_masker_failure', { ...base, status: STATUS_UNAVAILABLE,
        code: e.code });
      return errorResponse(STATUS_UNAVAILABLE, 'api_error',
        'Сервис маскирования вложений недоступен: запрос не отправлен.');
    }
    if (e instanceof BadBodyError) {
      this.deps.logger.log('request_rejected', { ...base, status: STATUS_BAD_REQUEST,
        code: 'bad_body' });
      return errorResponse(STATUS_BAD_REQUEST, 'invalid_request_error', e.message);
    }
    this.deps.logger.log('request_failed', { ...base, status: STATUS_UNAVAILABLE,
      code: e instanceof Error ? e.name : 'unknown' });
    this.noteFailure(ctx, 'internal');
    return errorResponse(STATUS_UNAVAILABLE, 'api_error', 'Внутренняя ошибка pii-proxy.');
  }

  /** Учесть отказ 422/503 сессии; при серии подряд - событие session_stuck (без ПДн). */
  private noteFailure(ctx: RequestContext, code: string): void {
    if (ctx.ephemeral) return;
    const signal = this.stuck.recordFailure(ctx.session, code);
    if (signal === undefined) return;
    this.deps.logger.log('session_stuck', { session: signal.session, count: signal.count,
      code: signal.code });
    this.deps.onStuck?.(signal);
  }

  private async dropThread(ctx: RequestContext): Promise<void> {
    try {
      await this.service.deleteThread(ctx.threadId);
      // labops-pii 1.0.2: после удаления треда на сервисе кэш масок треда забывается, иначе
      // старая маска совпала бы с новой нумерацией сервиса.
      this.masker.forgetThread(ctx.threadId);
    } catch (e) {
      this.deps.logger.log('thread_delete_failed', { route: ctx.route,
        code: e instanceof PseudonymizerError ? e.code : 'unknown' });
    }
  }
}

class BadBodyError extends Error {}

/** Поля события `upstream_error` сверх общих полей журнала. */
interface UpstreamErrorFields {
  readonly probe?: boolean;
  readonly upstream_error_type?: string;
  readonly upstream_headers?: Readonly<Record<string, string>>;
}

/**
 * Служебная проба квоты claude: один user-текст «quota», max_tokens 1, без system, tools и
 * прочих полей, меняющих смысл запроса.
 */
export function isQuotaProbe(body: JsonObject): boolean {
  if (body.max_tokens !== QUOTA_PROBE_MAX_TOKENS) return false;
  if ('system' in body || 'tools' in body || 'tool_choice' in body || 'thinking' in body) {
    return false;
  }
  const messages = body.messages;
  if (!Array.isArray(messages) || messages.length !== 1) return false;
  const only: unknown = messages[0];
  return isObject(only) && only.role === 'user' && only.content === QUOTA_PROBE_TEXT;
}

function parseJsonBody(body: string): JsonObject {
  let v: unknown;
  try {
    v = JSON.parse(body);
  } catch {
    throw new BadBodyError('Тело запроса не JSON.');
  }
  if (!isObject(v)) throw new BadBodyError('Тело запроса должно быть JSON-объектом.');
  return v;
}
