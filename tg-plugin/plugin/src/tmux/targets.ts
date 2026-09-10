// targets.ts — единственное место, где строится форма цели tmux (`-t ...`).
//
// ПОЧЕМУ ТОЛЬКО ТОЧНЫЕ ЦЕЛИ. Голое `-t NAME` tmux разрешает так: сначала точное
// имя сессии, а если такой нет — первая сессия, чьё имя НАЧИНАЕТСЯ с NAME
// (проверено на tmux 3.4: `has-session -t labops-labops-app` нашёл
// labops-labops-app-124546645). Для плагина это значит: при осиротевшем bun или
// AGENT_ID, разошедшемся с именем сессии, текст оператора печатается в соседнего
// агента с более длинным именем; в пуле multichat мёртвая `multichat-12345`
// «оживает» за счёт `multichat-1234567`, а kill убивает чужой чат.
//
// Префикс `=` запрещает этот откат: нет точной сессии — команда падает.
//
// ПОЧЕМУ ПАНЕЛЬ — `^.{top-left}`, А НЕ `=имя:`. Цель `=имя:` означает ТЕКУЩЕЕ окно
// сессии: стоит оператору открыть второе окно, и клавиши уходят туда. `^` — первое
// окно, `{top-left}` — его верхняя левая панель; обе формы не зависят от
// base-index / pane-base-index (проверено при значении 1). Это соглашение общее
// для всего монорепо, не менять в одном месте.

/** Префикс, запрещающий tmux подбирать сессию по началу имени. */
const EXACT_SESSION_PREFIX = '='

/** Первое окно сессии и его верхняя левая панель — там живёт claude. */
const FIRST_WINDOW_TOP_LEFT_PANE = '^.{top-left}'

// `:` и `.` — разделители в синтаксисе цели (сессия:окно.панель): имя с ними
// превратилось бы в другую цель. Пробельные символы в именах наших сессий не
// встречаются и в аргументе цели означают ошибку сборки имени.
const FORBIDDEN_NAME_CHARS = /[:.\s]/

/**
 * Проверяет, что имя сессии можно безопасно вставить в цель tmux.
 *
 * @param name - Голое имя сессии, например `labops-carmella`.
 * @throws {TypeError} Имя пустое или содержит `:`, `.` или пробельный символ.
 */
export function assertSessionName(name: string): void {
  if (name.length === 0) {
    throw new TypeError('tmux session name must not be empty')
  }
  if (FORBIDDEN_NAME_CHARS.test(name)) {
    throw new TypeError(`tmux session name must not contain ':', '.' or whitespace: ${name}`)
  }
}

/**
 * Точная цель сессии для команд над сессией (`has-session`, `kill-session`,
 * `attach-session`).
 *
 * @param name - Голое имя сессии.
 * @returns Цель вида `=имя`.
 * @throws {TypeError} См. {@link assertSessionName}.
 */
export function sessionTarget(name: string): string {
  assertSessionName(name)
  return `${EXACT_SESSION_PREFIX}${name}`
}

/**
 * Точная цель панели для команд над панелью (`send-keys`, `capture-pane`).
 *
 * @param name - Голое имя сессии.
 * @returns Цель вида `=имя:^.{top-left}`.
 * @throws {TypeError} См. {@link assertSessionName}.
 */
export function paneTarget(name: string): string {
  return `${sessionTarget(name)}:${FIRST_WINDOW_TOP_LEFT_PANE}`
}
