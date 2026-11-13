// Fallback-reply: разбор транскрипта и сервис (флаг, был ли reply, дедуп,
// не-Telegram ход, пути, разбиение, пометка).

import { afterEach, beforeEach, describe, expect, test } from 'bun:test'
import { mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'

import {
  DEFAULT_FALLBACK_PREFIX,
  FALLBACK_MAX_CHARS,
  FallbackReplyService,
  analyzeTurn,
  defaultTranscriptRoots,
  parseLeadingTelegramEnvelope,
  type FallbackReplyServiceOpts,
} from '../../src/channel/fallback-reply.js'
import { createLogger } from '../../src/log.js'
import type { SendMessageOpts } from '../../src/channel/tools.js'

const CHAT = '124546645'
const GROUP = '-1003784643974'

// ── Конструкторы строк транскрипта (формат JSONL-транскрипта) ──────────────
function envelope(chat: string, msgId: number | null, body = 'привет'): string {
  const mid = msgId === null ? '' : ` message_id="${msgId}"`
  return `<channel source="labops-channel" source="telegram" chat_id="${chat}" user_id="1" ts="2026-11-09T09:01:31.241Z"${mid}>\n${body}\n</channel>`
}
const line = (o: unknown): string => JSON.stringify(o)
const userPrompt = (content: string): string => line({ type: 'user', message: { role: 'user', content } })
const toolResult = (): string =>
  line({ type: 'user', message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 't1', content: 'ok' }] } })
const assistantText = (text: string): string =>
  line({ type: 'assistant', message: { role: 'assistant', content: [{ type: 'text', text }] } })
const assistantThinking = (): string =>
  line({ type: 'assistant', message: { role: 'assistant', content: [{ type: 'thinking', thinking: 'hm' }] } })
const assistantTool = (name: string): string =>
  line({ type: 'assistant', message: { role: 'assistant', content: [{ type: 'tool_use', id: 't1', name, input: {} }] } })
const join_ = (...ls: string[]): string => ls.join('\n') + '\n'

describe('parseLeadingTelegramEnvelope', () => {
  test('берёт chat_id и message_id из ведущего тега', () => {
    expect(parseLeadingTelegramEnvelope(envelope(CHAT, 1332))).toEqual({ chatId: CHAT, messageId: 1332 })
  })
  test('отрицательный chat_id группы', () => {
    expect(parseLeadingTelegramEnvelope(envelope(GROUP, 7))?.chatId).toBe(GROUP)
  })
  test('не Telegram-источник → undefined', () => {
    expect(parseLeadingTelegramEnvelope('<channel source="labops-channel" source="webhook" chat_id="1">x')).toBeUndefined()
  })
  test('тег не в начале текста игнорируется', () => {
    expect(parseLeadingTelegramEnvelope(`текст\n${envelope(CHAT, 5)}`)).toBeUndefined()
  })
  test('без message_id — только chatId', () => {
    expect(parseLeadingTelegramEnvelope(envelope(CHAT, null))).toEqual({ chatId: CHAT })
  })
})

describe('analyzeTurn', () => {
  test('ход без reply: текст, chat и message_id', () => {
    const t = analyzeTurn(join_(userPrompt(envelope(CHAT, 10)), assistantThinking(), assistantText('итог')))
    expect(t).toEqual({ replied: false, text: 'итог', chatId: CHAT, messageId: 10 })
  })
  test('вызов reply → replied', () => {
    const t = analyzeTurn(
      join_(userPrompt(envelope(CHAT, 10)), assistantTool('mcp__labops-channel__reply'), toolResult(), assistantText('готово')),
    )
    expect(t.replied).toBe(true)
  })
  test('вызов edit_message → replied', () => {
    const t = analyzeTurn(
      join_(userPrompt(envelope(CHAT, 10)), assistantTool('mcp__labops-channel__edit_message'), toolResult(), assistantText('x')),
    )
    expect(t.replied).toBe(true)
  })
  test('чужой reply другого сервера не считается ответом', () => {
    const t = analyzeTurn(join_(userPrompt(envelope(CHAT, 10)), assistantTool('mcp__other__reply'), toolResult(), assistantText('x')))
    expect(t.replied).toBe(false)
  })
  test('reply из ПРЕДЫДУЩЕГО хода не влияет', () => {
    const t = analyzeTurn(
      join_(
        userPrompt(envelope(CHAT, 9)),
        assistantTool('mcp__labops-channel__reply'),
        toolResult(),
        assistantText('старый'),
        userPrompt(envelope(CHAT, 10)),
        assistantText('новый без reply'),
      ),
    )
    expect(t).toEqual({ replied: false, text: 'новый без reply', chatId: CHAT, messageId: 10 })
  })
  test('текст до последнего tool_result не берётся (реплики между вызовами)', () => {
    const t = analyzeTurn(
      join_(userPrompt(envelope(CHAT, 10)), assistantText('сейчас проверю'), assistantTool('Bash'), toolResult(), assistantThinking()),
    )
    expect(t.text).toBeUndefined()
    expect(t.chatId).toBe(CHAT)
  })
  test('ход не из Telegram: chatId undefined', () => {
    const t = analyzeTurn(join_(userPrompt('<task-notification>что-то</task-notification>'), assistantText('ответ')))
    expect(t.chatId).toBeUndefined()
  })
  test('набранный человеком текст — не Telegram', () => {
    expect(analyzeTurn(join_(userPrompt('Как дела?'), assistantText('ок'))).chatId).toBeUndefined()
  })
  test('нет границы хода в окне → chatId undefined', () => {
    expect(analyzeTurn(join_(assistantText('хвост'))).chatId).toBeUndefined()
  })
  test('битые строки пропускаются', () => {
    const t = analyzeTurn(`{oops\n${userPrompt(envelope(CHAT, 3))}\nnot json\n${assistantText('ок')}\n`)
    expect(t.text).toBe('ок')
  })
})

// ── Сервис ───────────────────────────────────────────────────────────
interface Sent { chatId: string; text: string; opts: SendMessageOpts }

let dir: string
let projects: string
let sent: Sent[]
let nextId: number

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'labops-fallback-'))
  projects = join(dir, 'projects', 'slug')
  mkdirSync(projects, { recursive: true })
  sent = []
  nextId = 100
})
afterEach(() => rmSync(dir, { recursive: true, force: true }))

function makeService(over: Partial<FallbackReplyServiceOpts> = {}): FallbackReplyService {
  return new FallbackReplyService({
    enabled: true,
    transcriptRoots: [join(dir, 'projects')],
    statePath: join(dir, 'state', 'state.json'),
    prefix: DEFAULT_FALLBACK_PREFIX,
    log: createLogger('test-fallback'),
    sendMessage: async (chatId, text, opts) => {
      sent.push({ chatId, text, opts })
      return { message_id: nextId++ }
    },
    isChatAllowed: (c) => c === CHAT || c === GROUP,
    ...over,
  })
}

function writeTranscript(name: string, ...ls: string[]): string {
  const p = join(projects, name)
  writeFileSync(p, join_(...ls))
  return p
}

describe('FallbackReplyService', () => {
  test('флаг выключен: ничего не читает и не шлёт', async () => {
    const p = writeTranscript('s.jsonl', userPrompt(envelope(CHAT, 1)), assistantText('итог'))
    const svc = makeService({ enabled: false })
    expect(await svc.handle({ transcript_path: p, session_id: 's' })).toEqual({ status: 'disabled' })
    expect(sent).toHaveLength(0)
  })

  test('был reply: молчим', async () => {
    const p = writeTranscript(
      's.jsonl',
      userPrompt(envelope(CHAT, 1)),
      assistantTool('mcp__labops-channel__reply'),
      toolResult(),
      assistantText('готово'),
    )
    expect((await makeService().handle({ transcript_path: p })).status).toBe('replied')
    expect(sent).toHaveLength(0)
  })

  test('ответа не было: отправка reply на входящее с пометкой', async () => {
    const p = writeTranscript('s.jsonl', userPrompt(envelope(CHAT, 55)), assistantText('Итог **готов**'))
    const r = await makeService().handle({ transcript_path: p, session_id: 's' })
    expect(r.status).toBe('sent')
    expect(sent).toHaveLength(1)
    const m = sent[0] as Sent
    expect(m.chatId).toBe(CHAT)
    expect(m.opts).toEqual({ parse_mode: 'HTML', reply_to_message_id: 55 })
    expect(m.text.startsWith(DEFAULT_FALLBACK_PREFIX)).toBe(true)
    expect(m.text).toContain('<b>готов</b>')
  })

  test('группа: отрицательный chat_id', async () => {
    const p = writeTranscript('g.jsonl', userPrompt(envelope(GROUP, 8)), assistantText('ок'))
    expect((await makeService().handle({ transcript_path: p })).status).toBe('sent')
    expect((sent[0] as Sent).chatId).toBe(GROUP)
  })

  test('дубль Stop того же хода: одна отправка', async () => {
    const p = writeTranscript('s.jsonl', userPrompt(envelope(CHAT, 55)), assistantText('итог'))
    const svc = makeService()
    expect((await svc.handle({ transcript_path: p, session_id: 's' })).status).toBe('sent')
    expect((await svc.handle({ transcript_path: p, session_id: 's' })).status).toBe('duplicate')
    expect(sent).toHaveLength(1)
  })

  test('дедуп переживает рестарт сервиса (файл состояния)', async () => {
    const p = writeTranscript('s.jsonl', userPrompt(envelope(CHAT, 55)), assistantText('итог'))
    await makeService().handle({ transcript_path: p, session_id: 's' })
    expect((await makeService().handle({ transcript_path: p, session_id: 's' })).status).toBe('duplicate')
    expect(sent).toHaveLength(1)
  })

  test('параллельные Stop одного хода: одна отправка', async () => {
    const p = writeTranscript('s.jsonl', userPrompt(envelope(CHAT, 55)), assistantText('итог'))
    const svc = makeService({
      sendMessage: async (chatId, text, opts) => {
        await new Promise((r) => setTimeout(r, 20))
        sent.push({ chatId, text, opts })
        return { message_id: 1 }
      },
    })
    const rs = await Promise.all([
      svc.handle({ transcript_path: p, session_id: 's' }),
      svc.handle({ transcript_path: p, session_id: 's' }),
    ])
    expect(rs.map((r) => r.status).sort()).toEqual(['duplicate', 'sent'])
    expect(sent).toHaveLength(1)
  })

  test('новый ход той же сессии отправляется отдельно', async () => {
    const svc = makeService()
    const p1 = writeTranscript('s.jsonl', userPrompt(envelope(CHAT, 1)), assistantText('a'))
    await svc.handle({ transcript_path: p1, session_id: 's' })
    const p2 = writeTranscript('s.jsonl', userPrompt(envelope(CHAT, 1)), assistantText('a'), userPrompt(envelope(CHAT, 2)), assistantText('b'))
    expect((await svc.handle({ transcript_path: p2, session_id: 's' })).status).toBe('sent')
    expect(sent).toHaveLength(2)
  })

  test('ход не из Telegram: молчим', async () => {
    const p = writeTranscript('s.jsonl', userPrompt('<task-notification>x</task-notification>'), assistantText('ответ'))
    expect((await makeService().handle({ transcript_path: p })).status).toBe('not_telegram')
    expect(sent).toHaveLength(0)
  })

  test('нет финального текста: молчим и не помечаем как отправленное', async () => {
    const svc = makeService()
    const p = writeTranscript('s.jsonl', userPrompt(envelope(CHAT, 1)), assistantTool('Bash'), toolResult())
    expect((await svc.handle({ transcript_path: p, session_id: 's' })).status).toBe('no_text')
    // Текст появился позже: тот же ход теперь отправляется.
    writeTranscript('s.jsonl', userPrompt(envelope(CHAT, 1)), assistantTool('Bash'), toolResult(), assistantText('поздно'))
    expect((await svc.handle({ transcript_path: p, session_id: 's' })).status).toBe('sent')
  })

  test('чат вне allowlist: не отправляем', async () => {
    const p = writeTranscript('s.jsonl', userPrompt(envelope('999', 1)), assistantText('x'))
    expect((await makeService().handle({ transcript_path: p })).status).toBe('chat_not_allowed')
    expect(sent).toHaveLength(0)
  })

  test('сбой отправки: send_failed, повтор того же хода разрешён', async () => {
    const p = writeTranscript('s.jsonl', userPrompt(envelope(CHAT, 1)), assistantText('x'))
    let fail = true
    const svc = makeService({
      sendMessage: async (chatId, text, opts) => {
        if (fail) throw new Error('boom')
        sent.push({ chatId, text, opts })
        return { message_id: 1 }
      },
    })
    expect((await svc.handle({ transcript_path: p, session_id: 's' })).status).toBe('send_failed')
    fail = false
    expect((await svc.handle({ transcript_path: p, session_id: 's' })).status).toBe('sent')
    expect(sent).toHaveLength(1)
  })

  test('длинный текст разбивается, reply_to только на первом куске', async () => {
    const long = Array.from({ length: 12 }, (_, i) => `Абзац ${i} ${'я'.repeat(900)}`).join('\n\n')
    const p = writeTranscript('s.jsonl', userPrompt(envelope(CHAT, 7)), assistantText(long))
    await makeService().handle({ transcript_path: p })
    expect(sent.length).toBeGreaterThan(2)
    for (const m of sent) expect(m.text.length).toBeLessThanOrEqual(4096)
    expect((sent[0] as Sent).opts.reply_to_message_id).toBe(7)
    for (const m of sent.slice(1)) expect(m.opts.reply_to_message_id).toBeUndefined()
  })

  test('огромный текст обрезается с маркером', async () => {
    const huge = 'ж'.repeat(FALLBACK_MAX_CHARS * 2)
    const p = writeTranscript('s.jsonl', userPrompt(envelope(CHAT, 7)), assistantText(huge))
    await makeService().handle({ transcript_path: p })
    const total = sent.reduce((n, m) => n + m.text.length, 0)
    expect(total).toBeLessThan(FALLBACK_MAX_CHARS + 500)
    expect(sent.at(-1)?.text).toContain('[обрезано]')
  })

  test('пустая пометка: текст без префикса', async () => {
    const p = writeTranscript('s.jsonl', userPrompt(envelope(CHAT, 7)), assistantText('просто текст'))
    await makeService({ prefix: '' }).handle({ transcript_path: p })
    expect((sent[0] as Sent).text).toBe('просто текст')
  })

  test('HTML отвергнут Telegram: повтор простым текстом', async () => {
    const p = writeTranscript('s.jsonl', userPrompt(envelope(CHAT, 7)), assistantText('x'))
    const calls: SendMessageOpts[] = []
    const svc = makeService({
      sendMessage: async (_c, _t, opts) => {
        calls.push(opts)
        if (opts.parse_mode === 'HTML') throw new Error("Bad Request: can't parse entities")
        return { message_id: 1 }
      },
    })
    expect((await svc.handle({ transcript_path: p })).status).toBe('sent')
    expect(calls[1]).toEqual({ reply_to_message_id: 7 })
  })

  test('afterSend вызывается после отправки', async () => {
    const p = writeTranscript('s.jsonl', userPrompt(envelope(CHAT, 7)), assistantText('x'))
    const done: string[] = []
    await makeService({ afterSend: async (c) => { done.push(c) } }).handle({ transcript_path: p })
    expect(done).toEqual([CHAT])
  })

  test('путь вне разрешённых корней отвергается', async () => {
    const outside = join(dir, 'other.jsonl')
    writeFileSync(outside, join_(userPrompt(envelope(CHAT, 1)), assistantText('x')))
    expect((await makeService().handle({ transcript_path: outside })).status).toBe('bad_path')
    expect(sent).toHaveLength(0)
  })

  test('симлинк из корня наружу отвергается; не .jsonl отвергается; ../ отвергается', async () => {
    const outside = join(dir, 'secret.jsonl')
    writeFileSync(outside, join_(userPrompt(envelope(CHAT, 1)), assistantText('x')))
    const link = join(projects, 'link.jsonl')
    symlinkSync(outside, link)
    const svc = makeService()
    expect((await svc.handle({ transcript_path: link })).status).toBe('bad_path')
    const txt = join(projects, 'a.txt')
    writeFileSync(txt, 'x')
    expect((await svc.handle({ transcript_path: txt })).status).toBe('bad_path')
    expect((await svc.handle({ transcript_path: `${projects}/../../other.jsonl` })).status).toBe('bad_path')
    expect(sent).toHaveLength(0)
  })

  test('несуществующий файл: bad_path', async () => {
    expect((await makeService().handle({ transcript_path: join(projects, 'nope.jsonl') })).status).toBe('bad_path')
  })
})

describe('defaultTranscriptRoots', () => {
  test('домашний каталог и CLAUDE_CONFIG_DIR', () => {
    expect(defaultTranscriptRoots({}, '/h')).toEqual(['/h/.claude/projects'])
    expect(defaultTranscriptRoots({ CLAUDE_CONFIG_DIR: '/c' }, '/h')).toEqual(['/h/.claude/projects', '/c/projects'])
  })
})
