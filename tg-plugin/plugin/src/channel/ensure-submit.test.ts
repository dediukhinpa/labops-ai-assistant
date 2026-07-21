import { describe, expect, test } from 'bun:test'
import {
  ensureSubmitted,
  paneInput,
  paneInputStuck,
  type TmuxRunner,
} from './ensure-submit.js'

const noopLog = {
  info: () => {},
  warn: () => {},
  error: () => {},
  debug: () => {},
} as unknown as Parameters<typeof ensureSubmitted>[0]['log']

const IDLE = '────────\n❯ \n  ⏵⏵ bypass permissions on'
const STUCK = '────────\n❯ что дальше по плану, босс\n  ⏵⏵ bypass permissions on'
const ACTIVE = '● Reading…\n  ✻ Thinking (esc to interrupt)'
const HINT = '────────\n❯ Try"fix lint errors"\n  ⏵⏵ bypass permissions on'

// A recording fake runner whose capture output can be scripted per call.
function fakeRunner(paneSequence: string[]): {
  runner: TmuxRunner
  calls: string[]
} {
  const calls: string[] = []
  let i = 0
  const runner: TmuxRunner = {
    capturePane: async () => {
      const out = paneSequence[Math.min(i, paneSequence.length - 1)] ?? ''
      i += 1
      return out
    },
    clearInput: async () => {
      calls.push('clear')
    },
    submitText: async (_session, text) => {
      calls.push(`submit:${text}`)
    },
  }
  return { runner, calls }
}

const noSleep = async () => {}

describe('paneInput / paneInputStuck', () => {
  test('clean idle prompt yields empty input', () => {
    expect(paneInput(IDLE)).toBe('')
    expect(paneInputStuck(IDLE)).toBe(false)
  })
  test('stuck message is detected', () => {
    expect(paneInputStuck(STUCK)).toBe(true)
  })
  test('active turn is never treated as stuck (would clobber work)', () => {
    expect(paneInputStuck(ACTIVE)).toBe(false)
  })
  test('rotating placeholder hint is not stuck', () => {
    expect(paneInputStuck(HINT)).toBe(false)
  })
})

describe('ensureSubmitted', () => {
  test('no-op when the message already submitted (empty input)', async () => {
    const { runner, calls } = fakeRunner([IDLE])
    const r = await ensureSubmitted({
      session: 'labops-carmella',
      content: 'hi',
      log: noopLog,
      runner,
      sleep: noSleep,
      delayMs: 0,
    })
    expect(r).toBe('noop')
    expect(calls).toEqual([])
  })

  test('recovers a stuck inbound by clearing and re-typing the ORIGINAL content', async () => {
    const { runner, calls } = fakeRunner([STUCK])
    const r = await ensureSubmitted({
      session: 'labops-carmella',
      content: 'что дальше по плану, босс',
      log: noopLog,
      runner,
      sleep: noSleep,
      delayMs: 0,
    })
    expect(r).toBe('recovered')
    // Full fidelity: retypes the exact content we delivered, not a pane guess.
    expect(calls).toEqual(['clear', 'submit:что дальше по плану, босс'])
  })

  test('skips when session or content is empty', async () => {
    const { runner, calls } = fakeRunner([STUCK])
    expect(
      await ensureSubmitted({ session: '', content: 'x', log: noopLog, runner, sleep: noSleep }),
    ).toBe('skip')
    expect(
      await ensureSubmitted({ session: 's', content: '', log: noopLog, runner, sleep: noSleep }),
    ).toBe('skip')
    expect(calls).toEqual([])
  })

  test('does not clobber an active turn', async () => {
    const { runner, calls } = fakeRunner([ACTIVE])
    const r = await ensureSubmitted({
      session: 'labops-carmella',
      content: 'hi',
      log: noopLog,
      runner,
      sleep: noSleep,
      delayMs: 0,
    })
    expect(r).toBe('noop')
    expect(calls).toEqual([])
  })

  test('capture failure fails open (skip, no throw)', async () => {
    const runner: TmuxRunner = {
      capturePane: async () => {
        throw new Error('tmux gone')
      },
      clearInput: async () => {},
      submitText: async () => {},
    }
    const r = await ensureSubmitted({
      session: 'labops-carmella',
      content: 'hi',
      log: noopLog,
      runner,
      sleep: noSleep,
      delayMs: 0,
    })
    expect(r).toBe('skip')
  })
})
