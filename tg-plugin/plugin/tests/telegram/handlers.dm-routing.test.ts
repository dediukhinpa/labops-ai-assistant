// Этап 1b: изоляция лички по собеседникам.
//
// Оператор остаётся в главной сессии (sendChannelNotification), личка другого
// разрешённого человека уходит через router.dispatch со своим chat_id.
// Тесты не поднимают tmux: роутер подменён шпионом.

import { describe, expect, test } from 'bun:test'
import { mkdtempSync, rmSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'
import type { Context } from 'grammy'

import {
  handleInboundPhoto,
  handleInboundText,
  sendAlbumNotification,
  type AlbumEntry,
  type HandlerDeps,
} from '../../src/telegram/handlers.js'
import type { Album } from '../../src/telegram/album-buffer.js'
import {
  checkDmRouterAccess,
  isOperatorUser,
  resolveDmRoutingMode,
  warnIfSharedDmContext,
} from '../../src/telegram/dm-routing.js'
import type { ChatPolicy, MultichatPolicy } from '../../src/chats/policy-loader.js'
import type { AppConfig, StatePaths } from '../../src/config.js'
import { createLogger, type Logger } from '../../src/log.js'
import type { TelegramApi } from '../../src/channel/tools.js'
import type { BotIdentity } from '../../src/prompt/build.js'
import type { MultichatRouter } from '../../src/router/multichat-router.js'
import type { InboundMessage } from '../../src/router/inbox-bridge.js'

const silentLog = createLogger('test', {
  stream: { write: () => true } as unknown as NodeJS.WritableStream,
})

const OPERATOR_ID = 100000001
const PERSON_A_ID = 200000001
const PERSON_B_ID = 200000002
const BOT_ID = 100000002
const MESSAGE_ID = 42

type DmRouting = 'main' | 'per_person'

function makeConfig(overrides: Partial<AppConfig> = {}): AppConfig {
  const everyone = [OPERATOR_ID, PERSON_A_ID, PERSON_B_ID]
  return {
    bot_id: BOT_ID,
    dm_only: true,
    allowed_user_ids: everyone,
    allowed_chat_ids: everyone,
    operator_user_ids: [OPERATOR_ID],
    status: {
      enabled: false,
      interval_ms: 700,
      ttl_ms: 300_000,
      delete_on_complete: true,
      delete_on_expire: true,
      suppress_typing_bubble: false,
    },
    album: { flush_ms: 50 },
    voice: { provider: 'groq', language: 'ru', model: 'whisper-large-v3-turbo' },
    webhook: { enabled: false, host: '127.0.0.1', port: 0 },
    permission_relay: { enabled: true, allowed_user_ids: [OPERATOR_ID], bash_only_proof: true },
    commands: { help: true, status: true, stop: true, reset: true },
    watcher: { enabled: false, debounce_ms: 10_000, busy_threshold_ms: 30_000 },
    ...overrides,
  } as unknown as AppConfig
}

function makeDmChatPolicy(): ChatPolicy {
  return {
    mode: 'private',
    streaming: 'off',
    tmux_mirror: false,
    edit_message_progress: false,
    delivery: 'final_only',
    persona_file: 'atlas.md',
    handoff_file: 'handoff.md',
    system_reminder: '',
    idle_ttl_ms: 1_800_000,
    max_queue_depth: 1,
  }
}

function makePolicy(personIds: number[] = [PERSON_A_ID, PERSON_B_ID]): MultichatPolicy {
  const ids = personIds.map(String)
  const chats: Record<string, ChatPolicy> = {}
  for (const id of ids) chats[id] = makeDmChatPolicy()
  return {
    version: 1,
    allowlist: { chats: ids, users: [String(OPERATOR_ID), ...ids] },
    mention_allowlist: [String(OPERATOR_ID)],
    chats,
  } as unknown as MultichatPolicy
}

function makeStatePaths(): StatePaths {
  const root = mkdtempSync(join(tmpdir(), 'labops-dm-routing-'))
  return {
    root,
    env: join(root, '.env'),
    config: join(root, 'config.json'),
    allowlist: join(root, 'allowlist.json'),
    pid: join(root, 'bot.pid'),
    lock: join(root, 'bot.lock'),
    updateOffset: join(root, 'update-offset'),
    inbox: join(root, 'inbox'),
    sessionIds: join(root, 'session-ids'),
    deadLetterUpdates: join(root, 'dead-letter', 'updates'),
    deadLetterWebhook: join(root, 'dead-letter', 'webhook'),
    logs: {
      server: join(root, 'logs', 'server.log'),
      telegram: join(root, 'logs', 'telegram.log'),
      permissions: join(root, 'logs', 'permissions.jsonl'),
      webhook: join(root, 'logs', 'webhook.log'),
      ask_user_question: join(root, 'logs', 'ask-user-question.jsonl'),
    },
  }
}

interface Harness {
  deps: HandlerDeps
  routed: InboundMessage[]
  notified: unknown[]
  verdicts: unknown[]
  cleanup: () => void
}

function makeHarness(opts: {
  withRouter: boolean
  config?: Partial<AppConfig>
  policy?: MultichatPolicy
}): Harness {
  const routed: InboundMessage[] = []
  const notified: unknown[] = []
  const verdicts: unknown[] = []
  const statePaths = makeStatePaths()
  const router = {
    dispatch: async (msg: InboundMessage) => {
      routed.push(msg)
    },
  } as unknown as MultichatRouter
  const telegramApi = {
    setMessageReaction: async () => undefined,
    sendMessage: async () => ({ message_id: 1 }),
  } as unknown as TelegramApi
  const bot: BotIdentity = { id: BOT_ID, username: 'canarybot' }
  const deps: HandlerDeps = {
    server: {
      notification: async (msg: unknown) => {
        notified.push(msg)
      },
    } as unknown as HandlerDeps['server'],
    config: makeConfig(opts.config),
    statePaths,
    telegramApi,
    log: silentLog,
    bot,
    botApi: { api: {} } as unknown as HandlerDeps['botApi'],
    botToken: 'fake-token',
    env: {},
    permissionHooks: {
      isPending: () => true,
      consumePending: () => undefined,
      emitVerdict: async (v: unknown) => {
        verdicts.push(v)
      },
    } as unknown as NonNullable<HandlerDeps['permissionHooks']>,
    ...(opts.withRouter ? { router, policy: opts.policy ?? makePolicy() } : {}),
  }
  return {
    deps,
    routed,
    notified,
    verdicts,
    cleanup: () => rmSync(statePaths.root, { recursive: true, force: true }),
  }
}

function makeDmCtx(fromId: number, text: string, extra: Record<string, unknown> = {}): Context {
  const chat = { id: fromId, type: 'private' as const }
  const from = { id: fromId, is_bot: false, first_name: 'x', username: `u${fromId}` }
  return {
    chat,
    from,
    me: { id: BOT_ID, username: 'canarybot' },
    message: { message_id: MESSAGE_ID, date: 1700000000, text, chat, from, ...extra },
  } as unknown as Context
}

describe('личка: оператор против остальных', () => {
  test('оператор идёт в главную сессию, роутер не трогается', async () => {
    const h = makeHarness({ withRouter: true })
    await handleInboundText(makeDmCtx(OPERATOR_ID, 'привет'), h.deps)
    expect(h.routed.length).toBe(0)
    expect(h.notified.length).toBe(1)
    h.cleanup()
  })

  test('не-оператор идёт в router.dispatch со своим chat_id', async () => {
    const h = makeHarness({ withRouter: true })
    await handleInboundText(makeDmCtx(PERSON_A_ID, 'привет'), h.deps)
    expect(h.notified.length).toBe(0)
    expect(h.routed.length).toBe(1)
    expect(h.routed[0]?.chat_id).toBe(String(PERSON_A_ID))
    expect(h.routed[0]?.user_id).toBe(String(PERSON_A_ID))
    expect(h.routed[0]?.message_id).toBe(String(MESSAGE_ID))
    h.cleanup()
  })

  test('два человека -- два разных chat_id (две сессии)', async () => {
    const h = makeHarness({ withRouter: true })
    await handleInboundText(makeDmCtx(PERSON_A_ID, 'я А'), h.deps)
    await handleInboundText(makeDmCtx(PERSON_B_ID, 'я Б'), h.deps)
    const chats = h.routed.map((m) => m.chat_id)
    expect(chats).toEqual([String(PERSON_A_ID), String(PERSON_B_ID)])
    expect(h.notified.length).toBe(0)
    h.cleanup()
  })

  test('фото не-оператора идёт через роутер', async () => {
    const h = makeHarness({ withRouter: true })
    const ctx = makeDmCtx(PERSON_A_ID, '', {
      text: undefined,
      caption: 'смотри',
      photo: [{ file_id: 'f1', file_unique_id: 'u1', width: 10, height: 10 }],
    })
    await handleInboundPhoto(ctx, h.deps)
    expect(h.routed.length).toBe(1)
    expect(h.routed[0]?.chat_id).toBe(String(PERSON_A_ID))
    expect(h.routed[0]?.text).toBe('смотри')
    expect(h.notified.length).toBe(0)
    h.cleanup()
  })

  test('альбом не-оператора идёт через роутер, оператора -- в главную', async () => {
    const h = makeHarness({ withRouter: true })
    const entry: AlbumEntry = {
      descriptors: ['<media kind="photo"/>'],
      mediaPaths: ['/tmp/p1.jpg'],
      caption: 'альбом',
      messageId: MESSAGE_ID,
      reply: undefined,
      addressedAtPush: true,
    }
    const album = { messages: [entry] } as unknown as Album<AlbumEntry>
    const ids = (id: number) => ({
      chatId: String(id),
      senderId: String(id),
      user: 'u',
      mediaGroupId: 'mg',
      kind: 'photo',
    })
    const deps = h.deps
    const a = await sendAlbumNotification(album, ids(PERSON_A_ID), deps)
    expect(a.dispatched).toBe(true)
    expect(h.routed.length).toBe(1)
    expect(h.routed[0]?.chat_id).toBe(String(PERSON_A_ID))
    expect(h.routed[0]?.media_paths).toEqual(['/tmp/p1.jpg'])
    await sendAlbumNotification(album, ids(OPERATOR_ID), deps)
    expect(h.routed.length).toBe(1)
    expect(h.notified.length).toBe(1)
    h.cleanup()
  })

  test('вердикт разрешения от не-оператора не принимается', async () => {
    const h = makeHarness({ withRouter: true })
    await handleInboundText(makeDmCtx(PERSON_A_ID, 'yes abcde'), h.deps)
    expect(h.verdicts.length).toBe(0)
    // Текст ушёл как обычное сообщение в сессию самого человека.
    expect(h.routed.length).toBe(1)
    await handleInboundText(makeDmCtx(OPERATOR_ID, 'yes abcde'), h.deps)
    expect(h.verdicts.length).toBe(1)
    h.cleanup()
  })

  test('человек вне политики роутера отбрасывается, в главную не попадает', async () => {
    const h = makeHarness({ withRouter: true, policy: makePolicy([PERSON_A_ID]) })
    await handleInboundText(makeDmCtx(PERSON_B_ID, 'привет'), h.deps)
    expect(h.routed.length).toBe(0)
    expect(h.notified.length).toBe(0)
    h.cleanup()
  })
})

describe('флаг совместимости dm_routing', () => {
  test('main возвращает старое поведение: все в главную сессию', async () => {
    const h = makeHarness({ withRouter: true, config: { dm_routing: 'main' } })
    await handleInboundText(makeDmCtx(PERSON_A_ID, 'привет'), h.deps)
    expect(h.routed.length).toBe(0)
    expect(h.notified.length).toBe(1)
    h.cleanup()
  })

  test('без роутера -- старое поведение даже при per_person', async () => {
    const h = makeHarness({ withRouter: false, config: { dm_routing: 'per_person' } })
    await handleInboundText(makeDmCtx(PERSON_A_ID, 'привет'), h.deps)
    expect(h.routed.length).toBe(0)
    expect(h.notified.length).toBe(1)
    h.cleanup()
  })

  test('оператор неизвестен -- остаёмся на старом поведении', async () => {
    const h = makeHarness({
      withRouter: true,
      config: {
        operator_user_ids: undefined,
        permission_relay: { enabled: false, allowed_user_ids: [], bash_only_proof: true },
      } as Partial<AppConfig>,
    })
    await handleInboundText(makeDmCtx(OPERATOR_ID, 'привет'), h.deps)
    expect(h.routed.length).toBe(0)
    expect(h.notified.length).toBe(1)
    h.cleanup()
  })
})

describe('dm-routing: чистые функции', () => {
  test('оператор по умолчанию = получатели разрешений', () => {
    const cfg = makeConfig({ operator_user_ids: undefined })
    expect(isOperatorUser(OPERATOR_ID, cfg)).toBe(true)
    expect(isOperatorUser(PERSON_A_ID, cfg)).toBe(false)
  })

  test('режим: по умолчанию per_person только с роутером', () => {
    const cfg = makeConfig()
    expect(resolveDmRoutingMode(cfg, true)).toBe('per_person')
    expect(resolveDmRoutingMode(cfg, false)).toBe('main')
    const forced: DmRouting = 'main'
    expect(resolveDmRoutingMode(makeConfig({ dm_routing: forced }), true)).toBe('main')
  })

  test('checkDmRouterAccess различает причины отказа', () => {
    const policy = makePolicy([PERSON_A_ID])
    expect(checkDmRouterAccess(policy, String(PERSON_A_ID), String(PERSON_A_ID))).toBeNull()
    expect(checkDmRouterAccess(policy, '1', '1')).toBe('user_not_in_policy')
    const noChat = { ...policy, chats: {} } as MultichatPolicy
    expect(checkDmRouterAccess(noChat, String(PERSON_A_ID), String(PERSON_A_ID)))
      .toBe('chat_not_in_policy')
  })

  test('предупреждение при старте: без роутера и с несколькими людьми, без id', () => {
    const lines: string[] = []
    const log: Logger = { ...silentLog, warn: (m, f) => lines.push(JSON.stringify([m, f])) }
    expect(warnIfSharedDmContext(makeConfig(), false, log)).toBe(true)
    expect(lines.length).toBe(1)
    expect(lines[0]).not.toContain(String(PERSON_A_ID))
    expect(warnIfSharedDmContext(makeConfig(), true, log)).toBe(false)
    expect(
      warnIfSharedDmContext(makeConfig({ allowed_user_ids: [OPERATOR_ID] }), false, log),
    ).toBe(false)
  })
})
