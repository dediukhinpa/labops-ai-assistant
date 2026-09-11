// Скачанные вложения — документы клиента: права только владельцу.

import { afterEach, expect, test } from 'bun:test'
import { mkdtempSync, rmSync, statSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'
import type { Bot } from 'grammy'

import {
  ATTACHMENT_DIR_MODE,
  ATTACHMENT_FILE_MODE,
  createTelegramApi,
} from '../../src/channel/tools.js'

const PERMISSION_BITS = 0o777
const originalFetch = globalThis.fetch
const roots: string[] = []

afterEach(() => {
  globalThis.fetch = originalFetch
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true })
})

test('вложение сохраняется с правами 600 в каталог с правами 700', async () => {
  const root = mkdtempSync(join(tmpdir(), 'tg-download-'))
  roots.push(root)
  const inbox = join(root, 'inbox')
  const bot = {
    api: {
      getFile: async () => ({ file_path: 'documents/report.pdf', file_unique_id: 'abc' }),
    },
  } as unknown as Bot
  globalThis.fetch = (async () =>
    new Response(new Uint8Array([1, 2, 3]))) as unknown as typeof fetch

  const result = await createTelegramApi(bot, 'test-token').downloadFile('file-id', inbox)

  expect(result.size).toBe(3)
  expect(statSync(result.path).mode & PERMISSION_BITS).toBe(ATTACHMENT_FILE_MODE)
  expect(statSync(inbox).mode & PERMISSION_BITS).toBe(ATTACHMENT_DIR_MODE)
})
