import { describe, expect, test } from 'bun:test'

import type { Logger } from '../../src/log.js'
import {
  isCommandMenuEnabled,
  syncCommandMenu,
  type BotCommandEntry,
  type CommandMenuApi,
} from '../../src/telegram/command-menu.js'

const COMMANDS: readonly BotCommandEntry[] = [{ command: 'help', description: 'справка' }]

const silentLog: Logger = { debug: () => {}, info: () => {}, warn: () => {}, error: () => {} }

function apiSpy(fail = false): { api: CommandMenuApi; calls: string[] } {
  const calls: string[] = []
  const api: CommandMenuApi = {
    setMyCommands: async () => {
      calls.push('set')
      if (fail) throw new Error('network')
    },
    deleteMyCommands: async () => {
      calls.push('delete')
      if (fail) throw new Error('network')
    },
  }
  return { api, calls }
}

describe('isCommandMenuEnabled', () => {
  test('по умолчанию меню включено', () => {
    expect(isCommandMenuEnabled({})).toBe(true)
    expect(isCommandMenuEnabled({ TELEGRAM_COMMAND_MENU: '' })).toBe(true)
    expect(isCommandMenuEnabled({ TELEGRAM_COMMAND_MENU: 'on' })).toBe(true)
  })

  test('явное off/false/0/no выключает меню', () => {
    for (const value of ['off', 'OFF', 'false', '0', 'no', ' off ']) {
      expect(isCommandMenuEnabled({ TELEGRAM_COMMAND_MENU: value })).toBe(false)
    }
  })
})

describe('syncCommandMenu', () => {
  test('меню включено — регистрирует команды', async () => {
    const { api, calls } = apiSpy()
    await syncCommandMenu(api, COMMANDS, {}, silentLog)
    expect(calls).toEqual(['set'])
  })

  test('меню выключено — очищает его, а не регистрирует', async () => {
    const { api, calls } = apiSpy()
    await syncCommandMenu(api, COMMANDS, { TELEGRAM_COMMAND_MENU: 'off' }, silentLog)
    expect(calls).toEqual(['delete'])
  })

  test('сбой Bot API не бросает', async () => {
    const { api } = apiSpy(true)
    await syncCommandMenu(api, COMMANDS, {}, silentLog)
    await syncCommandMenu(api, COMMANDS, { TELEGRAM_COMMAND_MENU: 'off' }, silentLog)
  })
})
