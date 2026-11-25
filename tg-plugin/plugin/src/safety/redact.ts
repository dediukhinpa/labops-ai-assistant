// Unified secret redactor for all outbound text destined for Telegram, logs,
// or any other channel that might leak to operators.
//
// ORDER MATTERS. Patterns are applied in the sequence declared in the
// `RULES` array below. More specific shapes (Telegram bot tokens, provider
// API keys, IPs, Supabase hosts, Firebase JSON fields, secret paths) MUST
// run BEFORE the generic ≥24-char [A-Za-z0-9_-] long-token rule, otherwise
// the generic rule would chew through the head/tail of a token and produce
// a partially-masked-but-still-recognisable string that a careful eye can
// reverse. We pin order via a flat list rather than calling N replace()s in
// arbitrary order; if you add a new rule, slot it where its specificity
// belongs in the constant below.
//
// The redactor is IDEMPOTENT: `redactSecrets(redactSecrets(x))` equals
// `redactSecrets(x)` for every input. The `[REDACTED]` placeholder itself
// contains no characters matched by any pattern (no digits, no slashes,
// no ≥24-char run), so re-running cannot expand the mask. Tests pin this.

// Internal rule shape — kept unexported because no caller outside this
// module composes rules dynamically. If a future caller needs to inject
// a custom rule, expose this then.
interface RedactionRule {
  pattern: RegExp
  replacement: string | ((match: string, ...groups: string[]) => string)
}

// ─────────────────────────────────────────────────────────────────────
// Pattern definitions. Each entry is a single global regex + replacement.
// Order is load-bearing — see header comment.
// ─────────────────────────────────────────────────────────────────────

// Telegram bot token: `<8-12 digits>:<30+ urlsafe base64 chars>`.
// Port of TELEGRAM_TOKEN_RE in config.ts:134.
const TELEGRAM_TOKEN_RE = /\d{8,12}:[A-Za-z0-9_-]{30,}/g

// Provider API keys. Each shape is well-known and the prefix anchors the
// match so we don't collide with random base64 in URLs.
const GROQ_KEY_RE = /gsk_[A-Za-z0-9]{40,}/g
const OPENAI_PROJ_RE = /sk-proj-[A-Za-z0-9_-]{20,}/g
const OPENAI_RE = /sk-[A-Za-z0-9_-]{20,}/g
const GITHUB_PAT_RE = /ghp_[A-Za-z0-9]{30,}/g
const RESEND_RE = /re_[A-Za-z0-9_]{20,}/g
const SLACK_BOT_RE = /xoxb-[A-Za-z0-9-]+/g

// Firebase service-account JSON fields: keep the key visible, replace the
// value with `[REDACTED]`. Use a tight pattern that matches a JSON string
// value (`"…"`) only — we don't want to swallow trailing commas/braces.
// The (\\.|[^"\\])* body permits escaped quotes/newlines inside the value
// (Firebase keys have literal `\n` sequences in JSON).
const FIREBASE_FIELDS = ['private_key', 'private_key_id', 'client_email']
const FIREBASE_REs: RedactionRule[] = FIREBASE_FIELDS.map((field) => ({
  pattern: new RegExp(`("${field}"\\s*:\\s*)"(?:\\\\.|[^"\\\\])*"`, 'g'),
  replacement: '$1"[REDACTED]"',
}))

// Authorization: Bearer <opaque> — preserve the "Bearer " prefix so the
// type of header remains obvious in logs (helps spot missing auth, etc.).
// Match the casing flexibly but not the "Bearer" word itself.
const BEARER_RE = /(Bearer\s+)[A-Za-z0-9._\-+/=]{8,}/gi

// Query-string tokens: ?token=, ?access_token=, ?api_key=, &key=.
// Anchored by `[?&]` and the param name so we don't match `&keyword=` etc.
// Значение не заходит за `<`/`>`: в ответе `reply` текст уже HTML, и маска не должна
// съедать закрывающий тег (`?token=x</code>` → `?token=[REDACTED]</code>`).
const QUERY_TOKEN_RE = /([?&](?:access_token|api_key|token)=)[^&\s"'<>]+/gi

// IPv4 — keep first and last octet (helps debugging) and mask the middle
// two. Loopback (127.*) and 0.* placeholders are pure debug noise; the
// callback returns the raw match unchanged for those so operators can read
// "127.0.0.1" verbatim. Port of activity-renderer.ts:62-73.
const IPV4_RE = /\b(\d{1,3})\.\d{1,3}\.\d{1,3}\.(\d{1,3})\b/g
function ipv4Replacer(full: string, first: string, last: string): string {
  if (first === '127' || first === '0') return full
  return `${first}.***.***.${last}`
}

// Secret paths.
//   1. `~/.foo/secrets/<file>` — legacy tilde-anchored form.
//   2. anchored `secrets/<file>` — catches collapsed summaries like
//      `secrets/openviking.key`. Must match at string start OR after a
//      whitespace/path separator so we don't mangle `my-secrets/x`.
//   Путь кончается на пробеле ИЛИ на `<`/`>`: `reply` превращает `путь` в
//   <code>путь</code>, и прежний `\S+` съедал `</code>` — Telegram отвергал HTML,
//   плагин слал сообщение простым текстом с видимыми `&lt;code&gt;` (24.11.2026).
const SECRET_PATH_TILDE_RE = /(~\/?\.\w+\/)secrets\/[^\s<>]+/g
const SECRET_PATH_ANCHORED_RE = /(^|[\s/])secrets\/[^\s<>]+/g

// Supabase project host: `<projectid>.supabase.co`. The callback masks the
// inner project-id segment while leaving `.supabase.co` intact so the
// provider remains identifiable in logs.
const SUPABASE_HOST_RE = /[a-z0-9]{10,}\.supabase\.co/g
function supabaseReplacer(host: string): string {
  const parts = host.split('.')
  if (parts.length === 0) return host
  const first = parts[0] ?? ''
  if (first.length > 8) {
    parts[0] = `${first.slice(0, 4)}*****${first.slice(-4)}`
  }
  if (parts.length > 1) {
    const idx = parts.length - 2
    const seg = parts[idx] ?? ''
    if (seg.length > 5) {
      parts[idx] = `${seg.slice(0, 4)}***`
    }
  }
  return parts.join('.')
}

// Telegram bot token (mid-shape variant from activity-renderer.ts): emits
// `NNN***:AA***` instead of `[REDACTED]` so the prefix shape stays visible.
// We keep this AFTER the canonical TELEGRAM_TOKEN_RE rule because the
// canonical rule replaces the whole token with `[REDACTED]` — once that
// fires, this regex no longer matches (no digits remain). Order ensures
// idempotency.
const TELEGRAM_TOKEN_PARTIAL_RE = /\b(\d{3})\d{7,}:(AA\w{2})\w+/g

// Generic long token rule (≥24 chars of [A-Za-z0-9_-]). LAST — keeps head
// and tail visible so a partial mask is still useful for debugging.
const GENERIC_LONG_TOKEN_RE = /\b([A-Za-z0-9_-]{4})[A-Za-z0-9_-]{16,}([A-Za-z0-9_-]{4})\b/g

// http(s) URL span. The generic rule above matches any ≥24-char run of
// [A-Za-z0-9_-], which is exactly what a normal link's path / query / id
// segment looks like (slugs, file ids, signed tokens, commit SHAs). Running
// it over a URL injects `***` into the middle and silently rewrites the link
// to a wrong-but-plausible address — the operator clicks and lands elsewhere.
// So the generic rule is held back from URL spans (see `redactSecrets`). This
// is safe: real secrets inside a URL carry their own shape and are already
// masked by the specific rules above, which still run over the whole text —
// `?token=`/`?api_key=`/`?access_token=` (QUERY_TOKEN_RE), provider keys
// (sk-…, gsk_…, ghp_…), `Bearer …`, and the Telegram bot-token shape. The
// span stops at whitespace or quote/angle/backtick so an href="…" boundary
// and a bare trailing space both end it cleanly.
// Кроме http(s)-ссылок ссылкой считается IPv4 с портом или путём без схемы
// (`10.1.2.3:8098/dash`): Telegram делает её кликабельной, и агенты так пишут адреса.
// Голый IP в тексте («сервер 10.1.2.3») ссылкой не считается и маскируется как раньше.
const LINK_SPAN_RE =
  /\bhttps?:\/\/[^\s<>"'`]+|\b(?:\d{1,3}\.){3}\d{1,3}(?::\d{1,5}(?:\/[^\s<>"'`]*)?|\/[^\s<>"'`]*)/gi

// Исключение из общего правила: составные имена из строчных слов через `_`/`-` — имена
// инструментов и серверов MCP (`mcp__second_brain-agent_router__list_my_pending`,
// `second_brain-memory_router`). Их маскировка делала ленту хода нечитаемой (прогон
// 23.11.2026). Слово — только строчные буквы и не больше одной цифры в конце, слов хотя бы
// два: в токенах есть заглавные, цифры в середине или нет разделителей, они по-прежнему
// маскируются.
const IDENTIFIER_WORD_RE = /^[a-z]+[0-9]?$/
const MIN_IDENTIFIER_WORDS = 2
function isCompoundIdentifier(candidate: string): boolean {
  const words = candidate.split(/[_-]+/).filter(w => w !== '')
  return words.length >= MIN_IDENTIFIER_WORDS && words.every(w => IDENTIFIER_WORD_RE.test(w))
}
function genericLongTokenReplacer(match: string, head: string, tail: string): string {
  return isCompoundIdentifier(match) ? match : `${head}***${tail}`
}

// ─────────────────────────────────────────────────────────────────────
// Public API
// ─────────────────────────────────────────────────────────────────────

const RULES: ReadonlyArray<RedactionRule> = [
  // 1. Provider tokens with anchored prefixes — most specific first.
  { pattern: TELEGRAM_TOKEN_RE, replacement: '[REDACTED]' },
  { pattern: GROQ_KEY_RE, replacement: '[REDACTED]' },
  { pattern: OPENAI_PROJ_RE, replacement: '[REDACTED]' },
  { pattern: OPENAI_RE, replacement: '[REDACTED]' },
  { pattern: GITHUB_PAT_RE, replacement: '[REDACTED]' },
  { pattern: RESEND_RE, replacement: '[REDACTED]' },
  { pattern: SLACK_BOT_RE, replacement: '[REDACTED]' },
  // 2. Firebase JSON fields — value replaced, key preserved.
  ...FIREBASE_REs,
  // 3. Auth header + query params — preserve prefix.
  { pattern: BEARER_RE, replacement: '$1[REDACTED]' },
  { pattern: QUERY_TOKEN_RE, replacement: '$1[REDACTED]' },
  // 5. Secret paths.
  { pattern: SECRET_PATH_TILDE_RE, replacement: '$1secrets/***' },
  { pattern: SECRET_PATH_ANCHORED_RE, replacement: '$1secrets/***' },
  // 6. Supabase host: id проекта чувствителен и в ссылке, маскируется везде.
  { pattern: SUPABASE_HOST_RE, replacement: supabaseReplacer },
  // 7. Telegram partial-mask shape (renderer-style).
  { pattern: TELEGRAM_TOKEN_PARTIAL_RE, replacement: '$1***:$2***' },
  // NB: правило IPv4 и общее правило длинных токенов
  // применяются отдельно и только вне ссылок — см. OUTSIDE_LINK_RULES / LINK_SPAN_RE.
]

// Правила, которые маскируют части адреса, а не секреты: IP и длинные id. Внутри ссылки они ломают адрес: агент прислал дашборд
// `http://<IP>:8098/...`, а пользователю дошло `203.***.***.87` — ссылка не открывалась (25.11.2026).
// Поэтому внутри ссылок работают только правила секретов (RULES выше: токены провайдеров,
// `Bearer`, `?token=`, токен бота), а эти — только в обычном тексте.
const OUTSIDE_LINK_RULES: ReadonlyArray<RedactionRule> = [
  { pattern: IPV4_RE, replacement: ipv4Replacer },
  { pattern: GENERIC_LONG_TOKEN_RE, replacement: genericLongTokenReplacer },
]

// Apply the generic long-token rule to every span of `text` that is NOT part
// of an http(s) URL, leaving URLs byte-for-byte intact. Specific-shape secrets
// have already been masked by `RULES` over the whole text (URLs included), so
// the only thing this rule would still catch inside a URL is a legitimate long
// path/id segment — which we must not corrupt.
function applyRule(text: string, rule: RedactionRule): string {
  if (typeof rule.replacement === 'string') return text.replace(rule.pattern, rule.replacement)
  return text.replace(rule.pattern, rule.replacement as (sub: string, ...args: unknown[]) => string)
}

function applyOutsideLinks(text: string): string {
  const outside = (chunk: string): string => OUTSIDE_LINK_RULES.reduce(applyRule, chunk)
  let out = ''
  let last = 0
  LINK_SPAN_RE.lastIndex = 0
  for (const match of text.matchAll(LINK_SPAN_RE)) {
    const start = match.index ?? 0
    out += outside(text.slice(last, start)) // обычный текст — маскируем
    out += match[0] // сама ссылка — без изменений
    last = start + match[0].length
  }
  out += outside(text.slice(last))
  return out
}

/**
 * Apply every redaction rule to `text` in declaration order, then mask
 * caller-supplied exact-substring secrets (`extras`). Returns the redacted
 * string. Idempotent for any input.
 *
 * @param text  Arbitrary string. Treated as untrusted — may contain secrets.
 * @param extras Optional list of exact substrings to mask (e.g. webhook
 *               tokens that have no public pattern). Strings shorter than
 *               4 chars are ignored to avoid catastrophic false positives.
 */
export function redactSecrets(
  text: string,
  extras?: ReadonlyArray<string>,
): string {
  let out = text
  // Extras BEFORE patterns: caller-supplied exact substrings (e.g. webhook
  // tokens with no public shape) get masked first so the downstream generic
  // long-token rule doesn't partially eat them and leave a recoverable
  // prefix/suffix. Short (<4 chars) entries are ignored as catastrophic-
  // false-positive guards.
  if (extras && extras.length > 0) {
    for (const secret of extras) {
      if (!secret || secret.length < 4) continue
      const escaped = secret.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
      out = out.replace(new RegExp(escaped, 'g'), '[REDACTED]')
    }
  }
  out = RULES.reduce(applyRule, out)
  // Адреса и длинные токены — последними и только вне ссылок, чтобы не сломать адрес.
  out = applyOutsideLinks(out)
  return out
}
