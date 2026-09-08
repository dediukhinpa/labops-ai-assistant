// Telegram card for the confirm gate. Mirrors the keyboard shape of
// channel/permissions.ts (See more / Allow / Deny) so the operator sees one
// consistent confirmation UX, but uses a distinct `confirm:` callback
// namespace so the two relays never consume each other's taps.

import type { InlineKeyboardLike } from '../channel/tools.js'
import type { GateDecision } from '../safety/tool-classifier.js'

const CALLBACK_RE = /^confirm:(allow|deny|more):([a-km-z]{5})$/

export function parseConfirmCallback(
  data: string,
): { behavior: 'allow' | 'deny' | 'more'; requestId: string } | null {
  const m = CALLBACK_RE.exec(data)
  if (!m || !m[1] || !m[2]) return null
  return { behavior: m[1] as 'allow' | 'deny' | 'more', requestId: m[2] }
}

function escapeHtml(s: string): string {
  return s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;')
}

// The card is read by the client, not by an engineer, so the reason has to
// be Russian prose. GateDecision.reason stays English on purpose (it is the
// audit key in logs/permissions.jsonl); the Russian sentence is rendered here
// from the structured `code` + `detail` pair instead of by re-parsing it.
export function reasonInRussian(decision: GateDecision): string {
  const d = decision.detail
  switch (decision.code) {
    case 'verb-destroy':
      return `в имени инструмента разрушающий глагол «${d}»`
    case 'verb-mutate':
      return `в имени инструмента изменяющий глагол «${d}»`
    case 'verb-read':
      return `читающий глагол «${d}»`
    case 'verb-unknown':
      return 'глагол не распознан — по умолчанию спрашиваем'
    case 'url-verb':
      return decision.cls === 'destroy'
        ? `в адресе запроса разрушающий глагол «${d}»`
        : `в адресе запроса изменяющий глагол «${d}»`
    case 'http-method':
      return `HTTP-метод ${d}`
    case 'bash-http-method':
      return `в команде HTTP-метод ${d}`
    case 'bash-pattern':
      return `команда совпала с защищённым шаблоном «${d}»`
    case 'protected-file':
      return `правка защищённого файла: ${d}`
    case 'override-deny':
      return `запрещено политикой: ${d}`
    case 'override-allow':
      return `разрешено политикой: ${d}`
    case 'mode-off':
      return 'гейт выключен'
    case 'local-tool':
      return 'локальный инструмент, не внешняя интеграция'
    case 'plain-bash':
      return 'обычная команда'
    default:
      return decision.reason
  }
}

// 5 lowercase letters a-z minus 'l' — same alphabet as the permission relay,
// so ids stay unambiguous when read aloud or retyped on a phone.
export function newConfirmId(): string {
  const alphabet = 'abcdefghijkmnopqrstuvwxyz'
  let out = ''
  for (let i = 0; i < 5; i += 1) {
    out += alphabet[Math.floor(Math.random() * alphabet.length)]
  }
  return out
}

export function renderConfirmCard(
  toolName: string,
  decision: GateDecision,
  inputPreview: string,
  requestId: string = newConfirmId(),
): { text: string; replyMarkup: InlineKeyboardLike; requestId: string } {
  const mark = decision.cls === 'destroy' ? 'УДАЛЕНИЕ' : 'ИЗМЕНЕНИЕ'
  const text =
    `<b>${mark} — подтверди операцию</b>\n\n`
    + `инструмент: <code>${escapeHtml(toolName)}</code>\n`
    + `причина: ${escapeHtml(reasonInRussian(decision))}\n`
    + `id: <code>${requestId}</code>`
  const replyMarkup: InlineKeyboardLike = {
    inline_keyboard: [[
      { text: 'Подробнее', callback_data: `confirm:more:${requestId}` },
      { text: 'Подтвердить', callback_data: `confirm:allow:${requestId}` },
      { text: 'Отклонить', callback_data: `confirm:deny:${requestId}` },
    ]],
  }
  void inputPreview
  return { text, replyMarkup, requestId }
}

// Expanded view behind the "Подробнее" button: the operator must be able to
// see WHAT is being changed, not just which tool is being called. A tool name
// alone is not enough to approve a deletion.
export function renderConfirmDetails(
  toolName: string,
  decision: GateDecision,
  inputPreview: string,
  requestId: string,
): { text: string; replyMarkup: InlineKeyboardLike } {
  let pretty: string
  try {
    pretty = JSON.stringify(JSON.parse(inputPreview), null, 2)
  } catch {
    pretty = inputPreview
  }
  // Telegram caps a message at 4096 chars; leave room for the header.
  const clipped = pretty.length > 3000 ? `${pretty.slice(0, 3000)}\n…` : pretty
  const text =
    `<b>${decision.cls === 'destroy' ? 'УДАЛЕНИЕ' : 'ИЗМЕНЕНИЕ'} — подтверди операцию</b>\n\n`
    + `инструмент: <code>${escapeHtml(toolName)}</code>\n`
    + `причина: ${escapeHtml(reasonInRussian(decision))}\n`
    + `id: <code>${requestId}</code>\n\n`
    + `аргументы:\n<pre>${escapeHtml(clipped)}</pre>`
  const replyMarkup: InlineKeyboardLike = {
    inline_keyboard: [[
      { text: 'Подтвердить', callback_data: `confirm:allow:${requestId}` },
      { text: 'Отклонить', callback_data: `confirm:deny:${requestId}` },
    ]],
  }
  return { text, replyMarkup }
}
