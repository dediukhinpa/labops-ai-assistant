#!/usr/bin/env bun
// Диспетчер общего бота.
//
// Один процесс владеет токеном бота приложения и единственный читает
// getUpdates: приём в Telegram эксклюзивен, а отправка — нет. По `from.id`
// он находит агента пользователя и кладёт сообщение в его приёмник
// (POST /hooks/agent) — тем же путём, которым в сессию пишет приложение.
// Ответы агенты шлют сами, своим sendMessage с тем же токеном.
//
// Агенты за диспетчером обязаны стоять в режиме ingress=external
// (см. config.ts), иначе они начнут вычитывать апдейты друг у друга.
//
// Запуск: bun run src/dispatcher/main.ts
// Окружение:
//   TELEGRAM_BOT_TOKEN       — токен общего бота (обязателен)
//   DISPATCHER_STATE_DIR     — состояние диспетчера (курсор, dead-letter)
//   DISPATCHER_ROUTES_PATH   — таблица маршрутов telegram_id → агент
//   DISPATCHER_AGENT_STATE_ROOT — каталог состояния агентов роя

import { Bot } from 'grammy'
import { homedir } from 'os'
import { join } from 'path'

import { getStatePaths, loadConfig, RuntimeEnvSchema } from '../config.js'
import { createLogger } from '../log.js'
import { ensureStateDirs } from '../state/store.js'
import { TelegramPoller } from '../telegram/poller.js'
import { deliverToAgent } from './deliver.js'
import { dispatchUpdate } from './dispatch.js'
import { resolveAgentEndpoint } from './endpoints.js'
import { RouteTable } from './routes.js'

const DEFAULT_STATE_DIR = join(homedir(), '.claude-lab', 'shared', 'state', 'telegram-dispatcher')
const DEFAULT_AGENT_STATE_ROOT = join(homedir(), '.claude-lab', 'shared', 'state')

const stateDir = process.env.DISPATCHER_STATE_DIR ?? DEFAULT_STATE_DIR
const agentStateRoot = process.env.DISPATCHER_AGENT_STATE_ROOT ?? DEFAULT_AGENT_STATE_ROOT
const routesPath = process.env.DISPATCHER_ROUTES_PATH ?? join(stateDir, 'routes.json')

// Токен виден только процессу: в логи он попасть не может — createLogger
// получает его в списке секретов и вырезает из любой строки.
const botToken = process.env.TELEGRAM_BOT_TOKEN ?? ''
if (botToken === '') {
  process.stderr.write('TELEGRAM_BOT_TOKEN is required\n')
  process.exit(1)
}

const log = createLogger('dispatcher', { secrets: [botToken] })

// Конфиг и пути состояния берём у плагина: поллер уже умеет курсор на
// диске, backoff по классам ошибок, dead-letter и pid-лок токена.
const env = { TELEGRAM_BOT_TOKEN: botToken, TELEGRAM_STATE_DIR: stateDir }
const config = loadConfig(env)
const statePaths = getStatePaths(config, RuntimeEnvSchema.parse(env))
ensureStateDirs(statePaths)

const bot = new Bot(botToken)
const routes = new RouteTable(routesPath, log)

let poller: TelegramPoller | undefined
let shuttingDown = false

function shutdown(): void {
  if (shuttingDown) return
  shuttingDown = true
  log.info('останавливаюсь')
  const stopped = poller ? poller.stop() : Promise.resolve()
  setTimeout(() => process.exit(0), 2000)
  void stopped.finally(() => process.exit(0))
}

process.on('SIGTERM', shutdown)
process.on('SIGINT', shutdown)

try {
  await bot.init()
  log.info('диспетчер поднялся', {
    bot_id: bot.botInfo.id,
    routes: routes.size,
    routes_path: routesPath,
  })
} catch (err) {
  log.error('bot.init() не прошёл — токен или сеть', {
    error: err instanceof Error ? err.message : String(err),
  })
  process.exit(1)
}

poller = new TelegramPoller({
  bot,
  config,
  statePaths,
  log,
  onUpdate: async (update) => {
    await dispatchUpdate(update, {
      lookupAgent: (telegramId) => routes.lookup(telegramId),
      resolveEndpoint: (agentId) => resolveAgentEndpoint(agentStateRoot, agentId),
      deliver: (target, payload) => deliverToAgent(target, payload),
      replyToUser: async (chatId, text) => {
        await bot.api.sendMessage(chatId, text)
      },
      log,
    })
  },
})

try {
  await poller.start()
} catch (err) {
  if (!shuttingDown) {
    log.error('поллер остановился с ошибкой', {
      error: err instanceof Error ? err.message : String(err),
    })
    shutdown()
  }
}
