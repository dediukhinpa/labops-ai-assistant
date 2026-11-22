// Запуск хуков памяти рабочей папки агента и пересборка AGENTS.md для драйвера Codex.
//
// Скрипты те же, что у Claude Code (agent-template/hooks, scripts): у Claude их вызывает
// харнес по settings.json, у Codex — драйвер по событиям нити. JSON-полезная нагрузка
// уходит на stdin, как у хуков Claude, поэтому скрипты менять не нужно.

import { spawn } from 'child_process'
import { existsSync } from 'fs'
import { join } from 'path'

import type { MemoryHook } from './driver.js'

/** Предел работы хука; brain-flush пишет в общую память по сети — ему дольше. */
export const HOOK_TIMEOUT_MS = 60_000
export const FLUSH_TIMEOUT_MS = 120_000
/** Предел stdout хука, который читаем (session-start выдаёт до пары КБ). */
const MAX_STDOUT_BYTES = 64 * 1024

interface HookCommand {
  script: string
  args: string[]
  timeoutMs: number
}

/** Какой скрипт рабочей папки отвечает за хук. */
export function hookCommand(workspace: string, hook: MemoryHook): HookCommand {
  switch (hook) {
    case 'session-start':
      return { script: join(workspace, 'hooks', 'session-start-hook.sh'), args: [], timeoutMs: HOOK_TIMEOUT_MS }
    case 'stop':
      return { script: join(workspace, 'hooks', 'stop-hook.sh'), args: [], timeoutMs: HOOK_TIMEOUT_MS }
    case 'precompact':
      return { script: join(workspace, 'hooks', 'precompact-hook.sh'), args: [], timeoutMs: HOOK_TIMEOUT_MS }
    case 'heartbeat':
      return { script: join(workspace, 'hooks', 'heartbeat-hook.sh'), args: [], timeoutMs: HOOK_TIMEOUT_MS }
    case 'session-end':
      return {
        script: join(workspace, 'scripts', 'brain-flush.sh'),
        args: ['--reason', 'session-end'],
        timeoutMs: FLUSH_TIMEOUT_MS,
      }
  }
}

/**
 * Запустить процесс, подать stdin, вернуть stdout. Падение и таймаут — исключение.
 *
 * @param cmd Программа.
 * @param args Аргументы.
 * @param opts Окружение, cwd, stdin и таймаут.
 * @returns stdout процесса.
 */
export function runProcess(
  cmd: string,
  args: readonly string[],
  opts: { cwd: string; env: NodeJS.ProcessEnv; stdin: string; timeoutMs: number },
): Promise<string> {
  return new Promise((resolve, reject) => {
    const child = spawn(cmd, [...args], { cwd: opts.cwd, env: opts.env, stdio: ['pipe', 'pipe', 'ignore'] })
    let out = ''
    let done = false
    const timer = setTimeout(() => {
      if (done) return
      done = true
      child.kill('SIGKILL')
      reject(new Error(`${cmd}: timed out after ${opts.timeoutMs} ms`))
    }, opts.timeoutMs)
    child.stdout.on('data', (chunk: Buffer) => {
      if (out.length < MAX_STDOUT_BYTES) out += chunk.toString('utf8')
    })
    child.on('error', err => {
      if (done) return
      done = true
      clearTimeout(timer)
      reject(err)
    })
    child.on('close', code => {
      if (done) return
      done = true
      clearTimeout(timer)
      if (code === 0) resolve(out.slice(0, MAX_STDOUT_BYTES))
      else reject(new Error(`${cmd}: exit ${String(code)}`))
    })
    child.stdin.on('error', () => undefined)
    child.stdin.end(opts.stdin)
  })
}

/**
 * Запустить хук памяти. Нет скрипта (старая рабочая папка) — пустой результат.
 */
export async function runMemoryHook(
  workspace: string,
  hook: MemoryHook,
  payload: Record<string, unknown>,
  env: NodeJS.ProcessEnv,
): Promise<string> {
  const cmd = hookCommand(workspace, hook)
  if (!existsSync(cmd.script)) return ''
  return runProcess('bash', [cmd.script, ...cmd.args], {
    cwd: workspace,
    env: { ...env, AGENT_WORKSPACE: workspace },
    stdin: JSON.stringify(payload),
    timeoutMs: cmd.timeoutMs,
  })
}

/** Скрипт сборки AGENTS.md в рабочей папке (его кладёт установщик агента на Codex). */
export function identityScript(workspace: string): string {
  return join(workspace, 'scripts', 'codex_workspace.py')
}

/**
 * Пересобрать AGENTS.md из AGENTS.src.md и файлов памяти.
 *
 * @returns false — скрипта нет, остаётся AGENTS.md, собранный при установке.
 */
export async function rebuildAgentsMd(workspace: string, env: NodeJS.ProcessEnv): Promise<boolean> {
  const script = identityScript(workspace)
  if (!existsSync(script)) return false
  await runProcess('python3', ['-I', script, 'agents-md', workspace], {
    cwd: workspace,
    env,
    stdin: '',
    timeoutMs: HOOK_TIMEOUT_MS,
  })
  return true
}
