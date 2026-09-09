// Приём апдейтов зависит от режима ingress (см. config.ts).
//
// getUpdates отдаёт апдейт ровно одному читателю. На общем боте токеном
// владеет диспетчер, и если агент поднимет свой поллер, он начнёт воровать
// чужие сообщения — молча и вперемешку. Полноценно поднять server.ts в
// тесте нельзя (stdio-транспорт MCP + живой Telegram), поэтому инвариант
// проверяем по исходнику: конструирование и старт поллера обязаны быть
// под условием режима.

import { describe, expect, test } from 'bun:test'
import { readFileSync } from 'fs'
import { join } from 'path'

const SERVER_SRC = readFileSync(join(import.meta.dir, '..', 'src', 'server.ts'), 'utf8')

describe('ingress guards in server.ts', () => {
  test('poller is constructed only under ingress === poll', () => {
    const guard = SERVER_SRC.indexOf("if (config.ingress === 'poll') {")
    const construct = SERVER_SRC.indexOf('poller = new TelegramPoller({')
    expect(guard).toBeGreaterThan(-1)
    expect(construct).toBeGreaterThan(guard)
    // Единственное место конструирования — иначе гарантия дырявая.
    expect(SERVER_SRC.split('new TelegramPoller(').length - 1).toBe(1)
  })

  test('poller.start is skipped when no poller was constructed', () => {
    expect(SERVER_SRC).toContain('if (poller === undefined) return')
    // Старый безусловный `poller!.start()` роняет процесс в режиме external.
    expect(SERVER_SRC).not.toContain('poller!.start()')
  })

  test('sending stays available in external mode', () => {
    // Отправка не эксклюзивна: ни один выключатель не должен её трогать.
    const telegramApi = SERVER_SRC.indexOf('createTelegramApi(')
    expect(telegramApi).toBeGreaterThan(-1)
    const guard = SERVER_SRC.indexOf("if (config.ingress === 'poll') {")
    expect(telegramApi).toBeLessThan(guard)
  })
})
