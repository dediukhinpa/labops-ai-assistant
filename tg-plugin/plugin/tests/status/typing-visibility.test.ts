// Видимость статуса «Печатает…» на дефолтах — регрессия 16.09.2026.
//
// У свежеустановленного агента в Telegram не появлялось вообще никакого
// статуса, пока он думает. Причина — сочетание двух дефолтов:
//   * `status.suppress_typing_bubble: true` — плагин не шлёт бабл, пока
//     состояние `typing`, и создаёт его лениво на первом переходе
//     thinking/tool/activity;
//   * переходы приходят только из хуков Claude Code в /hooks/agent, а их
//     в агентском флоу никто не регистрирует (settings.json воркспейса
//     держит только heartbeat и память, install-hooks.sh — ручной шаг).
// Значит, ленивый бабл не создаётся никогда, и в чате остаётся лишь
// нативная анимация sendChatAction.
//
// Поэтому new-agent.sh пишет агенту config.json с
// `status.suppress_typing_bubble: false`. Тест держит оба конца: что
// дефолт схемы действительно молчит и что конфиг агента — говорит.

import { describe, expect, test } from 'bun:test'

import { StatusManager, type TelegramApiForStatus } from '../../src/status/status-manager.js'
import { AppConfigSchema } from '../../src/config.js'
import { createLogger } from '../../src/log.js'

const silentLog = createLogger('test', {
  stream: { write: () => true } as unknown as NodeJS.WritableStream,
})

// Ровно тот JSON, который new-agent.sh кладёт в state/<agent>/telegram/config.json.
const AGENT_CONFIG_JSON = '{"webhook": {"enabled": true}, "status": {"suppress_typing_bubble": false}}'

const BOT_TOKEN = '1234567890:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'

interface Recorded {
  readonly calls: string[]
  readonly texts: string[]
  readonly api: TelegramApiForStatus
}

function recordingApi(): Recorded {
  const calls: string[] = []
  const texts: string[] = []
  const api: TelegramApiForStatus = {
    sendMessage: async (_chatId: string, text: string) => {
      calls.push('sendMessage')
      texts.push(text)
      return { message_id: 42 }
    },
    editMessageText: async () => {
      calls.push('editMessageText')
    },
    deleteMessage: async () => {
      calls.push('deleteMessage')
    },
    sendChatAction: async () => {
      calls.push('sendChatAction')
    },
  } as unknown as TelegramApiForStatus
  return { calls, texts, api }
}

// Таймеры-заглушки: тесту нужен только первый проход start(), а живой
// setTimeout оставил бы после себя тикающую анимацию.
const frozenTimers = {
  setTimer: () => 0 as unknown as NodeJS.Timeout,
  clearTimer: () => {},
}

describe('видимость статуса «Печатает…»', () => {
  test('на дефолтах схемы бабл не отправляется — виден только нативный индикатор', async () => {
    const config = AppConfigSchema.parse({ bot_token: BOT_TOKEN })
    expect(config.status.suppress_typing_bubble).toBe(true)

    const rec = recordingApi()
    const manager = new StatusManager({
      telegramApi: rec.api,
      config,
      log: silentLog,
      policy: null,
      ...frozenTimers,
    })

    await manager.start('100000001', 7)

    expect(rec.calls).toContain('sendChatAction')
    expect(rec.calls).not.toContain('sendMessage')
  })

  test('с config.json агента бабл «Печатает…» уходит сразу', async () => {
    const config = AppConfigSchema.parse({
      bot_token: BOT_TOKEN,
      ...(JSON.parse(AGENT_CONFIG_JSON) as Record<string, unknown>),
    })
    expect(config.status.suppress_typing_bubble).toBe(false)

    const rec = recordingApi()
    const manager = new StatusManager({
      telegramApi: rec.api,
      config,
      log: silentLog,
      policy: null,
      ...frozenTimers,
    })

    await manager.start('100000001', 7)

    expect(rec.calls).toContain('sendMessage')
    expect(rec.texts[0]).toContain('Печатает')
  })
})
