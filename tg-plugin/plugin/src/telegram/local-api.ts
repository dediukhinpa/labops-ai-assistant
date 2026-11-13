// Поддержка ЛОКАЛЬНОГО сервера Telegram Bot API (tdlib/telegram-bot-api, --local).
//
// Облачный api.telegram.org режет отправку файлов на 50 МБ, а скачивание на
// 20 МБ. Локальный сервер снимает оба потолка (до 2000 МБ) и в режиме --local
// отдаёт в getFile АБСОЛЮТНЫЙ путь файла на диске сервера.
//
// Всё здесь включается только переменной TELEGRAM_API_ROOT. Без неё модуль
// ничего не меняет: ни адреса, ни лимиты, ни пути скачивания.
//
// Токен бота не пишем ни в сообщения об ошибках, ни в логи: всё, что может
// содержать URL с токеном, пропускается через redactSecrets.

import {
  chmodSync,
  constants as fsConstants,
  copyFileSync,
  createWriteStream,
  mkdirSync,
  realpathSync,
  statSync,
} from 'fs'
import { isAbsolute, join, sep } from 'path'
import { Readable } from 'stream'
import { pipeline } from 'stream/promises'

import { redactSecrets } from '../safety/redact.js'

/** Облачный хост: его нельзя указывать как «локальный» корень. */
const CLOUD_API_HOST = 'api.telegram.org'

/** Хосты, на которые можно ходить по голому http: токен в URL, наружу он не уйдёт. */
const LOOPBACK_HOSTNAMES: ReadonlySet<string> = new Set(['localhost', '[::1]'])
const IPV4_LOOPBACK_RE = /^127(?:\.\d{1,3}){3}$/

/** Права на скачанные вложения: документы клиента, только владельцу. */
const LOCAL_DIR_MODE = 0o700
const LOCAL_FILE_MODE = 0o600

/** Настройки локального Bot API (в AppConfig лежат под ключом local_api). */
export interface LocalApiConfig {
  /** Нормализованный корень сервера, например http://127.0.0.1:8081 (без «/» на конце). */
  api_root: string
  /** Каталог данных сервера: читать файлы с диска разрешено только внутри него. */
  local_dir?: string | undefined
}

/**
 * Проверяет и нормализует TELEGRAM_API_ROOT.
 *
 * Правила: только http(s); без логина/пароля, пути, query и фрагмента (grammy
 * сам добавляет /bot<token>/<метод>); голый http допустим только для
 * loopback, иначе токен пойдёт по сети открытым текстом; облачный хост
 * api.telegram.org запрещён (иначе поднялись бы лимиты, которых у облака нет).
 *
 * @throws Error с понятным текстом (значение в сообщение не подставляем).
 */
export function normalizeApiRoot(raw: string): string {
  let url: URL
  try {
    url = new URL(raw.trim())
  } catch {
    throw new Error('TELEGRAM_API_ROOT must be an absolute http(s) URL, e.g. http://127.0.0.1:8081')
  }
  if (url.protocol !== 'http:' && url.protocol !== 'https:') {
    throw new Error('TELEGRAM_API_ROOT must use http: or https:')
  }
  if (url.username !== '' || url.password !== '') {
    throw new Error('TELEGRAM_API_ROOT must not contain credentials')
  }
  if ((url.pathname !== '/' && url.pathname !== '') || url.search !== '' || url.hash !== '') {
    throw new Error('TELEGRAM_API_ROOT must be a bare origin without path, query or fragment')
  }
  if (url.hostname === CLOUD_API_HOST) {
    throw new Error('TELEGRAM_API_ROOT must point to a local Bot API server, not api.telegram.org')
  }
  if (url.protocol === 'http:' && !isLoopbackHost(url.hostname)) {
    throw new Error(
      'TELEGRAM_API_ROOT over plain http is allowed for loopback only (127.0.0.0/8, localhost, ::1); '
        + 'use https for a remote host, otherwise the bot token travels unencrypted',
    )
  }
  return url.origin
}

function isLoopbackHost(hostname: string): boolean {
  return LOOPBACK_HOSTNAMES.has(hostname) || IPV4_LOOPBACK_RE.test(hostname)
}

/** Проверка TELEGRAM_API_LOCAL_DIR: только абсолютный путь. */
export function assertAbsoluteLocalDir(raw: string): string {
  const dir = raw.trim()
  if (!isAbsolute(dir)) {
    throw new Error('TELEGRAM_API_LOCAL_DIR must be an absolute path')
  }
  return dir
}

/** URL скачивания файла: облако или локальный сервер без file_path-абсолюта. */
export function buildFileUrl(token: string, filePath: string, localApi?: LocalApiConfig): string {
  const root = localApi === undefined ? 'https://api.telegram.org' : localApi.api_root
  return `${root}/file/bot${token}/${filePath}`
}

/**
 * Приводит абсолютный путь из getFile к реальному файлу внутри каталога данных
 * сервера. Симлинки и `..` раскрываются через realpath ДО проверки вхождения,
 * поэтому выйти за каталог ссылкой нельзя.
 *
 * @throws Error, если каталог не задан, путь вне него или это не обычный файл.
 */
export function resolveLocalApiFile(filePath: string, localDir: string | undefined): string {
  if (localDir === undefined) {
    throw new Error(
      'local Bot API returned an on-disk file path but TELEGRAM_API_LOCAL_DIR is not set; '
        + 'refusing to read it',
    )
  }
  let canonicalDir: string
  try {
    canonicalDir = realpathSync(localDir)
  } catch {
    throw new Error('TELEGRAM_API_LOCAL_DIR is not readable')
  }
  let canonicalFile: string
  try {
    canonicalFile = realpathSync(filePath)
  } catch {
    throw new Error('local Bot API file does not exist or is not readable')
  }
  const prefix = canonicalDir.endsWith(sep) ? canonicalDir : canonicalDir + sep
  if (!canonicalFile.startsWith(prefix)) {
    throw new Error('refusing to read a file outside TELEGRAM_API_LOCAL_DIR')
  }
  if (!statSync(canonicalFile).isFile()) {
    throw new Error('local Bot API path is not a regular file')
  }
  return canonicalFile
}

export interface LocalFileInfo {
  file_path: string
  file_unique_id?: string | undefined
}

export interface LocalDownloadDeps {
  fetchImpl?: typeof fetch
  now?: () => number
}

/** Расширение и имя во входящей папке строятся так же, как в облачной ветке. */
function inboxFileName(info: LocalFileInfo, now: number, fallbackId: string): string {
  const rawExt = info.file_path.includes('.') ? info.file_path.split('.').pop() ?? 'bin' : 'bin'
  const ext = rawExt.replace(/[^a-zA-Z0-9]/g, '') || 'bin'
  const uniqueId = (info.file_unique_id ?? '').replace(/[^a-zA-Z0-9_-]/g, '') || fallbackId
  return `${now}-${uniqueId}.${ext}`
}

/**
 * Скачивает файл через локальный Bot API в каталог `destDir`.
 *
 * Абсолютный file_path читается с диска (копия, без загрузки в память: файлы
 * бывают до 2 ГБ); относительный — по HTTP потоком в файл. Лимита 20 МБ нет.
 *
 * @returns путь сохранённой копии и размер в байтах.
 */
export async function downloadViaLocalApi(
  info: LocalFileInfo,
  token: string,
  destDir: string,
  localApi: LocalApiConfig,
  deps: LocalDownloadDeps = {},
  fallbackId = 'dl',
): Promise<{ path: string; size: number }> {
  const secrets = [token]
  const now = deps.now ? deps.now() : Date.now()
  const dest = join(destDir, inboxFileName(info, now, fallbackId))
  try {
    mkdirSync(destDir, { recursive: true, mode: LOCAL_DIR_MODE })
    if (isAbsolute(info.file_path)) {
      const src = resolveLocalApiFile(info.file_path, localApi.local_dir)
      // FICLONE: на copy-on-write ФС копия мгновенная, иначе обычное копирование.
      copyFileSync(src, dest, fsConstants.COPYFILE_FICLONE)
      chmodSync(dest, LOCAL_FILE_MODE)
      return { path: dest, size: statSync(dest).size }
    }
    const fetchFn = deps.fetchImpl ?? fetch
    const res = await fetchFn(buildFileUrl(token, info.file_path, localApi))
    if (!res.ok || res.body === null) throw new Error(`download failed: HTTP ${res.status}`)
    const out = createWriteStream(dest, { mode: LOCAL_FILE_MODE })
    await pipeline(Readable.fromWeb(res.body as never), out)
    chmodSync(dest, LOCAL_FILE_MODE)
    return { path: dest, size: statSync(dest).size }
  } catch (err) {
    // В тексте ошибки мог оказаться URL с токеном: вычищаем до выхода наружу.
    const msg = err instanceof Error ? err.message : String(err)
    throw new Error(redactSecrets(msg, secrets))
  }
}
