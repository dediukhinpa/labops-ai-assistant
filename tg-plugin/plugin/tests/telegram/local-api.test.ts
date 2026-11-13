// Локальный Bot API: валидация корня, чтение файлов с диска, таймауты fetch.

import { afterEach, describe, expect, test } from 'bun:test'
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'
import { Bot } from 'grammy'

import {
  assertAbsoluteLocalDir,
  buildFileUrl,
  downloadViaLocalApi,
  normalizeApiRoot,
  resolveLocalApiFile,
  type LocalApiConfig,
} from '../../src/telegram/local-api.js'
import {
  LOCAL_HEAVY_TIMEOUT_MS,
  TG_DEFAULT_TIMEOUT_MS,
  TG_TIMEOUTS_MS,
  createTimedTelegramFetch,
  resolveTelegramTimeoutMs,
} from '../../src/telegram/timed-fetch.js'

const TOKEN = '123456789:AAH-fake_test_token_with_at_least_thirty_chars'
const ROOT = 'http://127.0.0.1:8081'
const PERMISSION_BITS = 0o777
const FILE_MODE = 0o600

const tmpDirs: string[] = []
function tmp(prefix: string): string {
  const d = mkdtempSync(join(tmpdir(), prefix))
  tmpDirs.push(d)
  return d
}
afterEach(() => {
  for (const d of tmpDirs.splice(0)) rmSync(d, { recursive: true, force: true })
})

describe('normalizeApiRoot', () => {
  test('принимает loopback по http и убирает хвостовой слэш', () => {
    expect(normalizeApiRoot('http://127.0.0.1:8081')).toBe('http://127.0.0.1:8081')
    expect(normalizeApiRoot('http://127.0.0.1:8081/')).toBe('http://127.0.0.1:8081')
    expect(normalizeApiRoot('http://localhost:8081')).toBe('http://localhost:8081')
    expect(normalizeApiRoot('http://127.5.6.7:8081')).toBe('http://127.5.6.7:8081')
    expect(normalizeApiRoot('http://[::1]:8081')).toBe('http://[::1]:8081')
  })

  test('https допустим для любого хоста', () => {
    expect(normalizeApiRoot('https://botapi.internal.example:8443')).toBe(
      'https://botapi.internal.example:8443',
    )
  })

  test('голый http на не-loopback отвергается (токен пошёл бы открытым текстом)', () => {
    expect(() => normalizeApiRoot('http://10.0.0.5:8081')).toThrow(/loopback/)
    expect(() => normalizeApiRoot('http://example.com')).toThrow(/loopback/)
    expect(() => normalizeApiRoot('http://127.0.0.1.evil.example')).toThrow(/loopback/)
  })

  test('облачный хост, не-http схема, мусор, путь, логин и query отвергаются', () => {
    expect(() => normalizeApiRoot('https://api.telegram.org')).toThrow(/not api.telegram.org/)
    expect(() => normalizeApiRoot('ftp://127.0.0.1')).toThrow(/http/)
    expect(() => normalizeApiRoot('127.0.0.1:8081')).toThrow()
    expect(() => normalizeApiRoot('not a url')).toThrow()
    expect(() => normalizeApiRoot('http://127.0.0.1:8081/bot')).toThrow(/bare origin/)
    expect(() => normalizeApiRoot('http://127.0.0.1:8081/?x=1')).toThrow(/bare origin/)
    expect(() => normalizeApiRoot('http://user:pw@127.0.0.1:8081')).toThrow(/credentials/)
  })

  test('текст ошибки не содержит исходное значение', () => {
    try {
      normalizeApiRoot(`http://user:${TOKEN}@10.0.0.5`)
      throw new Error('должно было упасть')
    } catch (err) {
      expect(String(err)).not.toContain(TOKEN)
    }
  })
})

describe('assertAbsoluteLocalDir', () => {
  test('только абсолютный путь', () => {
    expect(assertAbsoluteLocalDir(' /var/lib/telegram-bot-api ')).toBe('/var/lib/telegram-bot-api')
    expect(() => assertAbsoluteLocalDir('relative/dir')).toThrow(/absolute/)
  })
})

describe('buildFileUrl', () => {
  test('облако без localApi, иначе корень локального сервера', () => {
    expect(buildFileUrl('T', 'documents/a.pdf')).toBe('https://api.telegram.org/file/botT/documents/a.pdf')
    expect(buildFileUrl('T', 'documents/a.pdf', { api_root: ROOT })).toBe(
      `${ROOT}/file/botT/documents/a.pdf`,
    )
  })
})

describe('resolveLocalApiFile', () => {
  test('файл внутри каталога данных разрешается', () => {
    const dir = tmp('tg-local-dir-')
    const f = join(dir, 'videos', 'file_1.mp4')
    mkdirSync(join(dir, 'videos'))
    writeFileSync(f, 'x')
    expect(resolveLocalApiFile(f, dir).endsWith('/videos/file_1.mp4')).toBe(true)
  })

  test('без TELEGRAM_API_LOCAL_DIR абсолютный путь не читается', () => {
    expect(() => resolveLocalApiFile('/etc/passwd', undefined)).toThrow(/TELEGRAM_API_LOCAL_DIR/)
  })

  test('путь вне каталога и выход через .. отвергаются', () => {
    const dir = tmp('tg-local-dir-')
    const outside = tmp('tg-outside-')
    writeFileSync(join(outside, 'secret.txt'), 's')
    expect(() => resolveLocalApiFile(join(outside, 'secret.txt'), dir)).toThrow(/outside/)
    expect(() => resolveLocalApiFile(`${dir}/../${outside.split('/').pop()}/secret.txt`, dir)).toThrow(
      /outside/,
    )
  })

  test('каталог-сосед с общим префиксом имени не проходит', () => {
    const base = tmp('tg-base-')
    const dir = join(base, 'data')
    const evil = join(base, 'data-evil')
    mkdirSync(dir)
    mkdirSync(evil)
    writeFileSync(join(evil, 'f'), 'x')
    expect(() => resolveLocalApiFile(join(evil, 'f'), dir)).toThrow(/outside/)
  })

  test('симлинк наружу отвергается', () => {
    const dir = tmp('tg-local-dir-')
    const outside = tmp('tg-outside-')
    writeFileSync(join(outside, 'secret.txt'), 's')
    symlinkSync(join(outside, 'secret.txt'), join(dir, 'link.txt'))
    expect(() => resolveLocalApiFile(join(dir, 'link.txt'), dir)).toThrow(/outside/)
  })

  test('каталог и несуществующий файл отвергаются', () => {
    const dir = tmp('tg-local-dir-')
    mkdirSync(join(dir, 'sub'))
    expect(() => resolveLocalApiFile(join(dir, 'sub'), dir)).toThrow(/regular file/)
    expect(() => resolveLocalApiFile(join(dir, 'nope'), dir)).toThrow(/does not exist/)
  })
})

describe('downloadViaLocalApi', () => {
  test('абсолютный путь копируется с диска с правами 600, лимита 20 МБ нет', async () => {
    const dataDir = tmp('tg-data-')
    const inbox = join(tmp('tg-state-'), 'inbox')
    const src = join(dataDir, 'video_1.mp4')
    writeFileSync(src, 'hello')
    const BIG_BYTES = 30 * 1024 * 1024
    writeFileSync(join(dataDir, 'big.mp4'), '')
    const big = join(dataDir, 'big.mp4')
    // sparse-файл крупнее облачного потолка скачивания (20 МБ)
    const { truncateSync } = await import('fs')
    truncateSync(big, BIG_BYTES)

    const api: LocalApiConfig = { api_root: ROOT, local_dir: dataDir }
    const small = await downloadViaLocalApi({ file_path: src, file_unique_id: 'uq1' }, TOKEN, inbox, api)
    expect(readFileSync(small.path, 'utf8')).toBe('hello')
    expect(small.size).toBe(5)
    expect(small.path.endsWith('-uq1.mp4')).toBe(true)
    expect(statSync(small.path).mode & PERMISSION_BITS).toBe(FILE_MODE)

    const large = await downloadViaLocalApi({ file_path: big, file_unique_id: 'uq2' }, TOKEN, inbox, api)
    expect(large.size).toBe(BIG_BYTES)
  })

  test('абсолютный путь вне каталога данных -- отказ без копирования', async () => {
    const dataDir = tmp('tg-data-')
    const outside = tmp('tg-outside-')
    writeFileSync(join(outside, 'x.bin'), 'x')
    const inbox = join(tmp('tg-state-'), 'inbox')
    await expect(
      downloadViaLocalApi({ file_path: join(outside, 'x.bin') }, TOKEN, inbox, {
        api_root: ROOT,
        local_dir: dataDir,
      }),
    ).rejects.toThrow(/outside/)
  })

  test('абсолютный путь без TELEGRAM_API_LOCAL_DIR -- отказ', async () => {
    const inbox = join(tmp('tg-state-'), 'inbox')
    await expect(
      downloadViaLocalApi({ file_path: '/var/lib/x/file.mp4' }, TOKEN, inbox, { api_root: ROOT }),
    ).rejects.toThrow(/TELEGRAM_API_LOCAL_DIR/)
  })

  test('относительный путь качается по ${apiRoot}/file/bot<token>/<path> потоком', async () => {
    const inbox = join(tmp('tg-state-'), 'inbox')
    let requested = ''
    const fetchImpl = (async (url: string) => {
      requested = url
      return new Response(new Uint8Array([1, 2, 3, 4]))
    }) as unknown as typeof fetch
    const out = await downloadViaLocalApi(
      { file_path: 'documents/report.pdf', file_unique_id: 'abc' },
      TOKEN,
      inbox,
      { api_root: ROOT },
      { fetchImpl },
    )
    expect(requested).toBe(`${ROOT}/file/bot${TOKEN}/documents/report.pdf`)
    expect(out.size).toBe(4)
    expect(statSync(out.path).mode & PERMISSION_BITS).toBe(FILE_MODE)
  })

  test('ошибка загрузки не раскрывает токен', async () => {
    const inbox = join(tmp('tg-state-'), 'inbox')
    const fetchImpl = (async (url: string) => {
      throw new Error(`connect failed: ${url}`)
    }) as unknown as typeof fetch
    try {
      await downloadViaLocalApi({ file_path: 'a/b.bin' }, TOKEN, inbox, { api_root: ROOT }, { fetchImpl })
      throw new Error('должно было упасть')
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err)
      expect(msg).toContain('connect failed')
      expect(msg).not.toContain(TOKEN)
    }
  })

  test('HTTP-ошибка сервера не раскрывает токен', async () => {
    const inbox = join(tmp('tg-state-'), 'inbox')
    const fetchImpl = (async () => new Response('no', { status: 404 })) as unknown as typeof fetch
    await expect(
      downloadViaLocalApi({ file_path: 'a/b.bin' }, TOKEN, inbox, { api_root: ROOT }, { fetchImpl }),
    ).rejects.toThrow('download failed: HTTP 404')
  })
})

describe('resolveTelegramTimeoutMs', () => {
  const cloud = (m: string): string => `https://api.telegram.org/bot${TOKEN}/${m}`
  const local = (m: string): string => `${ROOT}/bot${TOKEN}/${m}`

  test('облако без apiRoot: прежняя таблица и значение по умолчанию', () => {
    for (const [method, ms] of Object.entries(TG_TIMEOUTS_MS)) {
      expect(resolveTelegramTimeoutMs(cloud(method))).toBe(ms)
    }
    expect(resolveTelegramTimeoutMs(cloud('someNewMethod'))).toBe(TG_DEFAULT_TIMEOUT_MS)
    // зафиксированные значения: правка таблицы должна быть осознанной
    expect(resolveTelegramTimeoutMs(cloud('getUpdates'))).toBe(35_000)
    expect(resolveTelegramTimeoutMs(cloud('sendDocument'))).toBe(20_000)
    expect(resolveTelegramTimeoutMs(cloud('getFile'))).toBe(8_000)
  })

  test('облако с заданным apiRoot считается так же', () => {
    expect(resolveTelegramTimeoutMs(cloud('sendDocument'), ROOT)).toBe(20_000)
  })

  test('чужие URL не трогаем, а локальный хост без apiRoot -- тоже', () => {
    expect(resolveTelegramTimeoutMs('http://127.0.0.1:9999/health')).toBeUndefined()
    expect(resolveTelegramTimeoutMs(local('sendMessage'))).toBeUndefined()
    expect(resolveTelegramTimeoutMs('http://127.0.0.1:9999/bot1/x', ROOT)).toBeUndefined()
  })

  test('локальный сервер: быстрые методы по таблице, тяжёлые и файлы -- долго', () => {
    expect(resolveTelegramTimeoutMs(local('sendMessage'), ROOT)).toBe(8_000)
    expect(resolveTelegramTimeoutMs(local('getUpdates'), ROOT)).toBe(35_000)
    expect(resolveTelegramTimeoutMs(local('getMe'), ROOT)).toBe(5_000)
    expect(resolveTelegramTimeoutMs(local('sendDocument'), ROOT)).toBe(LOCAL_HEAVY_TIMEOUT_MS)
    expect(resolveTelegramTimeoutMs(local('sendVideo'), ROOT)).toBe(LOCAL_HEAVY_TIMEOUT_MS)
    expect(resolveTelegramTimeoutMs(local('getFile'), ROOT)).toBe(LOCAL_HEAVY_TIMEOUT_MS)
    expect(resolveTelegramTimeoutMs(`${ROOT}/file/bot${TOKEN}/videos/a.mp4`, ROOT)).toBe(
      LOCAL_HEAVY_TIMEOUT_MS,
    )
  })
})

describe('createTimedTelegramFetch', () => {
  const noPreconnect = (() => undefined) as unknown as typeof fetch.preconnect

  test('вызов Bot API локального сервера получает AbortSignal, чужой -- нет', async () => {
    const seen: Array<AbortSignal | null | undefined> = []
    const native = (async (_input: unknown, init?: RequestInit) => {
      seen.push(init?.signal)
      return new Response('{}')
    }) as unknown as typeof fetch
    const timed = createTimedTelegramFetch(native, noPreconnect, { apiRoot: ROOT })
    await timed(`${ROOT}/bot${TOKEN}/getMe`)
    await timed('http://127.0.0.1:9999/other')
    expect(seen[0]).toBeInstanceOf(AbortSignal)
    expect(seen[1]).toBeUndefined()
  })

  test('без apiRoot запрос к локальному хосту идёт мимо обёртки', async () => {
    const seen: Array<AbortSignal | null | undefined> = []
    const native = (async (_input: unknown, init?: RequestInit) => {
      seen.push(init?.signal)
      return new Response('{}')
    }) as unknown as typeof fetch
    const timed = createTimedTelegramFetch(native, noPreconnect)
    await timed(`${ROOT}/bot${TOKEN}/getMe`)
    await timed(`https://api.telegram.org/bot${TOKEN}/getMe`)
    expect(seen[0]).toBeUndefined()
    expect(seen[1]).toBeInstanceOf(AbortSignal)
  })

  test('preconnect пробрасывается', () => {
    const marker = (() => undefined) as unknown as typeof fetch.preconnect
    const timed = createTimedTelegramFetch((async () => new Response('')) as unknown as typeof fetch, marker)
    expect(timed.preconnect).toBe(marker)
  })
})

describe('grammy apiRoot', () => {
  test('Bot с client.apiRoot отправляет вызов Bot API на локальный сервер', async () => {
    // grammY под Bun берёт нативный fetch сам, подмена globalThis.fetch его не
    // перехватывает, поэтому проверяем по факту: поднимаем крошечный сервер.
    const paths: string[] = []
    const server = Bun.serve({
      hostname: '127.0.0.1',
      port: 0,
      fetch(req) {
        paths.push(new URL(req.url).pathname)
        return Response.json({ ok: true, result: true })
      },
    })
    try {
      const root = normalizeApiRoot(`http://127.0.0.1:${server.port}`)
      await new Bot(TOKEN, { client: { apiRoot: root } }).api.sendChatAction(1, 'typing')
      expect(paths).toEqual([`/bot${TOKEN}/sendChatAction`])
    } finally {
      await server.stop(true)
    }
  })
})
