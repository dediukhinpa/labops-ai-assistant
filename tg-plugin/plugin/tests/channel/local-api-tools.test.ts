// Лимиты и скачивание в режиме локального Bot API; режим по умолчанию не меняется.

import { afterEach, describe, expect, test } from 'bun:test'
import { mkdtempSync, rmSync, statSync, truncateSync, writeFileSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'
import type { Bot } from 'grammy'

import { createTelegramApi, listTools } from '../../src/channel/tools.js'
import type { AppConfig } from '../../src/config.js'
import { loadConfig } from '../../src/config.js'
import {
  LOCAL_ATTACHMENT_MAX_BYTES,
  MAX_ATTACHMENT_BYTES,
  assertSendableFile,
} from '../../src/security/paths.js'
import type { LocalApiConfig } from '../../src/telegram/local-api.js'
import { downloadPhotoToInbox } from '../../src/telegram/media.js'

const TOKEN = '123456789:AAH-fake_test_token_with_at_least_thirty_chars'
const ROOT = 'http://127.0.0.1:8081'
const MIB = 1024 * 1024
const FILE_MODE = 0o600
const PERMISSION_BITS = 0o777

const dirs: string[] = []
function tmp(prefix: string): string {
  const d = mkdtempSync(join(tmpdir(), prefix))
  dirs.push(d)
  return d
}
const originalFetch = globalThis.fetch
afterEach(() => {
  globalThis.fetch = originalFetch
  for (const d of dirs.splice(0)) rmSync(d, { recursive: true, force: true })
})

function configFor(workspace: string, localApi?: LocalApiConfig): AppConfig {
  const base = loadConfig({
    TELEGRAM_BOT_TOKEN: TOKEN,
    TELEGRAM_STATE_DIR: tmp('tg-state-'),
    TELEGRAM_WORKSPACE_ROOT: workspace,
    ...(localApi !== undefined ? { TELEGRAM_API_ROOT: localApi.api_root } : {}),
  })
  return base
}

describe('listTools: описания лимитов', () => {
  const filesNote = (tools: ReturnType<typeof listTools>): string =>
    (tools.find(t => t.name === 'reply')?.inputSchema.properties.files as { description: string }).description
  const downloadNote = (tools: ReturnType<typeof listTools>): string =>
    tools.find(t => t.name === 'download_attachment')?.description ?? ''

  test('по умолчанию тексты прежние: 50MB и 20MB', () => {
    const tools = listTools()
    expect(filesNote(tools)).toContain('Max 50MB each.')
    expect(downloadNote(tools)).toContain('Telegram caps bot downloads at 20MB.')
  })

  test('с локальным API тексты соответствуют режиму', () => {
    const tools = listTools({ api_root: ROOT })
    expect(filesNote(tools)).toContain('Max 2000MB each')
    expect(filesNote(tools)).not.toContain('50MB')
    expect(downloadNote(tools)).toContain('no 20MB download cap')
    expect(downloadNote(tools)).not.toContain('caps bot downloads at 20MB')
  })

  test('порядок инструментов не меняется, исходный список не мутирует', () => {
    const local = listTools({ api_root: ROOT }).map(t => t.name)
    expect(local).toEqual(['reply', 'react', 'download_attachment', 'edit_message', 'status'])
    expect(filesNote(listTools())).toContain('Max 50MB each.')
  })
})

describe('assertSendableFile: потолок отправки', () => {
  function sparse(dir: string, bytes: number): string {
    const f = join(dir, 'big.bin')
    writeFileSync(f, '')
    truncateSync(f, bytes)
    return f
  }

  test('облако: 50 МБ -- потолок', () => {
    const ws = tmp('tg-ws-')
    sparse(ws, MAX_ATTACHMENT_BYTES + 1)
    expect(() => assertSendableFile({ filePath: 'big.bin', config: configFor(ws) })).toThrow(/max 50MB/)
  })

  test('локальный API: файл больше 50 МБ проходит, больше 2000 МБ -- нет', () => {
    const ws = tmp('tg-ws-')
    const config = configFor(ws, { api_root: ROOT })
    sparse(ws, 60 * MIB)
    expect(assertSendableFile({ filePath: 'big.bin', config }).endsWith('big.bin')).toBe(true)
    truncateSync(join(ws, 'big.bin'), LOCAL_ATTACHMENT_MAX_BYTES + 1)
    expect(() => assertSendableFile({ filePath: 'big.bin', config })).toThrow(/max 2000MB/)
  })
})

describe('createTelegramApi.downloadFile', () => {
  function botReturning(file_path: string): Bot {
    return {
      api: { getFile: async () => ({ file_path, file_unique_id: 'uq' }) },
    } as unknown as Bot
  }

  test('локальный API: абсолютный путь внутри каталога данных читается с диска', async () => {
    const data = tmp('tg-data-')
    const src = join(data, 'videos', 'v.mp4')
    const { mkdirSync } = await import('fs')
    mkdirSync(join(data, 'videos'))
    writeFileSync(src, 'video-bytes')
    globalThis.fetch = (async () => {
      throw new Error('сеть не должна использоваться')
    }) as unknown as typeof fetch
    const inbox = join(tmp('tg-state-'), 'inbox')

    const api = createTelegramApi(botReturning(src), TOKEN, { api_root: ROOT, local_dir: data })
    const out = await api.downloadFile('fid', inbox)
    expect(out.size).toBe('video-bytes'.length)
    expect(statSync(out.path).mode & PERMISSION_BITS).toBe(FILE_MODE)
  })

  test('локальный API: путь вне каталога данных -- отказ', async () => {
    const data = tmp('tg-data-')
    const outside = tmp('tg-outside-')
    writeFileSync(join(outside, 'x.bin'), 'x')
    const api = createTelegramApi(botReturning(join(outside, 'x.bin')), TOKEN, {
      api_root: ROOT,
      local_dir: data,
    })
    await expect(api.downloadFile('fid', join(tmp('tg-state-'), 'inbox'))).rejects.toThrow(/outside/)
  })

  test('по умолчанию: качает с https://api.telegram.org/file/bot<token>/<path>', async () => {
    let requested = ''
    globalThis.fetch = (async (url: string) => {
      requested = url
      return new Response(new Uint8Array([9, 9]))
    }) as unknown as typeof fetch
    const api = createTelegramApi(botReturning('documents/a.pdf'), TOKEN)
    const out = await api.downloadFile('fid', join(tmp('tg-state-'), 'inbox'))
    expect(requested).toBe(`https://api.telegram.org/file/bot${TOKEN}/documents/a.pdf`)
    expect(out.size).toBe(2)
  })
})

describe('downloadPhotoToInbox', () => {
  const bot = (file_size: number): { api: { getFile: () => Promise<Record<string, unknown>> } } => ({
    api: {
      getFile: async () => ({ file_path: 'photos/p.jpg', file_unique_id: 'u', file_size }),
    },
  })
  const BIG = 25 * MIB

  test('по умолчанию файл больше 20 МБ пропускается', async () => {
    let fetched = false
    const res = await downloadPhotoToInbox(bot(BIG), TOKEN, 'f', tmp('tg-inbox-'), {
      fetchImpl: (async () => {
        fetched = true
        return new Response(new Uint8Array([1]))
      }) as unknown as typeof fetch,
    })
    expect(res).toBeUndefined()
    expect(fetched).toBe(false)
  })

  test('с локальным API потолка 20 МБ нет, адрес -- локальный сервер', async () => {
    let requested = ''
    const inbox = tmp('tg-inbox-')
    const res = await downloadPhotoToInbox(bot(BIG), TOKEN, 'f', inbox, {
      localApi: { api_root: ROOT },
      fetchImpl: (async (url: string) => {
        requested = url
        return new Response(new Uint8Array([1, 2]))
      }) as unknown as typeof fetch,
    })
    expect(requested).toBe(`${ROOT}/file/bot${TOKEN}/photos/p.jpg`)
    expect(res?.startsWith(inbox)).toBe(true)
  })

  test('по умолчанию адрес -- облако', async () => {
    let requested = ''
    await downloadPhotoToInbox(bot(10), TOKEN, 'f', tmp('tg-inbox-'), {
      fetchImpl: (async (url: string) => {
        requested = url
        return new Response(new Uint8Array([1]))
      }) as unknown as typeof fetch,
    })
    expect(requested).toBe(`https://api.telegram.org/file/bot${TOKEN}/photos/p.jpg`)
  })
})
