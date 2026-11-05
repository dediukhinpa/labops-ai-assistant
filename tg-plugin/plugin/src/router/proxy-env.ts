// Прокси маскирования ПДн для сессий multichat.
//
// Зачем: роутер вычищает ANTHROPIC_* из окружения сессий собеседников (см. FORBIDDEN_ENV_REGEX
// в tmux-session-pool.ts), а сам claude читает ANTHROPIC_BASE_URL ещё и из блока env файла
// `{chatsBasePath}/.claude/settings.json`. Без записи туда сессия чужого собеседника шла бы
// прямо в API, мимо pii-proxy агента (дыра, найденная в плане 152-ФЗ 05.11.2026).
//
// Источник правды - settings.json самого агента (`{workspaceDir}/settings.json`): тот же ключ,
// что читает его основная сессия, поэтому порт прокси не может разойтись.

import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'

/** Ключи env из settings.json агента, которые наследуют сессии собеседников. */
export const PROXY_ENV_KEYS = [
  'ANTHROPIC_BASE_URL',
  'DISABLE_TELEMETRY',
  'DISABLE_ERROR_REPORTING',
  'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC',
] as const

/** Прокси слушает только локальный адрес: любое другое значение не считается прокси агента. */
const LOCAL_PROXY_URL = /^http:\/\/(127\.0\.0\.1|localhost):\d+\/?$/

function readJsonObject(path: string): Record<string, unknown> | undefined {
  try {
    const data: unknown = JSON.parse(readFileSync(path, 'utf8'))
    if (data !== null && typeof data === 'object' && !Array.isArray(data)) {
      return data as Record<string, unknown>
    }
  } catch {
    // нет файла или битый JSON - ниже решается, что делать
  }
  return undefined
}

/**
 * Прописать прокси агента в `{chatsBasePath}/.claude/settings.json` (идемпотентно).
 *
 * @param workspaceDir Рабочий каталог агента (там лежит его settings.json).
 * @param chatsBasePath cwd сессий собеседников.
 * @returns true, если у агента есть прокси и он прописан; false, если прокси у агента нет.
 * @throws Error, если прокси есть, а записать его нельзя: сессию лучше не поднимать, чем
 *   отправить данные собеседника в API напрямую.
 */
export function ensureChatsProxyEnv(workspaceDir: string, chatsBasePath: string): boolean {
  const agentSettings = readJsonObject(join(workspaceDir, 'settings.json'))
  const agentEnv = agentSettings?.env
  if (agentEnv === null || typeof agentEnv !== 'object') return false
  const env = agentEnv as Record<string, unknown>
  const url = env.ANTHROPIC_BASE_URL
  if (typeof url !== 'string' || !LOCAL_PROXY_URL.test(url)) return false

  const target = join(chatsBasePath, '.claude', 'settings.json')
  const existing = existsSync(target) ? readJsonObject(target) : {}
  if (existing === undefined) {
    throw new Error(`multichat: ${target} не разобран - не поднимаю сессию без прокси ПДн`)
  }
  const chatsEnv: Record<string, unknown> =
    existing.env !== null && typeof existing.env === 'object'
      ? { ...(existing.env as Record<string, unknown>) }
      : {}
  let changed = false
  for (const key of PROXY_ENV_KEYS) {
    const value = env[key]
    if (typeof value === 'string' && value !== '' && chatsEnv[key] !== value) {
      chatsEnv[key] = value
      changed = true
    }
  }
  if (!changed) return true
  try {
    mkdirSync(dirname(target), { recursive: true })
    const tmp = `${target}.tmp`
    writeFileSync(tmp, `${JSON.stringify({ ...existing, env: chatsEnv }, null, 2)}\n`)
    renameSync(tmp, target)
  } catch (e) {
    throw new Error(`multichat: не удалось записать прокси ПДн в ${target}: ${String(e)}`)
  }
  return true
}
