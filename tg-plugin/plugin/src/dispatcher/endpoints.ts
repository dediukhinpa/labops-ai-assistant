// Куда доставлять входящее: приёмник агента и его bearer.
//
// И порт, и токен берутся из состояния самого агента — это те же файлы,
// которые пишет установщик и читает плагин. Своя копия в конфиге
// диспетчера разъехалась бы после первой переустановки агента.

import { readFileSync } from 'fs'
import { join } from 'path'

/** Идентификатор агента = один сегмент пути (защита от выхода из каталога). */
const AGENT_ID_RE = /^[A-Za-z0-9][A-Za-z0-9._-]*$/

/** Приёмник хуков плагина: порт агента + путь маршрута. */
const HOOKS_PATH = '/hooks/agent'

export interface AgentEndpoint {
  /** Полный URL приёмника, всегда на loopback. */
  url: string
  /** Bearer этого агента. Никогда не логируется и не попадает в ошибки. */
  token: string
}

/**
 * Собрать адрес доставки для агента.
 *
 * @param stateRoot - Каталог состояния роя (`.../shared/state`).
 * @param agentId - Идентификатор агента из таблицы маршрутов.
 * @returns URL приёмника и bearer агента.
 * @throws Error Если идентификатор небезопасен, порт не задан или нет токена.
 */
export function resolveAgentEndpoint(stateRoot: string, agentId: string): AgentEndpoint {
  if (!AGENT_ID_RE.test(agentId)) {
    throw new Error(`unsafe agent id: ${JSON.stringify(agentId)}`)
  }
  const telegramDir = join(stateRoot, agentId, 'telegram')

  let envRaw: string
  try {
    envRaw = readFileSync(join(telegramDir, 'channel.env'), 'utf8')
  } catch {
    throw new Error(`agent '${agentId}': channel.env is unreadable`)
  }
  const port = readPort(envRaw)
  if (port === undefined) {
    throw new Error(`agent '${agentId}': no TELEGRAM_WEBHOOK_PORT in channel.env`)
  }

  let token: string
  try {
    token = readFileSync(join(telegramDir, 'webhook-token'), 'utf8').trim()
  } catch {
    // Текст ошибки уходит в логи, поэтому здесь только факт отсутствия.
    throw new Error(`agent '${agentId}': webhook token is unreadable`)
  }
  if (token === '') {
    throw new Error(`agent '${agentId}': webhook token is empty`)
  }

  return { url: `http://127.0.0.1:${port}${HOOKS_PATH}`, token }
}

/** Достать порт приёмника из channel.env, игнорируя закомментированные строки. */
function readPort(envRaw: string): number | undefined {
  for (const line of envRaw.split('\n')) {
    const m = /^TELEGRAM_WEBHOOK_PORT=([0-9]+)\s*$/.exec(line.trim())
    if (m?.[1] !== undefined) return Number.parseInt(m[1], 10)
  }
  return undefined
}
