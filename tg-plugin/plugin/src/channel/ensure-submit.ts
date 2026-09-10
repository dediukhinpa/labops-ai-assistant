// ensure-submit.ts — guarantee an inbound message actually gets submitted.
//
// The tg channel delivers an inbound by asking Claude Code (research-preview
// `notifications/claude/channel`) to inject it into the input and auto-submit.
// That auto-submit intermittently fails, leaving the message stuck in the `❯`
// box uncommitted; a plain Enter cannot finalise a stuck bracketed-paste. Until
// the agent's watchdog notices (a ~30s cycle) the session is frozen, and its
// recovery can only reconstruct the last visual line from the pane.
//
// This module closes that gap at the source: right after we deliver, we check
// our own tmux pane and, if the message is still sitting there unsubmitted, we
// clear the box and re-type the ORIGINAL content as literal keystrokes + Enter
// (literal typing submits cleanly — it is not a bracketed paste). Because we
// hold the exact text, recovery is full-fidelity. It only acts when genuinely
// stuck, so the happy path (channel auto-submit worked) is never double-fired.
//
// Fail-open by construction: any error resolves to a skip, never a throw into
// the inbound handler.

import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import type { Logger } from '../log.js'
import { paneTarget } from '../tmux/index.js'

const execFileAsync = promisify(execFile)

/** Injectable tmux surface so the logic is testable without a real session. */
export interface TmuxRunner {
  capturePane(session: string): Promise<string>
  clearInput(session: string): Promise<void>
  submitText(session: string, text: string): Promise<void>
}

export interface EnsureSubmitDeps {
  /**
   * Bare tmux session name, e.g. `labops-carmella` — the runner builds the
   * exact pane target itself. Empty ⇒ feature off (returns 'skip').
   */
  session: string
  /** The exact inbound text we delivered — retyped verbatim on recovery. */
  content: string
  log: Logger
  /** Test seams. */
  runner?: TmuxRunner
  sleep?: (ms: number) => Promise<void>
  /** Grace before checking the pane (let Claude Code inject + auto-submit). */
  delayMs?: number
}

const DEFAULT_DELAY_MS = 1200
// bracketed-paste bounds — used to re-type multi-line content without an early
// submit at the first newline (a well-formed paste, unlike the stuck one).
const PASTE_START = '\x1b[200~'
const PASTE_END = '\x1b[201~'

/**
 * The input-box contents with all whitespace stripped. Empty ⇒ clean idle
 * prompt. The `❯` renders with a trailing U+00A0 (not an ASCII space), so it is
 * stripped explicitly.
 */
export function paneInput(pane: string): string {
  const lines = pane.split('\n').filter((l) => l.includes('❯'))
  const last = lines.length > 0 ? lines[lines.length - 1] : undefined
  if (last === undefined) return ''
  const afterPrompt = last.slice(last.indexOf('❯') + 1)
  return afterPrompt.replace(/ /g, '').replace(/\s/g, '')
}

/**
 * A message is sitting in the input unsubmitted: a prompt is visible, no model
 * turn is running (never clobber active work), the input is non-empty, and it
 * is not the rotating placeholder hint `Try"..."`.
 */
export function paneInputStuck(pane: string): boolean {
  if (!/❯|bypass permissions/.test(pane)) return false
  if (pane.includes('esc to interrupt')) return false
  const input = paneInput(pane)
  if (input.length === 0) return false
  if (/^Try".*"$/.test(input)) return false
  return true
}

/**
 * Runs `tmux` with a ready argv and resolves with its stdout. Injectable so a
 * test can assert the exact targets without a real tmux server.
 */
export type TmuxExec = (args: readonly string[]) => Promise<string>

const execTmux: TmuxExec = async (args) => {
  const { stdout } = await execFileAsync('tmux', [...args])
  return stdout
}

/**
 * Build the tmux-backed {@link TmuxRunner}.
 *
 * Every call targets the pane via {@link paneTarget}, never the bare session
 * name. Why: without `=` tmux falls back to the first session whose name merely
 * STARTS with ours, so with an orphaned bun or an AGENT_ID that drifted from the
 * session name the operator's text was typed into a neighbouring agent (e.g.
 * `labops-app` → `labops-app-124546645`). And `=name:` would be the CURRENT
 * window — a second window opened by the operator would receive the keys.
 * With the exact target a missing session makes tmux fail, which the caller
 * already treats as a fail-open skip.
 *
 * @param exec - tmux launcher; defaults to `execFile('tmux', …)`.
 * @returns A runner whose methods take a bare session name.
 */
export function createTmuxRunner(exec: TmuxExec = execTmux): TmuxRunner {
  return {
    capturePane: async (session) =>
      exec(['capture-pane', '-p', '-t', paneTarget(session), '-S', '-8']),
    clearInput: async (session) => {
      // Ctrl-U kills the input line; the stuck paste yields to it (verified live).
      await exec(['send-keys', '-t', paneTarget(session), 'C-u'])
    },
    submitText: async (session, text) => {
      const target = paneTarget(session)
      if (text.includes('\n')) {
        // Multi-line: wrap in a well-formed bracketed paste so newlines are kept
        // and do not submit early, then commit with Enter.
        await exec(['send-keys', '-t', target, '-l', `${PASTE_START}${text}${PASTE_END}`])
      } else {
        // Single-line: literal keystrokes — the proven-reliable path.
        await exec(['send-keys', '-t', target, '-l', text])
      }
      await exec(['send-keys', '-t', target, 'Enter'])
    },
  }
}

const realRunner: TmuxRunner = createTmuxRunner()

export type EnsureSubmitResult = 'skip' | 'noop' | 'recovered'

/**
 * After delivering an inbound, make sure it was submitted; recover it if the
 * channel auto-submit left it stuck. Never throws.
 */
export async function ensureSubmitted(deps: EnsureSubmitDeps): Promise<EnsureSubmitResult> {
  if (deps.session.length === 0 || deps.content.length === 0) return 'skip'
  const runner = deps.runner ?? realRunner
  const sleep = deps.sleep ?? ((ms: number) => new Promise((r) => setTimeout(r, ms)))

  await sleep(deps.delayMs ?? DEFAULT_DELAY_MS)

  let pane: string
  try {
    pane = await runner.capturePane(deps.session)
  } catch (err) {
    deps.log.debug('ensure-submit: capture failed, skipping', {
      session: deps.session,
      error: err instanceof Error ? err.message : String(err),
    })
    return 'skip'
  }

  if (!paneInputStuck(pane)) return 'noop'

  try {
    await runner.clearInput(deps.session)
    await runner.submitText(deps.session, deps.content)
    deps.log.info('ensure-submit: recovered a stuck inbound (clear + literal retype)', {
      session: deps.session,
    })
    return 'recovered'
  } catch (err) {
    deps.log.warn('ensure-submit: recovery failed, leaving it for the watchdog', {
      session: deps.session,
      error: err instanceof Error ? err.message : String(err),
    })
    return 'skip'
  }
}

/** Resolve this agent's tmux session from the environment (empty ⇒ feature off). */
export function resolveAgentSession(env: NodeJS.ProcessEnv = process.env): string {
  const id = env.AGENT_ID ?? env.TELEGRAM_MEMORY_AGENT_LABEL ?? ''
  return id.length > 0 ? `labops-${id}` : ''
}
