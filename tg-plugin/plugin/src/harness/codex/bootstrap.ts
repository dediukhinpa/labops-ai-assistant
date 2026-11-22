// Сборка драйвера Codex из зависимостей плагина (server.ts): Telegram, статус, вопросы
// кнопками, хуки памяти. Здесь только связывание; логика — в driver.ts.

import { join } from 'path'

import type { Logger } from '../../log.js'
import type { AskUserQuestionRelay } from '../../channel/ask-user-question.js'
import type { AskUserQuestionUi } from '../../telegram/ask-user-question.js'
import { ClaudeHookPayloadSchema } from '../../schemas.js'
import { CodexDriver, READ_REACTION, type UserInputAnswers, type UserInputQuestion } from './driver.js'
import { CHANNEL_SERVER_NAME } from './events.js'
import { CHANNEL_TOKEN_ENV, MCP_HTTP_PATH } from './mcp-http.js'
import { rebuildAgentsMd, runMemoryHook } from './memory-hooks.js'
import { spawnAppServer } from './rpc.js'

/** Переменная окружения: какой харнес у роя (её ставит watchdog из swarm.env). */
export const HARNESS_ENV = 'LABOPS_HARNESS'
/** Путь к бинарю codex (закреплённая версия из установщика); по умолчанию — из PATH. */
export const CODEX_BIN_ENV = 'CODEX_BIN'
/** Секреты плагина, которые не должны попасть в окружение codex (и в его shell-команды). */
export const SECRETS_NOT_FOR_CODEX = [
  'TELEGRAM_BOT_TOKEN',
  'TELEGRAM_WEBHOOK_TOKEN',
  'VOICE_TRANSCRIBER_TOKEN',
  'SUPPORT_FOLLOWUP_TOKEN',
] as const

/** Рой работает на Codex. */
export function codexHarnessEnabled(env: NodeJS.ProcessEnv = process.env): boolean {
  return env[HARNESS_ENV] === 'codex'
}

/** Инструкции MCP-сервера канала для Codex: ответ — финальное сообщение хода. */
export const CODEX_CHANNEL_INSTRUCTIONS = [
  'Messages from Telegram arrive as turns: <channel source="telegram" chat_id="..." message_id="..." user="..." ts="...">.',
  'Your final message of the turn is delivered to that chat automatically — that is the answer.',
  'Use reply (pass chat_id back) only for progress notes during long work and for files (files: ["/abs/path"]);',
  'do not repeat in the final message what reply already sent. Photos arrive as <media kind="photo" local_path="...">',
  '— read the file. Other attachments: call download_attachment with file_id and chat_id, then read the returned path.',
  'Telegram exposes no history — ask the user to paste earlier context if you need it.',
].join('\n')

/** Окружение для codex app-server: без секретов плагина, с токеном MCP канала. */
export function codexChildEnv(env: NodeJS.ProcessEnv, channelToken: string): NodeJS.ProcessEnv {
  const out: NodeJS.ProcessEnv = { ...env }
  for (const key of SECRETS_NOT_FOR_CODEX) delete out[key]
  out[CHANNEL_TOKEN_ENV] = channelToken
  return out
}

/** Аргументы app-server: MCP канала по HTTP на внутреннем порту плагина. */
export function appServerArgs(host: string, port: number): string[] {
  const url = `http://${host}:${port}${MCP_HTTP_PATH}`
  return [
    'app-server',
    '-c',
    `mcp_servers.${CHANNEL_SERVER_NAME}.url=${JSON.stringify(url)}`,
    '-c',
    `mcp_servers.${CHANNEL_SERVER_NAME}.bearer_token_env_var=${JSON.stringify(CHANNEL_TOKEN_ENV)}`,
  ]
}

export interface CodexBootstrapDeps {
  workspace: string
  stateRoot: string
  webhookHost: string
  webhookPort: number
  channelToken: string
  log: Logger
  /** Событие хука → статус/прогресс/память (dispatchHookPayload). */
  dispatchHook: (payload: ReturnType<typeof ClaudeHookPayloadSchema.parse>) => Promise<void>
  /** Отправка текста оператору тем же путём, что инструмент reply. */
  sendReply: (chatId: string, text: string) => Promise<void>
  react: (chatId: string, messageId: number, emoji: string) => Promise<void>
  askRelay: AskUserQuestionRelay
  askUi: AskUserQuestionUi
  env?: NodeJS.ProcessEnv
}

/**
 * Вопросы Codex → вопросы релея кнопок; ответы релея (ключ — текст вопроса) → ответы Codex
 * (ключ — id вопроса).
 */
export async function askViaRelay(
  relay: AskUserQuestionRelay,
  ui: AskUserQuestionUi,
  chatId: string,
  questions: UserInputQuestion[],
  requestId: string,
  sessionId: string,
): Promise<UserInputAnswers | null> {
  const submitted = relay.submit({
    toolUseId: requestId,
    sessionId,
    chatId,
    questions: questions.map(q => ({
      question: q.question,
      header: q.header,
      multiSelect: false,
      options: (q.options ?? []).map(o => ({ label: o.label, description: o.description })),
    })),
  })
  if (submitted.requestId !== undefined) await Promise.resolve(ui.startQuestion(submitted.requestId))
  const result = await submitted.result
  if (result.status !== 'answered' || result.updatedInput === undefined) return null
  const answers: UserInputAnswers['answers'] = {}
  for (const q of questions) {
    const value = result.updatedInput.answers[q.question]
    if (value === undefined) continue
    answers[q.id] = { answers: Array.isArray(value) ? value : [value] }
  }
  return { answers }
}

/**
 * Собрать драйвер Codex.
 */
export function createCodexDriver(deps: CodexBootstrapDeps): CodexDriver {
  const env = deps.env ?? process.env
  const bin = env[CODEX_BIN_ENV] !== undefined && env[CODEX_BIN_ENV] !== '' ? env[CODEX_BIN_ENV] : 'codex'
  const childEnv = codexChildEnv(env, deps.channelToken)
  let driver: CodexDriver | undefined
  driver = new CodexDriver({
    workspace: deps.workspace,
    stateFile: join(deps.stateRoot, 'codex-thread.json'),
    log: deps.log,
    connect: () =>
      spawnAppServer({
        bin,
        args: appServerArgs(deps.webhookHost, deps.webhookPort),
        cwd: deps.workspace,
        env: childEnv,
        onStderr: line => deps.log.debug('codex', { line: line.slice(0, 500) }),
      }),
    effects: {
      status: async payload => {
        const parsed = ClaudeHookPayloadSchema.safeParse(payload)
        if (!parsed.success) {
          deps.log.debug('codex status event rejected by schema', { hook: String(payload.hook_event_name) })
          return
        }
        await deps.dispatchHook(parsed.data)
      },
      deliverFinal: (chatId, text) => deps.sendReply(chatId, text),
      askUser: (chatId, questions, requestId) =>
        askViaRelay(deps.askRelay, deps.askUi, chatId, questions, requestId, driver?.thread ?? ''),
      memory: (hook, payload) => runMemoryHook(deps.workspace, hook, payload, childEnv),
      rebuildIdentity: async () => {
        if (!(await rebuildAgentsMd(deps.workspace, childEnv))) {
          deps.log.warn('codex identity script missing — AGENTS.md left as installed')
        }
      },
      markRead: (chatId, messageId) => deps.react(chatId, messageId, READ_REACTION),
    },
  })
  return driver
}
