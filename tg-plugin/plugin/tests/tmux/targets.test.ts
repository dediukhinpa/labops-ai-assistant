// Форма точных целей tmux — одна на весь монорепо (см. src/tmux/targets.ts).

import { describe, expect, test } from 'bun:test'

import { assertSessionName, paneTarget, sessionTarget } from '../../src/tmux/index.js'

describe('sessionTarget', () => {
  test('prefixes the bare name with = so tmux never prefix-matches', () => {
    expect(sessionTarget('labops-carmella')).toBe('=labops-carmella')
  })

  test('keeps group chat ids with a leading minus intact', () => {
    expect(sessionTarget('multichat--1001234567')).toBe('=multichat--1001234567')
  })
})

describe('paneTarget', () => {
  test('targets the first window top-left pane, not the current window', () => {
    expect(paneTarget('labops-carmella')).toBe('=labops-carmella:^.{top-left}')
  })
})

describe('assertSessionName', () => {
  // Каждое из этих имён либо пустое, либо превратилось бы в другую цель.
  const invalid: readonly string[] = ['', 'a:b', 'a.b', 'a b', 'a\tb', 'a\nb']

  for (const name of invalid) {
    test(`rejects ${JSON.stringify(name)}`, () => {
      expect(() => assertSessionName(name)).toThrow(TypeError)
      expect(() => sessionTarget(name)).toThrow(TypeError)
      expect(() => paneTarget(name)).toThrow(TypeError)
    })
  }

  test('accepts the names the plugin actually builds', () => {
    expect(() => assertSessionName('labops-labops-app-124546645')).not.toThrow()
    expect(() => assertSessionName('multichat-12345')).not.toThrow()
  })
})
