// Маршрутизация личных сообщений: оператор -- в главную сессию, остальные
// разрешённые люди -- через multichat-роутер, каждый в свою сессию.
//
// Зачем: прокси псевдонимизации привязывает таблицу замен к сессии Claude. Если
// личка двух людей идёт в один контекст, токен ПДн из разговора с А
// восстановится в ответе Б. Группы уже изолированы роутером; здесь то же самое
// для лички.
//
// Чистые функции без побочных эффектов, кроме одноразового предупреждения.
import type { MultichatPolicy } from '../chats/policy-loader.js'
import type { AppConfig } from '../config.js'
import type { Logger } from '../log.js'

/** Режим маршрутизации лички не-оператора. */
export type DmRoutingMode = 'main' | 'per_person'

/** Причина, по которой личка не может быть принята роутером. */
export type DmRouterRefusal = 'user_not_in_policy' | 'chat_not_in_policy'

/**
 * Список операторов: явный `operator_user_ids`, иначе получатели разрешений.
 *
 * @param config Конфиг плагина.
 * @returns Числовые id операторов.
 */
export function resolveOperatorUserIds(config: AppConfig): readonly number[] {
  return config.operator_user_ids ?? config.permission_relay.allowed_user_ids
}

/**
 * Является ли отправитель оператором.
 *
 * @param senderId Telegram user id (строкой или числом).
 * @param config Конфиг плагина.
 */
export function isOperatorUser(senderId: string | number, config: AppConfig): boolean {
  const id = String(senderId)
  return resolveOperatorUserIds(config).some((v) => String(v) === id)
}

/**
 * Эффективный режим лички. Без роутера всегда 'main' (поведение как раньше),
 * даже если в конфиге явно указан per_person: отправлять некуда.
 *
 * @param config Конфиг плагина.
 * @param routerActive Есть ли работающий роутер вместе с политикой.
 */
export function resolveDmRoutingMode(config: AppConfig, routerActive: boolean): DmRoutingMode {
  if (!routerActive) return 'main'
  // Оператор неизвестен -- нельзя понять, чью личку оставить в главной сессии;
  // иначе сам владелец ушёл бы в отдельную сессию. Остаёмся на прежнем поведении.
  if (resolveOperatorUserIds(config).length === 0) return 'main'
  return config.dm_routing ?? 'per_person'
}

/**
 * Нужно ли отправить личное сообщение через роутер в отдельную сессию.
 *
 * @param config Конфиг плагина.
 * @param routerActive Есть ли роутер и политика.
 * @param senderId Telegram user id отправителя.
 * @returns true только для не-оператора в режиме per_person.
 */
export function shouldRouteDmPerPerson(
  config: AppConfig,
  routerActive: boolean,
  senderId: string,
): boolean {
  if (resolveDmRoutingMode(config, routerActive) !== 'per_person') return false
  return !isOperatorUser(senderId, config)
}

/**
 * Проверка, что роутер примет личку: человек и его чат описаны в политике.
 * Иначе dispatch молча отбросит сообщение; лучше отказать заранее и громко.
 *
 * @param policy Политика multichat.
 * @param chatId Личный чат (равен user id).
 * @param userId Отправитель.
 * @returns null, если можно; иначе причина отказа.
 */
export function checkDmRouterAccess(
  policy: MultichatPolicy,
  chatId: string,
  userId: string,
): DmRouterRefusal | null {
  if (!policy.allowlist.users.includes(userId)) return 'user_not_in_policy'
  if (!(chatId in policy.chats)) return 'chat_not_in_policy'
  return null
}

/**
 * Однократное предупреждение при старте: роутер выключен, а людей в allowlist
 * больше одного -- их личка смешивается в главной сессии. Без id и имён.
 *
 * @param config Конфиг плагина.
 * @param routerActive Есть ли роутер и политика.
 * @param log Логгер.
 * @returns true, если предупреждение выдано.
 */
export function warnIfSharedDmContext(
  config: AppConfig,
  routerActive: boolean,
  log: Logger,
): boolean {
  const mode = resolveDmRoutingMode(config, routerActive)
  const people = new Set(config.allowed_user_ids.map(String))
  if (mode === 'per_person' || people.size <= 1) return false
  log.warn('dm_routing.shared_context', {
    allowed_users: people.size,
    router_active: routerActive,
    operators_known: resolveOperatorUserIds(config).length > 0,
    hint: 'личка нескольких людей идёт в одну сессию; включите multichat и operator_user_ids',
  })
  return true
}
