import { describe, expect, test } from 'bun:test'

import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

import {
  BOT_COMMANDS,
  executeOobResult,
  handleOobCommand,
  parseOobCommand,
  resolveDoctorRequestPath,
  type OobContext,
} from '../../src/commands/oob.js'
import type { AppConfig } from '../../src/config.js'
import type { Logger } from '../../src/log.js'
import type { TelegramApi } from '../../src/channel/tools.js'

function makeConfig(overrides: Partial<AppConfig> = {}): AppConfig {
  return {
    bot_id: 100000002,
    dm_only: true,
    allowed_user_ids: [100000001],
    allowed_chat_ids: [100000001],
    status: { enabled: true, interval_ms: 700, ttl_ms: 300_000, delete_on_complete: true, suppress_typing_bubble: false },
    album: { flush_ms: 2000 },
    voice: { provider: 'groq', language: 'ru', model: 'whisper-large-v3-turbo' },
    webhook: { enabled: false, host: '127.0.0.1', port: 0 },
    permission_relay: {
      enabled: true,
      allowed_user_ids: [100000001],
      bash_only_proof: true,
    },
    commands: { help: true, status: true, stop: true, reset: true, new: true },
    memory: {
      enabled: false,
      source_tag: 'tg',
      max_active_bytes: 20480,
      trim_keep_lines: 600,
      buffer_ttl_ms: 5 * 60 * 1000,
      buffer_max_entries: 100,
    },
    progress: {
      enabled: true,
      edit_throttle_ms: 3000,
      recent_buffer: 10,
      session_ttl_ms: 600000,
    },
    task_mirror: {
      enabled: true,
      edit_throttle_ms: 3000,
      session_ttl_ms: 600000,
      collapse_completed_after: 5,
    },
    watcher: {
      enabled: true,
      debounce_ms: 10_000,
      busy_threshold_ms: 30_000,
    },
    tmux_mirror: { enabled: false, pane_target: '', poll_interval_ms: 5000, line_count: 50, hide_segments: ['boot_banner', 'inbound_warning', 'footer_hints', 'input_box'], mode: 'latest_inbound_only', max_lines: 14 },
    multichat: { enabled: false },
    ask_user_question: { enabled: false, timeout_ms: 300_000, max_preview_chars: 1000 },
    ...overrides,
  }
}

function makeLogger(): Logger {
  return {
    debug: () => {},
    info: () => {},
    warn: () => {},
    error: () => {},
  }
}

function makeTelegramApi(): TelegramApi {
  // /help and /status tests don't actually invoke handleOobCommand's side
  // effects on the API — the result object carries replyToTelegram and the
  // caller (executeOobResult / handlers.ts) issues sendMessage. We stub
  // every method to throw if accidentally invoked.
  const fail = (name: string) => {
    return (): never => {
      throw new Error(`unexpected TelegramApi call: ${name}`)
    }
  }
  return {
    sendMessage: fail('sendMessage') as TelegramApi['sendMessage'],
    editMessageText: fail('editMessageText') as TelegramApi['editMessageText'],
    setMessageReaction: fail(
      'setMessageReaction',
    ) as TelegramApi['setMessageReaction'],
    sendChatAction: fail('sendChatAction') as TelegramApi['sendChatAction'],
    sendDocument: fail('sendDocument') as TelegramApi['sendDocument'],
    sendPhoto: fail('sendPhoto') as TelegramApi['sendPhoto'],
    downloadFile: fail('downloadFile') as TelegramApi['downloadFile'],
    deleteMessage: fail('deleteMessage') as TelegramApi['deleteMessage'],
  }
}

function makeCtx(overrides: Partial<OobContext> = {}): OobContext {
  return {
    chatId: '100000001',
    senderId: '100000001',
    config: makeConfig(),
    telegramApi: makeTelegramApi(),
    log: makeLogger(),
    botId: 100000002,
    stateDir: '/tmp/state',
    ...overrides,
  }
}

// ─────────────────────────────────────────────────────────────────────
// parseOobCommand
// ─────────────────────────────────────────────────────────────────────

describe('parseOobCommand', () => {
  test('returns null on plain text', () => {
    expect(parseOobCommand('hello world')).toBeNull()
    expect(parseOobCommand('not a command')).toBeNull()
  })

  test('parses /help', () => {
    const r = parseOobCommand('/help')
    expect(r).not.toBeNull()
    expect(r!.name).toBe('help')
    expect(r!.args).toBe('')
    expect(r!.hasForceFlag).toBe(false)
  })

  test('parses /status@botname strips suffix', () => {
    const r = parseOobCommand('/status@labopscanarybot', 'labopscanarybot')
    expect(r).not.toBeNull()
    expect(r!.name).toBe('status')
  })

  test('parses /reset force with hasForceFlag=true', () => {
    const r = parseOobCommand('/reset force')
    expect(r).not.toBeNull()
    expect(r!.name).toBe('reset')
    expect(r!.args).toBe('force')
    expect(r!.hasForceFlag).toBe(true)
  })

  test('parses /new without force has hasForceFlag=false', () => {
    const r = parseOobCommand('/new')
    expect(r).not.toBeNull()
    expect(r!.name).toBe('new')
    expect(r!.hasForceFlag).toBe(false)
  })

  test('parses unknown /foo as null', () => {
    expect(parseOobCommand('/foo')).toBeNull()
    expect(parseOobCommand('/compact')).toBeNull()
    expect(parseOobCommand('/halt')).toBeNull()
  })

  test('parses /stop case-insensitively (/STOP)', () => {
    const r = parseOobCommand('/STOP')
    expect(r).not.toBeNull()
    expect(r!.name).toBe('stop')
  })
})

// ─────────────────────────────────────────────────────────────────────
// handleOobCommand
// ─────────────────────────────────────────────────────────────────────

describe('handleOobCommand', () => {
  test('/help returns HTML reply listing commands, no channel notify', async () => {
    const parsed = parseOobCommand('/help')!
    const result = await handleOobCommand(parsed, makeCtx())
    expect(result.handled).toBe(true)
    expect(result.command).toBe('help')
    expect(result.notifyChannel).toBeUndefined()
    expect(result.replyToTelegram).toBeDefined()
    const text = result.replyToTelegram!.text
    expect(result.replyToTelegram!.parseMode).toBe('HTML')
    // Lists all 5 Scope A commands.
    expect(text).toContain('/help')
    expect(text).toContain('/status')
    expect(text).toContain('/stop')
    expect(text).toContain('/reset')
    expect(text).toContain('/new')
    // Scope B commands explicitly absent.
    expect(text).not.toContain('/compact')
    expect(text).not.toContain('/halt')
  })

  test('/status includes bot_id state_dir allowed_user', async () => {
    const parsed = parseOobCommand('/status')!
    const result = await handleOobCommand(
      parsed,
      makeCtx({
        botId: 100000002,
        stateDir: '/var/lib/canary',
        senderId: '100000001',
      }),
    )
    expect(result.notifyChannel).toBeUndefined()
    expect(result.replyToTelegram).toBeDefined()
    const text = result.replyToTelegram!.text
    expect(text).toContain('100000002')
    expect(text).toContain('/var/lib/canary')
    expect(text).toContain('100000001')
  })

  test('/status includes status_manager and webhook info when supplied', async () => {
    const parsed = parseOobCommand('/status')!
    const result = await handleOobCommand(
      parsed,
      makeCtx({
        statusManager: {
          isActive: (cid: string) => cid === '100000001',
          cancel: async () => {},
        },
        webhookStatus: () => ({ enabled: true, port: 8089 }),
        pollerStatus: () => ({ offset: 42 }),
      }),
    )
    const text = result.replyToTelegram!.text
    expect(text).toContain('active')
    expect(text).toContain('on:8089')
    expect(text).toContain('42')
  })

  test('/stop emits channel notification with meta.command=stop', async () => {
    const parsed = parseOobCommand('/stop')!
    const result = await handleOobCommand(parsed, makeCtx())
    expect(result.command).toBe('stop')
    expect(result.notifyChannel).toBeDefined()
    expect(result.notifyChannel!.meta.command).toBe('stop')
    expect(result.notifyChannel!.meta.chat_id).toBe('100000001')
    expect(result.notifyChannel!.meta.source).toBe('telegram')
    expect(result.replyToTelegram).toBeDefined()
  })

  test('/reset force emits channel notification meta.command=reset', async () => {
    const parsed = parseOobCommand('/reset force')!
    const result = await handleOobCommand(parsed, makeCtx())
    expect(result.command).toBe('reset')
    expect(result.notifyChannel).toBeDefined()
    expect(result.notifyChannel!.meta.command).toBe('reset')
    expect(result.replyToTelegram!.text).toContain('сброшена')
  })

  test('/reset (no force) returns reply asking for force flag, no channel notify', async () => {
    const parsed = parseOobCommand('/reset')!
    const result = await handleOobCommand(parsed, makeCtx())
    expect(result.command).toBe('reset')
    expect(result.notifyChannel).toBeUndefined()
    expect(result.replyToTelegram).toBeDefined()
    expect(result.replyToTelegram!.text).toContain('force')
  })

  test('/new force emits channel notification meta.command=new', async () => {
    const parsed = parseOobCommand('/new force')!
    const result = await handleOobCommand(parsed, makeCtx())
    expect(result.command).toBe('new')
    expect(result.notifyChannel).toBeDefined()
    expect(result.notifyChannel!.meta.command).toBe('new')
  })

  test('/new (no force) returns reply asking for force flag, no channel notify', async () => {
    const parsed = parseOobCommand('/new')!
    const result = await handleOobCommand(parsed, makeCtx())
    expect(result.notifyChannel).toBeUndefined()
    expect(result.replyToTelegram!.text).toContain('force')
  })
})

// ─────────────────────────────────────────────────────────────────────
// /doctor — единственная команда, которую плагин НЕ исполняет сам.
// Плагин живёт внутри сессии агента; починка может её перезапустить, и
// тогда отвечать оператору будет уже некому. Поэтому плагин лишь кладёт
// заявку, а выполняет и отчитывается watchdog.
// ─────────────────────────────────────────────────────────────────────

describe('/doctor', () => {
  test('parses /doctor and /doctor@botname', () => {
    expect(parseOobCommand('/doctor')!.name).toBe('doctor')
    expect(parseOobCommand('/doctor@christopher_coderbot')!.name).toBe('doctor')
  })

  test('files a request for the watchdog and acks immediately', async () => {
    const parsed = parseOobCommand('/doctor')!
    const result = await handleOobCommand(
      parsed,
      makeCtx({ doctorRequestPath: '/tmp/doctor.request' }),
    )
    expect(result.command).toBe('doctor')
    expect(result.writeDoctorRequest).toBeDefined()
    expect(result.writeDoctorRequest!.path).toBe('/tmp/doctor.request')
    // chat_id уходит в заявку, чтобы watchdog ответил в тот же чат.
    expect(result.writeDoctorRequest!.chatId).toBe('100000001')
    expect(result.replyToTelegram).toBeDefined()
  })

  test('does NOT wake Claude — the command is about the agent, not for it', async () => {
    const parsed = parseOobCommand('/doctor')!
    const result = await handleOobCommand(
      parsed,
      makeCtx({ doctorRequestPath: '/tmp/doctor.request' }),
    )
    expect(result.notifyChannel).toBeUndefined()
  })

  test('says so plainly when there is no supervisor to ask', async () => {
    const parsed = parseOobCommand('/doctor')!
    const result = await handleOobCommand(parsed, makeCtx())
    expect(result.writeDoctorRequest).toBeUndefined()
    expect(result.replyToTelegram!.text).toContain('без надзора')
  })

  test('is listed in /help and in the bot command menu', async () => {
    const parsed = parseOobCommand('/help')!
    const result = await handleOobCommand(parsed, makeCtx())
    expect(result.replyToTelegram!.text).toContain('/doctor')
    expect(BOT_COMMANDS.some((c) => c.command === 'doctor')).toBe(true)
  })
})

describe('executeOobResult writes the doctor request', () => {
  test('writes chat_id to the request path before replying', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'doctor-req-'))
    const reqPath = join(dir, 'nested', 'doctor.request')
    const sent: string[] = []
    const api = makeTelegramApi()
    api.sendMessage = (async (_chat: string, text: string) => {
      sent.push(text)
      return { message_id: 1 }
    }) as TelegramApi['sendMessage']

    const ctx = makeCtx({ telegramApi: api, doctorRequestPath: reqPath })
    const parsed = parseOobCommand('/doctor')!
    const result = await handleOobCommand(parsed, ctx)
    await executeOobResult(result, ctx, {} as never)

    expect(readFileSync(reqPath, 'utf8')).toBe('100000001')
    expect(sent).toHaveLength(1)
    rmSync(dir, { recursive: true, force: true })
  })

  test('an unwritable path is admitted, not papered over with a false ack', async () => {
    const sent: string[] = []
    const api = makeTelegramApi()
    api.sendMessage = (async (_chat: string, text: string) => {
      sent.push(text)
      return { message_id: 1 }
    }) as TelegramApi['sendMessage']

    // Путь внутри файла — создать каталог невозможно.
    const dir = mkdtempSync(join(tmpdir(), 'doctor-req-'))
    const blocker = join(dir, 'blocker')
    writeFileSync(blocker, 'x')
    const ctx = makeCtx({
      telegramApi: api,
      doctorRequestPath: join(blocker, 'doctor.request'),
    })
    const parsed = parseOobCommand('/doctor')!
    const result = await handleOobCommand(parsed, ctx)
    await executeOobResult(result, ctx, {} as never)

    expect(sent).toHaveLength(1)
    expect(sent[0]).toContain('Не смог позвать доктора')
    rmSync(dir, { recursive: true, force: true })
  })
})

describe('resolveDoctorRequestPath', () => {
  test('mirrors the bash contract: <lab>/shared/state/<agent>/doctor.request', () => {
    expect(
      resolveDoctorRequestPath({ AGENT_ID: 'developer', CLAUDE_LAB: '/lab' } as NodeJS.ProcessEnv),
    ).toBe('/lab/shared/state/developer/doctor.request')
  })

  test('falls back to $HOME/.claude-lab, like the bash side', () => {
    expect(
      resolveDoctorRequestPath({ AGENT_ID: 'developer', HOME: '/home/x' } as NodeJS.ProcessEnv),
    ).toBe('/home/x/.claude-lab/shared/state/developer/doctor.request')
  })

  test('empty when the agent is unknown — the command then reports it honestly', () => {
    expect(resolveDoctorRequestPath({ HOME: '/home/x' } as NodeJS.ProcessEnv)).toBe('')
  })
})
