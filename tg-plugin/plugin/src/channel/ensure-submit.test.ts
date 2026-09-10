import { describe, expect, test } from 'bun:test'
import {
  createTmuxRunner,
  ensureSubmitted,
  paneInput,
  paneInputStuck,
  type TmuxExec,
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

// Записывает argv каждого вызова tmux; capture-pane отдаёт заданный экран.
function recordingExec(pane: string): { exec: TmuxExec; calls: string[][] } {
  const calls: string[][] = []
  const exec: TmuxExec = async (args) => {
    calls.push([...args])
    return args[0] === 'capture-pane' ? pane : ''
  }
  return { exec, calls }
}

// Точная цель панели: `=` запрещает подбор по префиксу имени (labops-app →
// labops-app-124546645), `^.{top-left}` — первое окно вместо текущего.
const PANE = '=labops-carmella:^.{top-left}'

describe('createTmuxRunner builds exact tmux targets', () => {
  test('capture-pane targets the exact first-window pane', async () => {
    const { exec, calls } = recordingExec(IDLE)
    const out = await createTmuxRunner(exec).capturePane('labops-carmella')
    expect(out).toBe(IDLE)
    expect(calls).toEqual([['capture-pane', '-p', '-t', PANE, '-S', '-8']])
  })

  test('clearInput sends C-u to the exact pane', async () => {
    const { exec, calls } = recordingExec(IDLE)
    await createTmuxRunner(exec).clearInput('labops-carmella')
    expect(calls).toEqual([['send-keys', '-t', PANE, 'C-u']])
  })

  test('single-line submit types literally, then Enter, both to the exact pane', async () => {
    const { exec, calls } = recordingExec(IDLE)
    await createTmuxRunner(exec).submitText('labops-carmella', 'привет')
    expect(calls).toEqual([
      ['send-keys', '-t', PANE, '-l', 'привет'],
      ['send-keys', '-t', PANE, 'Enter'],
    ])
  })

  test('multi-line submit wraps a bracketed paste to the exact pane', async () => {
    const { exec, calls } = recordingExec(IDLE)
    await createTmuxRunner(exec).submitText('labops-carmella', 'a\nb')
    expect(calls).toEqual([
      ['send-keys', '-t', PANE, '-l', '\x1b[200~a\nb\x1b[201~'],
      ['send-keys', '-t', PANE, 'Enter'],
    ])
  })

  test('no call ever carries the bare session name as a target', async () => {
    const { exec, calls } = recordingExec(STUCK)
    const r = await ensureSubmitted({
      session: 'labops-carmella',
      content: 'что дальше',
      log: noopLog,
      runner: createTmuxRunner(exec),
      sleep: noSleep,
      delayMs: 0,
    })
    expect(r).toBe('recovered')
    const targets = calls.map((argv) => argv[argv.indexOf('-t') + 1])
    expect(targets).toEqual([PANE, PANE, PANE, PANE])
  })
})

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

  test('invalid session name fails open (skip) before any tmux call', async () => {
    const { exec, calls } = recordingExec(STUCK)
    const r = await ensureSubmitted({
      session: 'labops-bad:name',
      content: 'hi',
      log: noopLog,
      runner: createTmuxRunner(exec),
      sleep: noSleep,
      delayMs: 0,
    })
    expect(r).toBe('skip')
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
