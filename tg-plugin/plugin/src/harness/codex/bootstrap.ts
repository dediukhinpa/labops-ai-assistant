// Сборка драйвера Codex из зависимостей плагина (server.ts): Telegram, статус, вопросы
// кнопками, хуки памяти. Здесь только связывание; логика — в driver.ts.

import { createHash } from 'crypto'
import { readFileSync } from 'fs'
import { join } from 'path'

import type { Logger } from '../../log.js'
import { ClaudeHookPayloadSchema } from '../../schemas.js'
import {
  CodexDriver,
  DONE_REACTION,
  READ_REACTION,
  ITEM_STALL_ENV,
  TURN_STALL_ENV,
  type PiiMode,
} from './driver.js'
import { CHANNEL_SERVER_NAME } from './events.js'
import { CHANNEL_TOKEN_ENV, MCP_HTTP_PATH } from './mcp-http.js'
import { rebuildAgentsMd, runMemoryHook } from './memory-hooks.js'
import { spawnAppServer } from './rpc.js'

/** Переменная окружения: какой харнес у роя (её ставит watchdog из swarm.env). */
export const HARNESS_ENV = 'LABOPS_HARNESS'
/** Путь к бинарю codex (закреплённая версия из установщика); по умолчанию — из PATH. */
export const CODEX_BIN_ENV = 'CODEX_BIN'
/** Файл режима pii-proxy агента (proxy|direct): его путь передаёт session-exec.sh. */
export const PII_MODE_FILE_ENV = 'LABOPS_PII_MODE_FILE'
/** Провайдер модели агента в config.toml (шаблон agent-template/templates/codex). */
export const PII_MODEL_PROVIDER = 'labops-pii'
/**
 * Адрес бэкенда для режима напрямую: туда же ходит сам pii-proxy (его upstream chatgpt.com, путь
 * как есть), вход ChatGPT тот же. Меняется только base_url провайдера, не сам провайдер: Codex
 * не даёт продолжить нить с другим провайдером («Cannot change this thread's model provider …
 * on resume», проверено на 0.171.0), а с тем же id нить продолжается и ходит по новому адресу.
 */
export const DIRECT_BACKEND_URL = 'https://chatgpt.com/backend-api/codex'
/** Секреты плагина, которые не должны попасть в окружение codex (и в его shell-команды). */
export const SECRETS_NOT_FOR_CODEX = [
  'TELEGRAM_BOT_TOKEN',
  'TELEGRAM_WEBHOOK_TOKEN',
  'VOICE_TRANSCRIBER_TOKEN',
  'SUPPORT_FOLLOWUP_TOKEN',
] as const

/** Файлы инструкций, которые Codex читает при создании нити (имя в CODEX_HOME и в cwd). */
export const INSTRUCTION_FILES = ['AGENTS.override.md', 'AGENTS.md'] as const

/**
 * Отпечаток инструкций нити: sha256 по AGENTS.md рабочей папки и глобальным файлам
 * инструкций в CODEX_HOME (каких нет — пропускаются). Драйвер сравнивает его с сохранённым:
 * Codex перечитывает инструкции только при создании нити, а thread/resume их не обновляет.
 *
 * @param workspace Рабочая папка агента.
 * @param codexHome CODEX_HOME агента; пусто — только рабочая папка.
 */
export function instructionsHash(workspace: string, codexHome: string): string {
  const h = createHash('sha256')
  const files = [
    ...(codexHome !== '' ? INSTRUCTION_FILES.map(name => join(codexHome, name)) : []),
    join(workspace, 'AGENTS.md'),
  ]
  for (const path of files) {
    let body: string
    try {
      body = readFileSync(path, 'utf8')
    } catch {
      continue
    }
    h.update(path).update('\0').update(body).update('\0')
  }
  return h.digest('hex')
}

/**
 * Предел молчания хода из окружения (секунды → мс). Пусто или не положительное целое —
 * undefined (умолчание драйвера).
 */
export function turnStallFromEnv(env: NodeJS.ProcessEnv): number | undefined {
  return secondsFromEnv(env, TURN_STALL_ENV)
}

/** Предел молчания при незавершённом элементе хода из окружения (секунды → мс). */
export function itemStallFromEnv(env: NodeJS.ProcessEnv): number | undefined {
  return secondsFromEnv(env, ITEM_STALL_ENV)
}

function secondsFromEnv(env: NodeJS.ProcessEnv, name: string): number | undefined {
  const raw = env[name]
  if (raw === undefined || !/^\d+$/.test(raw.trim())) return undefined
  const sec = Number.parseInt(raw.trim(), 10)
  return sec > 0 ? sec * 1000 : undefined
}

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
  'When you need something from the operator, ask in a plain message — never as buttons or a menu. List any',
  'choices in words in that message. The operator answers in their own words as the next message. Ask one',
  'thing at a time and wait for the reply before continuing; do not use request_user_input tools to present',
  'choices as buttons.',
].join('\n')

/** Окружение для codex app-server: без секретов плагина, с токеном MCP канала. */
export function codexChildEnv(env: NodeJS.ProcessEnv, channelToken: string): NodeJS.ProcessEnv {
  const out: NodeJS.ProcessEnv = { ...env }
  for (const key of SECRETS_NOT_FOR_CODEX) delete out[key]
  out[CHANNEL_TOKEN_ENV] = channelToken
  return out
}

/**
 * Аргументы app-server: MCP канала по HTTP на внутреннем порту плагина. Через прокси (норма)
 * аргументы прежние; напрямую — плюс адрес бэкенда вместо pii-proxy для провайдера агента.
 */
export function appServerArgs(host: string, port: number, mode: PiiMode = 'proxy'): string[] {
  const url = `http://${host}:${port}${MCP_HTTP_PATH}`
  const args = [
    'app-server',
    '-c',
    `mcp_servers.${CHANNEL_SERVER_NAME}.url=${JSON.stringify(url)}`,
    '-c',
    `mcp_servers.${CHANNEL_SERVER_NAME}.bearer_token_env_var=${JSON.stringify(CHANNEL_TOKEN_ENV)}`,
  ]
  if (mode === 'direct') {
    const key = `model_providers.${PII_MODEL_PROVIDER}.base_url`
    args.push('-c', `${key}=${JSON.stringify(DIRECT_BACKEND_URL)}`)
  }
  return args
}

/**
 * Читатель режима pii-proxy из файла агента. Файла нет или в нём не direct — через прокси:
 * обход прокси включается только явной записью watchdog/start-agent.
 *
 * @param path Путь файла режима; пусто — режим всегда «через прокси».
 */
export function piiModeReader(path: string): () => PiiMode {
  return () => {
    if (path === '') return 'proxy'
    try {
      return readFileSync(path, 'utf8').trim() === 'direct' ? 'direct' : 'proxy'
    } catch {
      return 'proxy'
    }
  }
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
  /** Личка оператора для предупреждений драйвера; не задана — только журнал. */
  operatorChatId?: string
  env?: NodeJS.ProcessEnv
}

/**
 * Собрать драйвер Codex.
 */
export function createCodexDriver(deps: CodexBootstrapDeps): CodexDriver {
  const env = deps.env ?? process.env
  const bin = env[CODEX_BIN_ENV] !== undefined && env[CODEX_BIN_ENV] !== '' ? env[CODEX_BIN_ENV] : 'codex'
  const childEnv = codexChildEnv(env, deps.channelToken)
  const modeFile = env[PII_MODE_FILE_ENV] ?? ''
  const turnStallMs = turnStallFromEnv(env)
  const itemStallMs = itemStallFromEnv(env)
  const codexHome = env.CODEX_HOME ?? ''
  let driver: CodexDriver | undefined
  driver = new CodexDriver({
    workspace: deps.workspace,
    stateFile: join(deps.stateRoot, 'codex-thread.json'),
    queueFile: join(deps.stateRoot, 'codex-queue.json'),
    log: deps.log,
    identityHash: () => instructionsHash(deps.workspace, codexHome),
    ...(turnStallMs !== undefined ? { turnStallMs } : {}),
    ...(itemStallMs !== undefined ? { itemStallMs } : {}),
    ...(modeFile !== '' ? { piiMode: piiModeReader(modeFile) } : {}),
    connect: mode =>
      spawnAppServer({
        bin,
        args: appServerArgs(deps.webhookHost, deps.webhookPort, mode),
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
      memory: (hook, payload) => runMemoryHook(deps.workspace, hook, payload, childEnv),
      rebuildIdentity: async () => {
        if (!(await rebuildAgentsMd(deps.workspace, childEnv))) {
          deps.log.warn('codex identity script missing — AGENTS.md left as installed')
        }
      },
      markRead: (chatId, messageId) => deps.react(chatId, messageId, READ_REACTION),
      markDone: (chatId, messageId) => deps.react(chatId, messageId, DONE_REACTION),
      notifyOperator: async text => {
        if (deps.operatorChatId === undefined) {
          deps.log.warn('codex operator notice skipped: no operator chat', { text: text.slice(0, 200) })
          return
        }
        await deps.sendReply(deps.operatorChatId, text)
      },
    },
  })
  return driver
}
