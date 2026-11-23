// Multichat на харнесе Codex: закрыто (fail closed).
//
// У Claude Code multichat — пул сессий tmux по чатам; у Codex такого пула нет, есть одна нить
// app-server. Пропусти мы личку всех allowed_user_ids и группы в эту нить — контексты людей
// смешаются, а таблица замен ПДн (pii-proxy привязывает её к сессии) восстановит токены
// одного собеседника в ответе другому. Ровно против этого dm-routing.ts отказывает
// «fail closed». Поэтому при multichat.enabled на Codex принимается только личка операторов
// (как их видит resolveCodexOperatorUserIds); чужая личка и любые группы отбрасываются до
// обработчиков (без 👀, статуса и записи в очередь) с log.error. Операторам — одно
// предупреждение при старте.

import { mkdirSync, readFileSync, writeFileSync } from 'fs'
import { dirname } from 'path'

import type { AppConfig } from '../../config.js'
import type { Logger } from '../../log.js'
import { resolveCodexOperatorUserIds } from '../../telegram/dm-routing.js'

/** Как часто повторять log.error про одну и ту же группу (чат может быть шумным). */
export const GROUP_REFUSAL_LOG_INTERVAL_MS = 10 * 60 * 1000
/** Не повторять предупреждение операторам чаще (рестарты watchdog не должны спамить). */
export const OPERATOR_NOTICE_INTERVAL_MS = 24 * 60 * 60 * 1000

/** Текст предупреждения операторам. */
export const CODEX_MULTICHAT_NOTICE =
  '⚠️ Multichat на харнесе Codex не поддерживается: у агента одна нить на всех, и личка ' +
  'разных людей смешалась бы в один контекст. Сейчас принимаются только ваши личные ' +
  'сообщения; личка других людей и сообщения групп отбрасываются. Выключите multichat ' +
  'или переведите рой на Claude Code.'

/** Решение по входящему сообщению. */
export type CodexMultichatVerdict = 'pass' | 'drop_dm' | 'drop_group'

/** Минимум сведений о сообщении, нужный решению. */
export interface GuardMessage {
  chatType: string | undefined
  chatId: string
  senderId: string
}

/**
 * Пропустить ли сообщение в обработчики при multichat на Codex.
 *
 * @param config Конфиг плагина.
 * @param msg Тип чата, его id и отправитель.
 * @returns pass — дальше по обычному пути (оператор или чужак, которого отбросит gate);
 *   drop_dm — личка разрешённого не-оператора; drop_group — группа.
 */
export function codexMultichatVerdict(config: AppConfig, msg: GuardMessage): CodexMultichatVerdict {
  if (msg.chatType === 'group' || msg.chatType === 'supergroup') return 'drop_group'
  if (msg.chatType !== 'private') return 'pass'
  const operators = new Set(resolveCodexOperatorUserIds(config).map(String))
  if (operators.has(msg.senderId)) return 'pass'
  // Не из allowlist — gate.ts и так отбросит (тихо, как всегда); кричать не о чем.
  const allowed = new Set(config.allowed_user_ids.map(String))
  return allowed.has(msg.senderId) ? 'drop_dm' : 'pass'
}

/** То, что middleware читает из контекста grammY (структурно совместимо с Context). */
export interface GuardContext {
  message?: { chat: { id: number; type: string }; from?: { id: number } | undefined } | undefined
}

/**
 * Middleware grammY: отбрасывает чужую личку и группы до обработчиков.
 *
 * @param config Конфиг плагина.
 * @param log Логгер.
 * @param now Часы (тесты).
 */
export function createCodexMultichatGuard(
  config: AppConfig,
  log: Logger,
  now: () => number = Date.now,
): (ctx: GuardContext, next: () => Promise<void>) => Promise<void> {
  const groupLogged = new Map<string, number>()
  return async (ctx, next) => {
    const m = ctx.message
    if (m === undefined) return next()
    const msg: GuardMessage = {
      chatType: m.chat.type,
      chatId: String(m.chat.id),
      senderId: m.from !== undefined ? String(m.from.id) : '',
    }
    const verdict = codexMultichatVerdict(config, msg)
    if (verdict === 'pass') return next()
    if (verdict === 'drop_dm') {
      // Без id и имён: журнал читают не только операторы.
      log.error('codex.multichat_refused — dropping non-operator dm', {
        reason: 'multichat_not_supported_on_codex',
        hint: 'на Codex одна нить на всех; выключите multichat или используйте Claude Code',
      })
      return
    }
    const t = now()
    const last = groupLogged.get(msg.chatId)
    if (last === undefined || t - last >= GROUP_REFUSAL_LOG_INTERVAL_MS) {
      groupLogged.set(msg.chatId, t)
      log.error('codex.multichat_refused — dropping group message', {
        reason: 'multichat_not_supported_on_codex',
        hint: 'на Codex одна нить на всех; выключите multichat или используйте Claude Code',
      })
    }
  }
}

export interface OperatorNoticeOptions {
  config: AppConfig
  send: (chatId: string, text: string) => Promise<void>
  log: Logger
  /** Файл-отметка последнего предупреждения (в каталоге состояния плагина). */
  markerPath: string
  now?: () => number
}

/**
 * Предупредить операторов, что multichat на Codex выключен. Не чаще раза в сутки: watchdog
 * может перезапускать плагин часто.
 *
 * @returns Сколько операторов предупреждено.
 */
export async function warnOperatorsCodexMultichat(opts: OperatorNoticeOptions): Promise<number> {
  const t = (opts.now ?? Date.now)()
  try {
    const last = Number.parseInt(readFileSync(opts.markerPath, 'utf8').trim(), 10)
    if (Number.isFinite(last) && t - last < OPERATOR_NOTICE_INTERVAL_MS) return 0
  } catch {
    // отметки нет — предупреждаем
  }
  const operators = resolveCodexOperatorUserIds(opts.config)
  if (operators.length === 0) {
    opts.log.error('codex multichat refused but no operator to tell', {
      hint: 'задайте operator_user_ids или TELEGRAM_ALLOWED_USER_IDS',
    })
    return 0
  }
  let sent = 0
  for (const id of operators) {
    try {
      await opts.send(String(id), CODEX_MULTICHAT_NOTICE)
      sent += 1
    } catch (err) {
      opts.log.warn('codex multichat notice failed', { error: err instanceof Error ? err.message : String(err) })
    }
  }
  if (sent > 0) {
    try {
      mkdirSync(dirname(opts.markerPath), { recursive: true })
      writeFileSync(opts.markerPath, `${t}\n`, { mode: 0o600 })
    } catch (err) {
      opts.log.warn('codex multichat notice marker not written', {
        error: err instanceof Error ? err.message : String(err),
      })
    }
  }
  return sent
}
