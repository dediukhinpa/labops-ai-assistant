import { describe, expect, test } from 'bun:test'
import {
  formatInboundForTmux,
  normalizeMeta,
  sendChannelNotification,
} from '../../src/channel/notify.js'
import type { TmuxRunner } from '../../src/channel/ensure-submit.js'
import { createLogger } from '../../src/log.js'

// Silent logger so test output stays clean.
const silentLog = createLogger('test', {
  stream: { write: () => true } as unknown as NodeJS.WritableStream,
})

// Minimal MCP server stub. sendChannelNotification only touches
// `.notification()`.
function makeStubServer(behavior: 'ok' | 'throw'): {
  // Cast to the real Server type at the call-site to avoid pulling in the
  // SDK's deep types just for a structural stub.
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  server: any
  calls: Array<{ method: string; params: unknown }>
} {
  const calls: Array<{ method: string; params: unknown }> = []
  const server = {
    notification: async (msg: { method: string; params: unknown }): Promise<void> => {
      calls.push({ method: msg.method, params: msg.params })
      if (behavior === 'throw') throw new Error('transport closed')
    },
  }
  return { server, calls }
}

describe('normalizeMeta', () => {
  test('drops keys with hyphens', () => {
    const out = normalizeMeta({ 'chat-id': '123', chat_id: '456' })
    expect(out['chat-id']).toBeUndefined()
    expect(out.chat_id).toBe('456')
  })

  test('coerces numbers and booleans to string', () => {
    const out = normalizeMeta({ count: 42, ok: true, off: false })
    expect(out.count).toBe('42')
    expect(out.ok).toBe('true')
    expect(out.off).toBe('false')
  })

  test('drops null and undefined values', () => {
    const out = normalizeMeta({ keep: 'yes', a: null, b: undefined })
    expect(out.keep).toBe('yes')
    expect(Object.keys(out)).toEqual(['keep'])
  })

  test("rejects keys that don't match identifier regex", () => {
    const out = normalizeMeta({
      good_key: 'a',
      '1starts_with_digit': 'b',
      'has space': 'c',
      'has.dot': 'd',
      _underscore_ok: 'e',
    })
    expect(out.good_key).toBe('a')
    expect(out._underscore_ok).toBe('e')
    expect(out['1starts_with_digit']).toBeUndefined()
    expect(out['has space']).toBeUndefined()
    expect(out['has.dot']).toBeUndefined()
  })
})

describe('sendChannelNotification return contract', () => {
  test('returns true on successful transport write', async () => {
    const { server, calls } = makeStubServer('ok')
    const ok = await sendChannelNotification(
      server,
      { content: 'hello', meta: { source: 'telegram' } },
      silentLog,
    )
    expect(ok).toBe(true)
    expect(calls.length).toBe(1)
    expect(calls[0]!.method).toBe('notifications/claude/channel')
  })

  test('returns false (no rethrow) when server.notification throws', async () => {
    const { server } = makeStubServer('throw')
    const ok = await sendChannelNotification(
      server,
      { content: 'hello', meta: { source: 'telegram' } },
      silentLog,
    )
    expect(ok).toBe(false)
  })
})

describe('delivery into the tmux window (LABOPS_INBOUND_VIA_TMUX=1)', () => {
  const env = { LABOPS_INBOUND_VIA_TMUX: '1', AGENT_ID: 'developer' } as NodeJS.ProcessEnv
  function makeRunner(fail = false): { runner: TmuxRunner; typed: Array<[string, string]> } {
    const typed: Array<[string, string]> = []
    const runner: TmuxRunner = {
      capturePane: async () => '',
      clearInput: async () => undefined,
      submitText: async (session, text) => {
        if (fail) throw new Error('no session')
        typed.push([session, text])
      },
    }
    return { runner, typed }
  }

  test('types the message into the agent session and skips the MCP notification', async () => {
    const { server, calls } = makeStubServer('ok')
    const { runner, typed } = makeRunner()
    const ok = await sendChannelNotification(
      server,
      { content: 'привет', meta: { chat_id: '42', message_id: '7' } },
      silentLog,
      { runner, env },
    )
    expect(ok).toBe(true)
    expect(calls).toHaveLength(0)
    expect(typed).toHaveLength(1)
    expect(typed[0]?.[0]).toBe('labops-developer')
    expect(typed[0]?.[1]).toBe(
      '<channel source="labops-channel" chat_id="42" message_id="7">\nпривет\n</channel>',
    )
  })

  test('without the flag it still uses the MCP notification', async () => {
    const { server, calls } = makeStubServer('ok')
    const { runner, typed } = makeRunner()
    await sendChannelNotification(server, { content: 'x', meta: { chat_id: '1' } }, silentLog, {
      runner,
      env: { AGENT_ID: 'developer' } as NodeJS.ProcessEnv,
    })
    expect(calls).toHaveLength(1)
    expect(typed).toHaveLength(0)
  })

  test('returns false when tmux fails and when AGENT_ID is missing', async () => {
    const { server } = makeStubServer('ok')
    const failing = makeRunner(true)
    const event = { content: 'x', meta: { chat_id: '1' } }
    expect(
      await sendChannelNotification(server, event, silentLog, { runner: failing.runner, env }),
    ).toBe(false)
    expect(
      await sendChannelNotification(server, event, silentLog, {
        runner: makeRunner().runner,
        env: { LABOPS_INBOUND_VIA_TMUX: '1' } as NodeJS.ProcessEnv,
      }),
    ).toBe(false)
  })

  test('strips escape sequences so a message cannot close the paste early', () => {
    const text = formatInboundForTmux({
      content: 'a\x1b[201~rm -rf /\x1b[200~b',
      meta: { chat_id: '1', note: 'x"y\x1b' },
    })
    expect(text).not.toContain('\x1b')
    expect(text).toContain('note="x\'y "')
  })

  test('parallel messages are typed one after another, in order', async () => {
    const { server } = makeStubServer('ok')
    const order: string[] = []
    const runner: TmuxRunner = {
      capturePane: async () => '',
      clearInput: async () => undefined,
      submitText: async (_s, text) => {
        order.push(`start:${text.includes('first') ? 1 : 2}`)
        await new Promise((r) => setTimeout(r, text.includes('first') ? 30 : 1))
        order.push(`end:${text.includes('first') ? 1 : 2}`)
      },
    }
    await Promise.all([
      sendChannelNotification(server, { content: 'first', meta: { chat_id: '1' } }, silentLog, { runner, env }),
      sendChannelNotification(server, { content: 'second', meta: { chat_id: '1' } }, silentLog, { runner, env }),
    ])
    expect(order).toEqual(['start:1', 'end:1', 'start:2', 'end:2'])
  })
})
