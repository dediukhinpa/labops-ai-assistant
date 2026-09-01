// inbound-marker.ts — метка «это входящее действительно доставлено агенту».
//
// ЗАЧЕМ: watchdog умеет досылать сообщение, застрявшее в поле ввода, но по
// панели он не отличает потерянное сообщение оператора от любого другого
// текста, который там оказался нарисован. 2026-09-01 это вышло боком: watchdog
// перепечатывал и отправлял агенту текст, которого никто не писал, агент его
// выполнял, результат порождал новый нарисованный текст — и рой уходил в
// самоподдерживающийся цикл. Теперь досылка разрешена только по этой метке.
//
// Формат файла (читает orchestration/lib/pane.sh::inbound_matches):
//   строка 1  — unix-время доставки в секундах,
//   строки 2+ — сам доставленный текст.
//
// Свойства: пишется на КАЖДОЕ доставленное входящее (независимо от того,
// включена ли досылка на стороне плагина), никогда не бросает и никогда не
// задерживает доставку.

import { writeFileSync } from 'node:fs'
import { join } from 'node:path'

import type { Logger } from '../log.js'

export const INBOUND_MARKER_FILE = 'last-inbound'

/**
 * Записать метку доставленного входящего.
 *
 * @param content - текст, отданный агенту (ровно тот, что рисуется в поле).
 * @param log - логгер; ошибки только логируются.
 * @param env - окружение; берётся TELEGRAM_STATE_DIR.
 * @returns true, если метка записана.
 */
export function recordInboundDelivery(
  content: string,
  log: Logger,
  env: NodeJS.ProcessEnv = process.env,
): boolean {
  const dir = env.TELEGRAM_STATE_DIR
  if (dir === undefined || dir.length === 0) return false
  try {
    const payload = `${Math.floor(Date.now() / 1000)}\n${content}`
    writeFileSync(join(dir, INBOUND_MARKER_FILE), payload, { mode: 0o600 })
    return true
  } catch (err) {
    log.debug('метка входящего не записана (игнорируем)', {
      error: err instanceof Error ? err.message : String(err),
    })
    return false
  }
}
