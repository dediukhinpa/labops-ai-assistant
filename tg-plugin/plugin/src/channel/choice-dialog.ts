// choice-dialog.ts — окна выбора Claude Code на экране агента → Telegram.
//
// ЗАЧЕМ. Claude Code иногда останавливает сессию и ждёт, пока человек выберет
// пункт в окне: «❯ 1. … / 2. …». Пример, из-за которого модуль написан (26.11.2026,
// developer): фильтр безопасности Opus 5.5 счёл разбор учебной лабы PortSwigger
// кибератакой и поставил сессию на паузу «Session paused · 1. Switch to Opus 4.8 /
// 2. Edit prompt and retry». Оператор агента сидит в Telegram, а не в tmux, и
// окна не видит: агент молчал почти три часа, тревоги не было.
//
// ЧТО ДЕЛАЕТ. Раз в несколько секунд смотрит СВОЮ панель (как ensure-submit.ts).
// Окно, простоявшее два опроса подряд, уходит оператору сообщением с кнопками;
// нажатая кнопка (или ответ цифрой) нажимает тот же пункт в панели. Пауза по
// фильтру безопасности — особый случай: пункт «Switch to <модель>» выбирается
// сам (решение владельца 26.11.2026: агент переключает модель автоматически),
// оператору приходит уведомление. Переключение, которое сделал сам Claude Code
// (настройка switchModelsOnFlag), тоже сообщается — один раз на текст плашки.
//
// Окна старта сессии (вопрос о каналах разработки, гейт Bypass Permissions,
// мастер первого запуска) не наши: их ведёт watchdog, а плагин в это время ещё
// не запущен. Отказ любой части молчаливый: ошибка опроса — пропуск такта.

import { randomBytes } from 'node:crypto'
import { execFile } from 'node:child_process'
import { promisify } from 'node:util'

import type { Logger } from '../log.js'
import { paneTarget } from '../tmux/index.js'
import type { InlineKeyboardLike, TelegramApi } from './tools.js'

const execFileAsync = promisify(execFile)

/** Пункт окна выбора. */
export interface ChoiceOption {
  /** Номер пункта, как его рисует Claude Code («2.» → 2). */
  readonly n: number
  /** Текст пункта вместе со строками-продолжениями. */
  readonly label: string
}

/** Окно выбора, распознанное на экране. */
export interface ChoiceDialog {
  /** Текст окна над пунктами, по строке, без пустых. */
  readonly body: readonly string[]
  /** Пункты по порядку, номера 1..N подряд. */
  readonly options: readonly ChoiceOption[]
  /** Номер пункта, на котором сейчас стоит «❯». */
  readonly selected: number
  /** Отпечаток окна: одно и то же окно на разных опросах даёт тот же отпечаток. */
  readonly fingerprint: string
}

/** Пауза по фильтру безопасности и пункт, переключающий модель. */
export interface SafeguardPause {
  /** Пункт «Switch to <модель>». */
  readonly switchOption: ChoiceOption
  /** Модель, на которую переключит пункт. */
  readonly model: string
  /** Категория из строки «Details: `[cyber]`», если она есть. */
  readonly category: string | undefined
}

// Выбранный пункт: «❯ 2. Текст». Номер — одна-две цифры.
const SELECTED_OPTION_RE = /^\s*❯\s*(\d{1,2})\.\s+(\S.*?)\s*$/
// Любой пункт, выбранный или нет.
const OPTION_RE = /^\s*(?:❯\s*)?(\d{1,2})\.\s+(\S.*?)\s*$/
// Горизонтальная линия, которой Claude Code отделяет окно и поле ввода.
const RULE_RE = /^\s*[─━]{3,}/
// Строка режима под полем ввода: если она ниже «❯», это поле ввода, не окно.
const STATUS_LINE_RE = /bypass permissions|shift\+tab to cycle/
// Сколько строк-продолжений может стоять между соседними пунктами.
const MAX_GAP_LINES = 3
// Окна старта сессии — их ведёт watchdog (lib/pane.sh), не плагин.
const STARTUP_DIALOG_RE = new RegExp([
  'I am using this for local development',
  'Bypass Permissions mode',
  'Choose the text style that looks best',
  'Select login method',
].join('|'))

/**
 * Распознаёт окно выбора на экране.
 *
 * Отличить окно от поля ввода с набранным «1. что-то» помогает то, что под полем
 * ввода всегда есть линия и строка режима, а под пунктами окна — нет.
 *
 * @param pane - Текст панели (`tmux capture-pane -p`).
 * @returns Окно или `null`, если окна выбора на экране нет.
 */
export function parseChoiceDialog(pane: string): ChoiceDialog | null {
  const lines = pane.split('\n').map((l) => l.replace(/\s+$/, ''))
  let markerIdx = -1
  for (let i = lines.length - 1; i >= 0; i -= 1) {
    if ((lines[i] ?? '').includes('❯')) {
      markerIdx = i
      break
    }
  }
  if (markerIdx < 0) return null
  const selectedMatch = SELECTED_OPTION_RE.exec(lines[markerIdx] ?? '')
  if (selectedMatch === null) return null
  for (const below of lines.slice(markerIdx + 1)) {
    if (RULE_RE.test(below) || STATUS_LINE_RE.test(below)) return null
  }

  let ruleIdx = -1
  for (let i = markerIdx - 1; i >= 0; i -= 1) {
    if (RULE_RE.test(lines[i] ?? '')) {
      ruleIdx = i
      break
    }
  }

  const selected = Number(selectedMatch[1])
  const found = new Map<number, number>()   // номер пункта → индекс строки
  found.set(selected, markerIdx)
  // Вверх: пункты selected-1 … 1, между ними не больше MAX_GAP_LINES строк.
  let want = selected - 1
  let gap = 0
  for (let i = markerIdx - 1; i > ruleIdx && want >= 1; i -= 1) {
    const m = OPTION_RE.exec(lines[i] ?? '')
    if (m !== null && Number(m[1]) === want) {
      found.set(want, i)
      want -= 1
      gap = 0
    } else if (++gap > MAX_GAP_LINES) {
      break
    }
  }
  if (want >= 1) return null
  // Вниз: пункты selected+1 … до первого пропуска.
  want = selected + 1
  gap = 0
  for (let i = markerIdx + 1; i < lines.length; i += 1) {
    const m = OPTION_RE.exec(lines[i] ?? '')
    if (m !== null && Number(m[1]) === want) {
      found.set(want, i)
      want += 1
      gap = 0
    } else if (++gap > MAX_GAP_LINES) {
      break
    }
  }
  const count = want - 1
  if (count < 2) return null

  const options: ChoiceOption[] = []
  for (let n = 1; n <= count; n += 1) {
    const idx = found.get(n) ?? -1
    const m = OPTION_RE.exec(lines[idx] ?? '')
    const next = found.get(n + 1) ?? lines.length
    // Продолжения пункта — непустые строки до следующего пункта (только между
    // пунктами: под последним обычно подсказка клавиш, это не текст пункта).
    const cont = n < count
      ? lines.slice(idx + 1, next).map((l) => l.trim()).filter((l) => l.length > 0)
      : []
    options.push({ n, label: [m?.[2] ?? '', ...cont].join(' ').trim() })
  }

  const firstIdx = found.get(1) ?? markerIdx
  const body = lines.slice(ruleIdx + 1, firstIdx).map((l) => l.trim()).filter((l) => l.length > 0)
  const fingerprint = JSON.stringify([body, options.map((o) => o.label)])
  return { body, options, selected, fingerprint }
}

// Пауза по фильтру: «<модель>'s safeguards flagged this session» + «Switch to <модель>».
const SAFEGUARD_BODY_RE = /safeguards flagged/i
const SWITCH_OPTION_RE = /^Switch to (.+)$/
const SAFEGUARD_CATEGORY_RE = /Details:\s*`?\[([A-Za-z_-]+)\]`?/

/**
 * Это пауза по фильтру безопасности? Если да — какой пункт переключает модель.
 *
 * @param dialog - Распознанное окно.
 * @returns Описание паузы или `null`.
 */
export function detectSafeguardPause(dialog: ChoiceDialog): SafeguardPause | null {
  const text = dialog.body.join(' ')
  if (!SAFEGUARD_BODY_RE.test(text)) return null
  for (const option of dialog.options) {
    const m = SWITCH_OPTION_RE.exec(option.label)
    if (m !== null) {
      return {
        switchOption: option,
        model: (m[1] ?? '').trim(),
        category: SAFEGUARD_CATEGORY_RE.exec(text)?.[1],
      }
    }
  }
  return null
}

// Плашка, которую Claude Code закрепляет, переключив модель сам.
const SWITCH_NOTICE_RE = /switched to (.+?) after a flagged message/

/**
 * Плашка «switched to <модель> after a flagged message» на экране.
 *
 * @param pane - Текст панели.
 * @returns Имя модели или `null`.
 */
export function detectSwitchNotice(pane: string): string | null {
  const m = SWITCH_NOTICE_RE.exec(pane)
  return m === null ? null : (m[1] ?? '').trim()
}

/** Доступ к tmux; подменяется в тестах. */
export interface ChoiceTmuxRunner {
  capturePane(session: string): Promise<string>
  /** Нажать одну клавишу (номер пункта). */
  pressKey(session: string, key: string): Promise<void>
}

/** tmux-реализация {@link ChoiceTmuxRunner}: только точная цель панели. */
export function createChoiceTmuxRunner(): ChoiceTmuxRunner {
  return {
    capturePane: async (session) => {
      const { stdout } = await execFileAsync('tmux', [
        'capture-pane', '-p', '-t', paneTarget(session), '-S', '-8',
      ])
      return stdout
    },
    pressKey: async (session, key) => {
      // -l: цифра уходит буквально; в окне Claude Code цифра сразу выбирает пункт.
      await execFileAsync('tmux', ['send-keys', '-t', paneTarget(session), '-l', key])
    },
  }
}

/** Нажатие кнопки, отвязанное от grammY. */
export interface ChoiceCallbackContext {
  readonly data: string
  readonly fromUserId: number
  answerCallbackQuery(arg?: { text?: string }): Promise<void>
}

/** Входящее текстовое сообщение. */
export interface ChoiceTextInput {
  readonly fromUserId: number | undefined
  readonly chatType: string | undefined
  readonly text: string
}

export interface ChoiceDialogRelayDeps {
  /** Голое имя tmux-сессии агента (`labops-<агент>`). */
  readonly session: string
  readonly telegramApi: Pick<TelegramApi, 'sendMessage' | 'editMessageText'>
  /** Кому слать окна и кто вправе выбирать (id в Telegram, личка). */
  readonly recipients: readonly number[]
  readonly log: Logger
  /** Пауза по фильтру: сразу выбирать «Switch to …». По умолчанию да. */
  readonly autoSwitchOnSafeguard?: boolean
  readonly runner?: ChoiceTmuxRunner
  readonly sleep?: (ms: number) => Promise<void>
  /** Сколько опросов подряд окно должно простоять, прежде чем его слать. */
  readonly stableTicks?: number
  /** Пауза после нажатия перед проверкой экрана, мс. */
  readonly settleMs?: number
}

export interface ChoiceDialogRelay {
  /** Один опрос панели. Не бросает. */
  tick(): Promise<void>
  /** Запустить опрос с интервалом; возвращает функцию остановки. */
  start(intervalMs: number): () => void
  /** Обработать нажатие кнопки. `true` — данные наши (даже если отказано). */
  handleCallback(ctx: ChoiceCallbackContext): Promise<boolean>
  /** Ответ цифрой на открытое окно. `true` — сообщение съедено, агенту не доставлять. */
  tryHandleText(input: ChoiceTextInput): Promise<boolean>
}

/** Префикс callback_data кнопок окна: `dlg:<id>:<номер>`. */
export const CHOICE_CALLBACK_PREFIX = 'dlg:'
const CALLBACK_RE = /^dlg:([a-z0-9]{6}):(\d{1,2})$/
const TEXT_CHOICE_RE = /^\s*(\d{1,2})\s*$/
const DIALOG_ID_BYTES = 3                // 3 байта → 6 hex-символов
const DEFAULT_STABLE_TICKS = 2
const DEFAULT_SETTLE_MS = 1500
// Цифрой выбираются только пункты 1–9: «1» в окне из 12 пунктов уже выбрало бы первый.
const MAX_KEY_OPTIONS = 9
const MAX_BODY_CHARS = 1500
const MAX_BUTTON_CHARS = 60

interface PendingMessage {
  readonly chatId: string
  readonly messageId: number
}

interface PendingDialog {
  readonly id: string
  readonly dialog: ChoiceDialog
  readonly messages: PendingMessage[]
  resolved: boolean
}

type ChooseResult = 'ok' | 'stuck' | 'stale' | 'invalid'

function isStartupDialog(dialog: ChoiceDialog): boolean {
  return STARTUP_DIALOG_RE.test([...dialog.body, ...dialog.options.map((o) => o.label)].join(' '))
}

function truncate(text: string, max: number): string {
  return text.length <= max ? text : `${text.slice(0, max - 1)}…`
}

function dialogText(dialog: ChoiceDialog, header: string, footer: string): string {
  const body = truncate(dialog.body.join('\n'), MAX_BODY_CHARS)
  const options = dialog.options.map((o) => `${o.n}. ${o.label}`).join('\n')
  return [header, '', body, '', options, '', footer].join('\n')
}

/**
 * Создаёт relay окон выбора для главной сессии агента.
 *
 * @param deps - Сессия, Telegram, получатели и подменяемые для тестов части.
 * @returns Relay; опрос запускается вызовом `start`.
 */
export function createChoiceDialogRelay(deps: ChoiceDialogRelayDeps): ChoiceDialogRelay {
  const runner = deps.runner ?? createChoiceTmuxRunner()
  const sleep = deps.sleep ?? ((ms: number) => new Promise<void>((r) => setTimeout(r, ms)))
  const stableTicks = deps.stableTicks ?? DEFAULT_STABLE_TICKS
  const settleMs = deps.settleMs ?? DEFAULT_SETTLE_MS
  const autoSwitch = deps.autoSwitchOnSafeguard ?? true
  const { log } = deps

  let seen: { fingerprint: string; count: number } | null = null
  let pending: PendingDialog | null = null
  const notifiedNotices = new Set<string>()
  let busy = false

  const capture = async (): Promise<string | null> => {
    try {
      return await runner.capturePane(deps.session)
    } catch (err) {
      log.debug('choice-dialog: capture failed', {
        session: deps.session,
        error: err instanceof Error ? err.message : String(err),
      })
      return null
    }
  }

  const sendAll = async (
    text: string,
    keyboard: InlineKeyboardLike | undefined,
  ): Promise<PendingMessage[]> => {
    const sent: PendingMessage[] = []
    for (const userId of deps.recipients) {
      const chatId = String(userId)
      try {
        const opts = keyboard === undefined ? {} : { reply_markup: keyboard }
        const res = await deps.telegramApi.sendMessage(chatId, text, opts)
        sent.push({ chatId, messageId: res.message_id })
      } catch (err) {
        log.warn('choice-dialog: send failed', {
          chat_id: chatId,
          error: err instanceof Error ? err.message : String(err),
        })
      }
    }
    return sent
  }

  // Убрать кнопки и дописать итог в каждое разосланное сообщение.
  const closeMessages = async (p: PendingDialog, outcome: string): Promise<void> => {
    const text = dialogText(p.dialog, 'Окно выбора на экране агента', outcome)
    for (const m of p.messages) {
      try {
        await deps.telegramApi.editMessageText(m.chatId, m.messageId, text, {
          reply_markup: { inline_keyboard: [] },
        })
      } catch (err) {
        log.debug('choice-dialog: edit failed', {
          chat_id: m.chatId,
          error: err instanceof Error ? err.message : String(err),
        })
      }
    }
  }

  // Нажать пункт n открытого окна. Перед нажатием окно перечитывается: если на
  // экране уже другое окно, цифра выбрала бы в нём не то, что выбрал человек.
  const press = async (dialog: ChoiceDialog, n: number): Promise<ChooseResult> => {
    if (n < 1 || n > Math.min(dialog.options.length, MAX_KEY_OPTIONS)) return 'invalid'
    const before = await capture()
    const current = before === null ? null : parseChoiceDialog(before)
    if (current === null || current.fingerprint !== dialog.fingerprint) return 'stale'
    try {
      await runner.pressKey(deps.session, String(n))
    } catch (err) {
      log.warn('choice-dialog: press failed', {
        error: err instanceof Error ? err.message : String(err),
      })
      return 'stuck'
    }
    await sleep(settleMs)
    const after = await capture()
    const still = after === null ? null : parseChoiceDialog(after)
    return still !== null && still.fingerprint === dialog.fingerprint ? 'stuck' : 'ok'
  }

  const choose = async (n: number, via: string): Promise<ChooseResult> => {
    const p = pending
    if (p === null || p.resolved) return 'stale'
    const result = await press(p.dialog, n)
    if (result === 'invalid') return result
    p.resolved = true
    const label = p.dialog.options.find((o) => o.n === n)?.label ?? ''
    const outcome = result === 'ok'
      ? `Выбрано: ${n}. ${label}`
      : result === 'stuck'
        ? `Нажал ${n}, но окно не закрылось — нужен человек в tmux.`
        : 'Окно уже закрыто или сменилось — ничего не нажимал.'
    await closeMessages(p, outcome)
    log.info('choice-dialog: choice made', { n, via, result })
    return result
  }

  const handleSafeguard = async (dialog: ChoiceDialog, pause: SafeguardPause): Promise<boolean> => {
    const result = await press(dialog, pause.switchOption.n)
    const category = pause.category === undefined ? '' : ` (${pause.category})`
    if (result === 'ok') {
      // Переключившись, Claude Code закрепит плашку «switched to <модель>…» — о ней
      // оператор уже знает из сообщения ниже, второе слать незачем.
      notifiedNotices.add(pause.model)
      log.info('choice-dialog: safeguard pause → switched model', { model: pause.model })
      await sendAll(
        `Фильтр безопасности остановил ответ${category}. Переключил сессию на ${pause.model} — ` +
          'ответ придёт от неё. Модель из настроек вернётся при следующем перезапуске сессии.',
        undefined,
      )
      return true
    }
    log.warn('choice-dialog: safeguard auto-switch failed, relaying', { result })
    return false
  }

  const relay = async (dialog: ChoiceDialog, header: string): Promise<void> => {
    const id = randomBytes(DIALOG_ID_BYTES).toString('hex')
    const keyable = dialog.options.length <= MAX_KEY_OPTIONS
    const keyboard: InlineKeyboardLike | undefined = keyable
      ? {
          inline_keyboard: dialog.options.map((o) => [
            {
              text: truncate(`${o.n}. ${o.label}`, MAX_BUTTON_CHARS),
              callback_data: `${CHOICE_CALLBACK_PREFIX}${id}:${o.n}`,
            },
          ]),
        }
      : undefined
    const footer = keyable
      ? 'Нажмите кнопку или ответьте номером пункта.'
      : 'Пунктов больше девяти — выбрать отсюда нельзя, нужен человек в tmux.'
    const messages = await sendAll(dialogText(dialog, header, footer), keyboard)
    pending = { id, dialog, messages, resolved: false }
    log.info('choice-dialog: relayed to operator', {
      id,
      options: dialog.options.length,
      recipients: messages.length,
    })
  }

  const tick = async (): Promise<void> => {
    const pane = await capture()
    if (pane === null) return

    const notice = detectSwitchNotice(pane)
    if (notice !== null && !notifiedNotices.has(notice)) {
      notifiedNotices.add(notice)
      await sendAll(
        `Фильтр безопасности остановил ответ — Claude Code сам переключился на ${notice}. ` +
          'Модель из настроек вернётся при следующем перезапуске сессии.',
        undefined,
      )
    }

    const parsed = parseChoiceDialog(pane)
    const dialog = parsed !== null && !isStartupDialog(parsed) ? parsed : null
    if (dialog === null) {
      seen = null
      const p = pending
      if (p !== null) {
        pending = null
        if (!p.resolved) await closeMessages(p, 'Окно закрыли в терминале.')
      }
      return
    }

    seen = seen !== null && seen.fingerprint === dialog.fingerprint
      ? { fingerprint: dialog.fingerprint, count: seen.count + 1 }
      : { fingerprint: dialog.fingerprint, count: 1 }
    if (pending !== null && pending.dialog.fingerprint === dialog.fingerprint) return
    if (seen.count < stableTicks) return
    // На экране другое окно, а прежнее так и не выбрано — закрыть его сообщение.
    const stalePending = pending
    if (stalePending !== null && !stalePending.resolved) {
      await closeMessages(stalePending, 'Окно сменилось другим.')
    }
    pending = null

    const pause = detectSafeguardPause(dialog)
    if (pause !== null && autoSwitch) {
      if (await handleSafeguard(dialog, pause)) {
        // Запоминаем окно как решённое: если экран ещё не перерисовался,
        // следующий опрос не должен выбрать пункт второй раз.
        pending = { id: '', dialog, messages: [], resolved: true }
        return
      }
      await relay(dialog, 'Фильтр безопасности остановил ответ, автоматически переключить не вышло')
      return
    }
    await relay(dialog, 'Агент ждёт выбора на экране')
  }

  // Опросы не накладываются: медленный tmux или Telegram не должны запускать
  // второй такт поверх первого (он нажал бы пункт повторно).
  const safeTick = async (): Promise<void> => {
    if (busy) return
    busy = true
    try {
      await tick()
    } catch (err) {
      log.warn('choice-dialog: tick failed', {
        error: err instanceof Error ? err.message : String(err),
      })
    } finally {
      busy = false
    }
  }

  return {
    tick: safeTick,

    start(intervalMs) {
      const timer = setInterval(() => {
        void safeTick()
      }, intervalMs)
      timer.unref?.()
      return () => clearInterval(timer)
    },

    async handleCallback(ctx) {
      if (!ctx.data.startsWith(CHOICE_CALLBACK_PREFIX)) return false
      const m = CALLBACK_RE.exec(ctx.data)
      if (m === null) {
        await ctx.answerCallbackQuery().catch(() => {})
        return true
      }
      if (!deps.recipients.includes(ctx.fromUserId)) {
        await ctx.answerCallbackQuery({ text: 'Not authorized.' }).catch(() => {})
        return true
      }
      if (pending === null || pending.resolved || pending.id !== m[1]) {
        await ctx.answerCallbackQuery({ text: 'Окно уже закрыто.' }).catch(() => {})
        return true
      }
      const result = await choose(Number(m[2]), 'button')
      const answer = result === 'ok'
        ? 'Выбрано.'
        : result === 'stuck' ? 'Окно не закрылось.' : 'Окно уже закрыто.'
      await ctx.answerCallbackQuery({ text: answer }).catch(() => {})
      return true
    },

    async tryHandleText(input) {
      if (input.chatType !== 'private' || input.fromUserId === undefined) return false
      if (!deps.recipients.includes(input.fromUserId)) return false
      if (pending === null || pending.resolved) return false
      const m = TEXT_CHOICE_RE.exec(input.text)
      if (m === null) return false
      const result = await choose(Number(m[1]), 'text')
      // Номер вне списка — не наш ответ, пусть уйдёт агенту как обычный текст.
      return result !== 'invalid'
    },
  }
}
