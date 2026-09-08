// Verb-based classification of a tool call.
//
// Why the verb and not the HTTP method: a PreToolUse hook sees only
// tool_name + tool_input. The DELETE request is issued by the MCP server
// itself, after the hook has already let the call through. The verb in the
// tool name is the one signal every MCP vendor exposes.
//
// Exact token matching, no stemming: "deleted" must NOT match "delete",
// otherwise `list_deleted_items` (read-only) would prompt the operator.

export type ToolClass = 'read' | 'mutate' | 'destroy' | 'unknown'

const READ_VERBS = new Set([
  'list', 'get', 'search', 'read', 'query', 'find', 'fetch', 'describe',
  'show', 'status', 'count', 'view', 'preview', 'check', 'export',
])

const MUTATE_VERBS = new Set([
  'create', 'add', 'update', 'patch', 'set', 'write', 'insert', 'append',
  'edit', 'modify', 'move', 'copy', 'rename', 'upload', 'share', 'assign',
  'close', 'cancel', 'archive', 'publish', 'send', 'post',
])

const DESTROY_VERBS = new Set([
  'delete', 'remove', 'destroy', 'drop', 'purge', 'truncate', 'revoke',
  'wipe', 'clear', 'reset', 'bulk',
])

// `mcp__<server>__<tool>` — the server segment may itself contain
// underscores (e.g. `claude_ai_Notion`), so split on the double underscore
// and keep everything after the second segment.
export function tokenizeToolName(toolName: string): string[] {
  const parts = toolName.split('__')
  const tail = parts.length >= 3 ? parts.slice(2).join('__') : toolName
  return tail
    .replace(/([a-z0-9])([A-Z])/g, '$1 $2')
    .split(/[^A-Za-z0-9]+/)
    .filter(t => t.length > 0)
    .map(t => t.toLowerCase())
}

export type VerbVerdict = {
  cls: ToolClass
  /** Audit string. English and stable — it lands in logs/permissions.jsonl. */
  reason: string
  code: ReasonCode
  /** The matched token, method, or pattern. Empty when nothing matched. */
  detail: string
}

export function classifyByVerb(toolName: string): VerbVerdict {
  const tokens = tokenizeToolName(toolName)
  for (const t of tokens) {
    if (DESTROY_VERBS.has(t)) {
      return { cls: 'destroy', reason: `destructive verb "${t}"`, code: 'verb-destroy', detail: t }
    }
  }
  for (const t of tokens) {
    if (MUTATE_VERBS.has(t)) {
      return { cls: 'mutate', reason: `mutating verb "${t}"`, code: 'verb-mutate', detail: t }
    }
  }
  for (const t of tokens) {
    if (READ_VERBS.has(t)) {
      return { cls: 'read', reason: `read-only verb "${t}"`, code: 'verb-read', detail: t }
    }
  }
  return {
    cls: 'unknown',
    reason: 'no known verb in tool name',
    code: 'verb-unknown',
    detail: '',
  }
}

// ─────────────────────────────────────────────────────────────────────
// Full gate decision. Precedence is the contract — see
// docs/superpowers/specs/2026-09-08-confirm-gate-spec.md.
// ─────────────────────────────────────────────────────────────────────

import type { ConfirmPolicy } from './confirm-policy.js'
import { matchesGlob } from './confirm-policy.js'

// Why both `reason` and `code`/`detail`: the two consumers want different
// things. The audit line in logs/permissions.jsonl wants a stable English
// string it can be grepped by across releases; the Telegram card wants
// Russian, because a client reads it. Rendering Russian by re-parsing the
// English string would couple the two forever, so the card renders from
// `code` + `detail` instead (see telegram/confirm-card.ts).
export type ReasonCode =
  | 'mode-off'
  | 'override-deny'
  | 'override-allow'
  | 'protected-file'
  | 'local-tool'
  | 'http-method'
  | 'url-verb'
  | 'bash-http-method'
  | 'bash-pattern'
  | 'plain-bash'
  | 'verb-destroy'
  | 'verb-mutate'
  | 'verb-read'
  | 'verb-unknown'

export type GateDecision = {
  action: 'allow' | 'confirm' | 'deny'
  reason: string
  cls: ToolClass
  code: ReasonCode
  detail: string
}

const READ_METHODS = new Set(['GET', 'HEAD', 'OPTIONS'])
const WRITE_METHODS = new Set(['POST', 'PUT', 'PATCH', 'DELETE'])

// The HTTP method is visible only inside a Bash command string. Explicit
// -X/--request wins; a body or upload flag without an explicit method
// implies one.
//
// The separator after the flag is optional, not required: `curl -XDELETE`
// glues the method to the flag and is the form people actually type. An
// unrecognised capture (`tar -Xf`) is dropped by the method tables below,
// so loosening the separator costs nothing.
export function httpMethodFromBash(command: string): string | null {
  const explicit = /(?:-X|--request)[=\s]*([A-Za-z]+)/.exec(command)
  if (explicit && explicit[1]) {
    const m = explicit[1].toUpperCase()
    if (READ_METHODS.has(m) || WRITE_METHODS.has(m)) return m
  }
  if (!/\bcurl\b/.test(command)) return null
  // `@` is a separator too: `curl -d@/tmp/body.json` reads the body from a
  // file and is a POST like any other.
  if (/(?:^|\s)(?:-d|--data|--data-raw|--data-binary|--data-urlencode|--data-ascii)(?:[=\s@])/
      .test(command)) {
    return 'POST'
  }
  // Multipart form upload is a POST; --upload-file is a PUT.
  if (/(?:^|\s)(?:-F|--form)(?:[=\s@])/.test(command)) return 'POST'
  if (/(?:^|\s)(?:-T|--upload-file)(?:[=\s@])/.test(command)) return 'PUT'
  return null
}

// Pull out anything shaped like a URL so the verb table can be applied to it
// alone. Trailing quotes and shell punctuation are stripped.
export function extractUrls(command: string): string[] {
  const matches = command.match(/[a-zA-Z][a-zA-Z0-9+.-]*:\/\/[^\s'"`;|&)]+/g)
  return matches === null ? [] : matches
}

// Static-asset suffixes. A URL ending in one of these is a download, not an
// RPC, so the verb table must not be run over it: `.../repo/main/update.sh`
// and `.../archive/dataset.zip` are everyday session traffic and were both
// prompting before this list existed. Business APIs that end in `.json`
// Rails-style are the accepted cost — they are still caught by the HTTP
// method and by confirm_patterns.
const ASSET_EXTENSIONS = new Set([
  'sh', 'bash', 'zip', 'tar', 'gz', 'tgz', 'bz2', 'xz', '7z', 'rar', 'iso',
  'deb', 'rpm', 'dmg', 'pkg', 'exe', 'bin', 'whl', 'jar', 'json', 'yaml',
  'yml', 'toml', 'txt', 'md', 'csv', 'tsv', 'xml', 'html', 'css', 'js',
  'mjs', 'ts', 'py', 'rb', 'go', 'png', 'jpg', 'jpeg', 'gif', 'svg', 'webp',
  'ico', 'pdf', 'docx', 'xlsx', 'pptx', 'mp3', 'mp4', 'wav', 'woff', 'woff2',
])

/**
 * The part of a URL a verb may legitimately live in: path, query, fragment.
 *
 * The scheme and host are dropped on purpose — a verb there is part of a
 * domain name (`update.example.com`), never an operation. Returns an empty
 * string when the URL points at a static asset, which switches the verb rule
 * off for that URL entirely.
 */
export function urlActionPart(url: string): string {
  const afterScheme = url.slice(url.indexOf('://') + 3)
  const slash = afterScheme.indexOf('/')
  if (slash === -1) return ''
  const rest = afterScheme.slice(slash)
  const path = rest.split(/[?#]/)[0] ?? ''
  const lastSegment = path.split('/').filter(seg => seg !== '').pop() ?? ''
  const dot = lastSegment.lastIndexOf('.')
  if (dot > 0 && ASSET_EXTENSIONS.has(lastSegment.slice(dot + 1).toLowerCase())) {
    return ''
  }
  return rest
}

export function decideGate(
  toolName: string,
  toolInput: Record<string, unknown>,
  policy: ConfirmPolicy,
): GateDecision {
  // 1. kill switch
  if (policy.mode === 'off') {
    return {
      action: 'allow', reason: 'gate disabled (mode: off)', cls: 'unknown',
      code: 'mode-off', detail: '',
    }
  }
  // 2. hard deny
  for (const p of policy.overrides.deny) {
    if (matchesGlob(toolName, p)) {
      return {
        action: 'deny', reason: `overrides.deny: ${p}`, cls: 'destroy',
        code: 'override-deny', detail: p,
      }
    }
  }
  // 3. explicit allow
  for (const p of policy.overrides.allow) {
    if (matchesGlob(toolName, p)) {
      return {
        action: 'allow', reason: `overrides.allow: ${p}`, cls: 'read',
        code: 'override-allow', detail: p,
      }
    }
  }
  // 3a. SCOPE. The gate exists for EXTERNAL integrations: MCP servers and
  // HTTP calls issued through Bash. Everything else a Claude Code session
  // does is local — reading files, editing code, spawning subagents — and
  // must pass untouched.
  //
  // This check has to come before the verb table, because the built-in tool
  // names collide with it head-on: Write/Edit/TodoWrite carry mutating verbs,
  // while Glob/Grep/Task carry no known verb at all and would fall into the
  // "unknown → ask" branch. Without this scope rule the gate would interrupt
  // every session, get switched off within a day, and protect nothing.
  if (!toolName.startsWith('mcp__') && toolName !== 'Bash') {
    // One exception: a write aimed at the gate's own configuration. Bash is
    // covered by confirm_patterns further down; the file-editing tools would
    // otherwise walk straight past and disable the gate in one call.
    const target =
      (typeof toolInput.file_path === 'string' ? toolInput.file_path : '')
      || (typeof toolInput.notebook_path === 'string' ? toolInput.notebook_path : '')
    if (target !== '') {
      // Segment equality, not substring: `settings.json` must not fire on
      // `/tmp/exported_settings.json.bak` or `src/settings.jsonc`. A prompt
      // nobody expects is how a gate earns its way to being switched off.
      const segments = target.toLowerCase().split('/').filter(seg => seg !== '')
      for (const p of policy.bash.confirmPatterns) {
        if (segments.includes(p.toLowerCase())) {
          return {
            action: 'confirm', reason: `write to protected file: ${p}`, cls: 'mutate',
            code: 'protected-file', detail: p,
          }
        }
      }
    }
    return {
      action: 'allow', reason: 'local tool, not an external integration', cls: 'read',
      code: 'local-tool', detail: '',
    }
  }

  // 4. declared HTTP method on a generic request tool.
  //
  // This field may only ESCALATE, never wave a call through. `method` is an
  // ordinary argument name and its value is chosen by whoever composed the
  // call — a destructive tool invoked with `{method: "GET"}` must still be
  // judged by its verb, or the gate is disabled by one extra argument.
  const declared = typeof toolInput.method === 'string' ? toolInput.method.toUpperCase() : null
  if (declared !== null) {
    if (READ_METHODS.has(declared) && classifyByVerb(toolName).cls === 'read') {
      return {
        action: 'allow', reason: `http method ${declared}`, cls: 'read',
        code: 'http-method', detail: declared,
      }
    }
    if (WRITE_METHODS.has(declared)) {
      const cls: ToolClass = declared === 'DELETE' ? 'destroy' : 'mutate'
      return {
        action: 'confirm', reason: `http method ${declared}`, cls,
        code: 'http-method', detail: declared,
      }
    }
  }
  // 5. Bash — only HTTP-shaped or explicitly listed commands are gated.
  if (toolName === 'Bash') {
    const command = typeof toolInput.command === 'string' ? toolInput.command : ''
    // 5a. Verb in the URL. Business APIs ignore REST semantics: Bitrix24
    // serves crm.deal.delete over GET, 1C HTTP services invent their own
    // conventions. Method alone would wave those through. Tokenize ONLY the
    // urls — running the verb table over the whole command would flag
    // `git add` on the verb "add" and bury the operator in prompts.
    for (const url of extractUrls(command)) {
      const action = urlActionPart(url)
      if (action === '') continue
      const v = classifyByVerb(action)
      if (v.cls === 'destroy' || v.cls === 'mutate') {
        return {
          action: 'confirm', reason: `url ${v.reason}`, cls: v.cls,
          code: 'url-verb', detail: v.detail,
        }
      }
    }
    const method = httpMethodFromBash(command)
    if (method !== null && WRITE_METHODS.has(method)) {
      const cls: ToolClass = method === 'DELETE' ? 'destroy' : 'mutate'
      return {
        action: 'confirm', reason: `bash http method ${method}`, cls,
        code: 'bash-http-method', detail: method,
      }
    }
    const lower = command.toLowerCase()
    for (const p of policy.bash.confirmPatterns) {
      if (lower.includes(p.toLowerCase())) {
        return {
          action: 'confirm', reason: `bash pattern "${p}"`, cls: 'mutate',
          code: 'bash-pattern', detail: p,
        }
      }
    }
    return {
      action: 'allow', reason: 'plain bash command', cls: 'read',
      code: 'plain-bash', detail: '',
    }
  }
  // 6/7. verb table; unknown verb confirms rather than passes.
  const verdict = classifyByVerb(toolName)
  if (verdict.cls === 'read') {
    return {
      action: 'allow', reason: verdict.reason, cls: 'read',
      code: verdict.code, detail: verdict.detail,
    }
  }
  return {
    action: 'confirm', reason: verdict.reason, cls: verdict.cls,
    code: verdict.code, detail: verdict.detail,
  }
}
