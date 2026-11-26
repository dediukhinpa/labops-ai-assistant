import { describe, expect, test } from 'bun:test'

import {
  createChoiceDialogRelay,
  detectSafeguardPause,
  detectSwitchNotice,
  parseChoiceDialog,
  type ChoiceDialogRelayDeps,
  type ChoiceTmuxRunner,
} from './choice-dialog.js'
import { paneInputStuck } from './ensure-submit.js'

const noopLog = {
  info: () => {},
  warn: () => {},
  error: () => {},
  debug: () => {},
} as unknown as ChoiceDialogRelayDeps['log']

const OPERATOR = 124546645

// Экран живой сессии developer 26.11.2026 (захват capture-pane, хвост).
const SAFEGUARD_PAUSE = [
  '← labops-channel: Lab: Method-based access control can be circumvented PRACTI…',
  '',
  "● Opus 5.5's safeguards stopped the response above · continuing once",
  '  with that noted',
  '',
  '✻ Waiting for API response · will retry in 0s · check your network',
  '',
  '────────────────────────────────────────────────────────────────────────────────',
  '  Session paused',
  '',
  "  Opus 5.5's safeguards flagged this session. You may be seeing this for the",
  '  first time: Opus 5.5 is more capable and has stronger safeguards as a',
  '  result, which can sometimes flag non-cybersecurity work.',
  '',
  '  Details: `[cyber]`',
  '',
  '  ❯ 1. Switch to Opus 4.8',
  '    2. Edit prompt and retry with Opus 5.5',
].join('\n')

const GENERIC_DIALOG = [
  '────────────────────────',
  '  Usage limit reached',
  '',
  '    1. Stop and wait for limit to reset',
  '  ❯ 2. Switch to extra usage',
  '    3. Upgrade your plan',
  '',
  '  Enter to confirm · Esc to cancel',
].join('\n')

const IDLE = '────────\n❯ \n────────\n  ⏵⏵ bypass permissions on'
// Оператор набрал нумерованный текст прямо в поле ввода — это не окно.
const TYPED_NUMBERED = [
  '────────',
  '❯ 1. сделай бэкап',
  '────────',
  '  ⏵⏵ bypass permissions on (shift+tab to cycle)',
].join('\n')
const DEV_CHANNELS = [
  '────────',
  '  Loading development channels',
  '  ❯ 1. I am using this for local development',
  '    2. Exit',
].join('\n')
const SWITCHED = [
  '────────',
  '❯ ',
  '────────',
  '  ⚠ switched to Opus 4.8 after a flagged message · /model',
  '  ⏵⏵ bypass permissions on (shift+tab to cycle)',
].join('\n')

describe('parseChoiceDialog', () => {
  test('распознаёт паузу по фильтру безопасности', () => {
    const d = parseChoiceDialog(SAFEGUARD_PAUSE)
    expect(d).not.toBeNull()
    expect(d?.options.map((o) => o.label)).toEqual([
      'Switch to Opus 4.8',
      'Edit prompt and retry with Opus 5.5',
    ])
    expect(d?.selected).toBe(1)
    expect(d?.body[0]).toBe('Session paused')
    expect(d?.body).toContain('Details: `[cyber]`')
  })

  test('выбранный пункт в середине списка', () => {
    const d = parseChoiceDialog(GENERIC_DIALOG)
    expect(d?.options.length).toBe(3)
    expect(d?.selected).toBe(2)
    expect(d?.body).toEqual(['Usage limit reached'])
  })

  test('поле ввода — не окно, даже с набранным «1. …»', () => {
    expect(parseChoiceDialog(IDLE)).toBeNull()
    expect(parseChoiceDialog(TYPED_NUMBERED)).toBeNull()
    expect(parseChoiceDialog('')).toBeNull()
  })

  test('один пункт — не окно выбора', () => {
    expect(parseChoiceDialog('────\n  ❯ 1. Единственный')).toBeNull()
  })

  test('нумерованный список в переписке выше линии в пункты не попадает', () => {
    const pane = '  1. Log in\n  2. Browse\n' + SAFEGUARD_PAUSE
    expect(parseChoiceDialog(pane)?.options.length).toBe(2)
  })

  test('отпечаток стабилен между захватами одного окна', () => {
    const a = parseChoiceDialog(SAFEGUARD_PAUSE)
    const b = parseChoiceDialog('лишняя строка истории\n' + SAFEGUARD_PAUSE)
    expect(a?.fingerprint).toBe(b?.fingerprint ?? '')
  })
})

describe('detectSafeguardPause / detectSwitchNotice', () => {
  test('пауза: пункт переключения, модель и категория', () => {
    const d = parseChoiceDialog(SAFEGUARD_PAUSE)
    const p = d === null ? null : detectSafeguardPause(d)
    expect(p?.switchOption.n).toBe(1)
    expect(p?.model).toBe('Opus 4.8')
    expect(p?.category).toBe('cyber')
  })

  test('обычное окно с «Switch to» в пункте — не пауза по фильтру', () => {
    const d = parseChoiceDialog(GENERIC_DIALOG)
    expect(d === null ? null : detectSafeguardPause(d)).toBeNull()
  })

  test('плашка автопереключения Claude Code', () => {
    expect(detectSwitchNotice(SWITCHED)).toBe('Opus 4.8')
    expect(detectSwitchNotice(IDLE)).toBeNull()
  })
})

describe('ensure-submit не печатает в окно выбора', () => {
  test('окно на экране — ввод не считается застрявшим', () => {
    expect(paneInputStuck(SAFEGUARD_PAUSE)).toBe(false)
    expect(paneInputStuck(GENERIC_DIALOG)).toBe(false)
  })

  test('набранный в поле текст по-прежнему застрявший', () => {
    expect(paneInputStuck(TYPED_NUMBERED)).toBe(true)
  })
})

interface Sent {
  chatId: string
  text: string
  buttons: string[]
}

// Фальшивый экран: pressKey меняет экран на заданный «после нажатия».
function harness(
  screens: { initial: string; afterPress?: string },
  extra: Partial<ChoiceDialogRelayDeps> = {},
) {
  let screen = screens.initial
  const pressed: string[] = []
  const sent: Sent[] = []
  const edits: string[] = []
  const runner: ChoiceTmuxRunner = {
    capturePane: async () => screen,
    pressKey: async (_s, key) => {
      pressed.push(key)
      if (screens.afterPress !== undefined) screen = screens.afterPress
    },
  }
  let nextId = 1
  const relay = createChoiceDialogRelay({
    session: 'labops-developer',
    recipients: [OPERATOR],
    log: noopLog,
    runner,
    sleep: async () => {},
    telegramApi: {
      sendMessage: async (chatId, text, opts) => {
        const buttons = (opts.reply_markup?.inline_keyboard ?? [])
          .flat()
          .map((b) => b.callback_data ?? '')
        sent.push({ chatId, text, buttons })
        return { message_id: nextId++ }
      },
      editMessageText: async (_c, _m, text) => {
        edits.push(text)
      },
    },
    ...extra,
  })
  return {
    relay,
    pressed,
    sent,
    edits,
    setScreen: (s: string) => {
      screen = s
    },
  }
}

function callback(data: string, fromUserId = OPERATOR) {
  const answers: string[] = []
  return {
    answers,
    ctx: {
      data,
      fromUserId,
      answerCallbackQuery: async (arg?: { text?: string }) => {
        answers.push(arg?.text ?? '')
      },
    },
  }
}

describe('relay: пауза по фильтру безопасности', () => {
  test('после двух опросов сам жмёт «Switch to» и сообщает оператору', async () => {
    const h = harness({ initial: SAFEGUARD_PAUSE, afterPress: SWITCHED })
    await h.relay.tick()
    expect(h.pressed).toEqual([])               // один опрос — ещё не устойчиво
    await h.relay.tick()
    expect(h.pressed).toEqual(['1'])
    expect(h.sent.length).toBe(1)
    expect(h.sent[0]?.chatId).toBe(String(OPERATOR))
    expect(h.sent[0]?.text).toContain('Opus 4.8')
    expect(h.sent[0]?.text).toContain('cyber')
    expect(h.sent[0]?.buttons).toEqual([])
  })

  test('плашку переключения после своего нажатия не дублирует сообщением', async () => {
    const h = harness({ initial: SAFEGUARD_PAUSE, afterPress: SWITCHED })
    await h.relay.tick()
    await h.relay.tick()
    await h.relay.tick()                         // экран уже SWITCHED
    await h.relay.tick()
    expect(h.sent.length).toBe(1)                // только сообщение о своём нажатии
  })

  test('переключение самим Claude Code сообщается один раз', async () => {
    const h = harness({ initial: SWITCHED })
    await h.relay.tick()
    await h.relay.tick()
    expect(h.sent.length).toBe(1)
    expect(h.sent[0]?.text).toContain('сам переключился на Opus 4.8')
    expect(h.pressed).toEqual([])
  })

  test('экран не перерисовался — второй раз не жмёт', async () => {
    const h = harness({ initial: SAFEGUARD_PAUSE })   // нажатие экран не меняет
    await h.relay.tick()
    await h.relay.tick()
    await h.relay.tick()
    await h.relay.tick()
    // Первое нажатие не помогло → окно уходит оператору кнопками, без повторных нажатий.
    expect(h.pressed).toEqual(['1'])
    expect(h.sent.some((s) => s.buttons.length === 2)).toBe(true)
  })

  test('автопереключение выключено — окно уходит кнопками', async () => {
    const h = harness({ initial: SAFEGUARD_PAUSE }, { autoSwitchOnSafeguard: false })
    await h.relay.tick()
    await h.relay.tick()
    expect(h.pressed).toEqual([])
    expect(h.sent[0]?.buttons.length).toBe(2)
  })
})

describe('relay: обычное окно выбора', () => {
  test('отправляет окно с кнопками, нажатие кнопки выбирает пункт', async () => {
    const h = harness({ initial: GENERIC_DIALOG, afterPress: IDLE })
    await h.relay.tick()
    await h.relay.tick()
    expect(h.sent.length).toBe(1)
    const buttons = h.sent[0]?.buttons ?? []
    expect(buttons.length).toBe(3)
    expect(h.sent[0]?.text).toContain('Usage limit reached')

    const cb = callback(buttons[2] ?? '')
    expect(await h.relay.handleCallback(cb.ctx)).toBe(true)
    expect(h.pressed).toEqual(['3'])
    expect(cb.answers).toEqual(['Выбрано.'])
    expect(h.edits.at(-1)).toContain('Выбрано: 3. Upgrade your plan')

    // Повторное нажатие той же кнопки ничего не жмёт.
    const again = callback(buttons[2] ?? '')
    await h.relay.handleCallback(again.ctx)
    expect(h.pressed).toEqual(['3'])
    expect(again.answers).toEqual(['Окно уже закрыто.'])
  })

  test('одно окно отправляется один раз', async () => {
    const h = harness({ initial: GENERIC_DIALOG })
    for (let i = 0; i < 5; i += 1) await h.relay.tick()
    expect(h.sent.length).toBe(1)
  })

  test('чужой не может выбрать', async () => {
    const h = harness({ initial: GENERIC_DIALOG })
    await h.relay.tick()
    await h.relay.tick()
    const cb = callback(h.sent[0]?.buttons[0] ?? '', 555)
    expect(await h.relay.handleCallback(cb.ctx)).toBe(true)
    expect(h.pressed).toEqual([])
    expect(cb.answers).toEqual(['Not authorized.'])
  })

  test('окно сменилось до нажатия — цифра не уходит', async () => {
    const h = harness({ initial: GENERIC_DIALOG })
    await h.relay.tick()
    await h.relay.tick()
    h.setScreen(SAFEGUARD_PAUSE)
    const cb = callback(h.sent[0]?.buttons[0] ?? '')
    await h.relay.handleCallback(cb.ctx)
    expect(h.pressed).toEqual([])
    expect(cb.answers).toEqual(['Окно уже закрыто.'])
  })

  test('ответ цифрой в личке выбирает пункт и агенту не доставляется', async () => {
    const h = harness({ initial: GENERIC_DIALOG, afterPress: IDLE })
    await h.relay.tick()
    await h.relay.tick()
    expect(await h.relay.tryHandleText({ fromUserId: OPERATOR, chatType: 'private', text: ' 1 ' }))
      .toBe(true)
    expect(h.pressed).toEqual(['1'])
  })

  test('текст, не являющийся номером пункта, уходит агенту', async () => {
    const h = harness({ initial: GENERIC_DIALOG })
    await h.relay.tick()
    await h.relay.tick()
    const input = { fromUserId: OPERATOR, chatType: 'private' }
    expect(await h.relay.tryHandleText({ ...input, text: 'что там?' })).toBe(false)
    expect(await h.relay.tryHandleText({ ...input, text: '7' })).toBe(false)
    expect(await h.relay.tryHandleText({ ...input, chatType: 'group', text: '1' })).toBe(false)
    expect(h.pressed).toEqual([])
  })

  test('окно закрыли в терминале — кнопки снимаются', async () => {
    const h = harness({ initial: GENERIC_DIALOG })
    await h.relay.tick()
    await h.relay.tick()
    h.setScreen(IDLE)
    await h.relay.tick()
    expect(h.edits.at(-1)).toContain('Окно закрыли в терминале.')
    expect(await h.relay.tryHandleText({ fromUserId: OPERATOR, chatType: 'private', text: '1' }))
      .toBe(false)
  })

  test('окна старта сессии не трогает', async () => {
    const h = harness({ initial: DEV_CHANNELS })
    await h.relay.tick()
    await h.relay.tick()
    await h.relay.tick()
    expect(h.sent).toEqual([])
    expect(h.pressed).toEqual([])
  })

  test('ошибка tmux — пропуск такта, без исключения', async () => {
    const relay = createChoiceDialogRelay({
      session: 'labops-developer',
      recipients: [OPERATOR],
      log: noopLog,
      runner: {
        capturePane: async () => {
          throw new Error('no server')
        },
        pressKey: async () => {},
      },
      telegramApi: {
        sendMessage: async () => ({ message_id: 1 }),
        editMessageText: async () => {},
      },
    })
    await relay.tick()
  })
})
