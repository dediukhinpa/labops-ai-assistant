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

export function classifyByVerb(toolName: string): { cls: ToolClass; reason: string } {
  const tokens = tokenizeToolName(toolName)
  for (const t of tokens) {
    if (DESTROY_VERBS.has(t)) return { cls: 'destroy', reason: `destructive verb "${t}"` }
  }
  for (const t of tokens) {
    if (MUTATE_VERBS.has(t)) return { cls: 'mutate', reason: `mutating verb "${t}"` }
  }
  for (const t of tokens) {
    if (READ_VERBS.has(t)) return { cls: 'read', reason: `read-only verb "${t}"` }
  }
  return { cls: 'unknown', reason: 'no known verb in tool name' }
}

// ─────────────────────────────────────────────────────────────────────
// Full gate decision. Precedence is the contract — see
// docs/superpowers/specs/2026-09-08-confirm-gate-spec.md.
// ─────────────────────────────────────────────────────────────────────

import type { ConfirmPolicy } from './confirm-policy.js'
import { matchesGlob } from './confirm-policy.js'

export type GateDecision = {
  action: 'allow' | 'confirm' | 'deny'
  reason: string
  cls: ToolClass
}

const READ_METHODS = new Set(['GET', 'HEAD', 'OPTIONS'])
const WRITE_METHODS = new Set(['POST', 'PUT', 'PATCH', 'DELETE'])

// The HTTP method is visible only inside a Bash command string. Explicit
// -X/--request wins; a body flag without an explicit method means POST.
export function httpMethodFromBash(command: string): string | null {
  const explicit = /(?:-X|--request)[=\s]+([A-Za-z]+)/.exec(command)
  if (explicit && explicit[1]) {
    const m = explicit[1].toUpperCase()
    if (READ_METHODS.has(m) || WRITE_METHODS.has(m)) return m
  }
  if (/\bcurl\b/.test(command)
      && /(?:^|\s)(?:-d|--data|--data-raw|--data-binary)(?:[=\s])/.test(command)) {
    return 'POST'
  }
  return null
}

// Pull out anything shaped like a URL so the verb table can be applied to it
// alone. Trailing quotes and shell punctuation are stripped.
export function extractUrls(command: string): string[] {
  const matches = command.match(/[a-zA-Z][a-zA-Z0-9+.-]*:\/\/[^\s'"`;|&)]+/g)
  return matches === null ? [] : matches
}

export function decideGate(
  toolName: string,
  toolInput: Record<string, unknown>,
  policy: ConfirmPolicy,
): GateDecision {
  // 1. kill switch
  if (policy.mode === 'off') {
    return { action: 'allow', reason: 'gate disabled (mode: off)', cls: 'unknown' }
  }
  // 2. hard deny
  for (const p of policy.overrides.deny) {
    if (matchesGlob(toolName, p)) {
      return { action: 'deny', reason: `overrides.deny: ${p}`, cls: 'destroy' }
    }
  }
  // 3. explicit allow
  for (const p of policy.overrides.allow) {
    if (matchesGlob(toolName, p)) {
      return { action: 'allow', reason: `overrides.allow: ${p}`, cls: 'read' }
    }
  }
  // 4. declared HTTP method on a generic request tool
  const declared = typeof toolInput.method === 'string' ? toolInput.method.toUpperCase() : null
  if (declared !== null) {
    if (READ_METHODS.has(declared)) {
      return { action: 'allow', reason: `http method ${declared}`, cls: 'read' }
    }
    if (WRITE_METHODS.has(declared)) {
      const cls: ToolClass = declared === 'DELETE' ? 'destroy' : 'mutate'
      return { action: 'confirm', reason: `http method ${declared}`, cls }
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
      const v = classifyByVerb(url)
      if (v.cls === 'destroy' || v.cls === 'mutate') {
        return { action: 'confirm', reason: `url ${v.reason}`, cls: v.cls }
      }
    }
    const method = httpMethodFromBash(command)
    if (method !== null && WRITE_METHODS.has(method)) {
      const cls: ToolClass = method === 'DELETE' ? 'destroy' : 'mutate'
      return { action: 'confirm', reason: `bash http method ${method}`, cls }
    }
    const lower = command.toLowerCase()
    for (const p of policy.bash.confirmPatterns) {
      if (lower.includes(p.toLowerCase())) {
        return { action: 'confirm', reason: `bash pattern "${p}"`, cls: 'mutate' }
      }
    }
    return { action: 'allow', reason: 'plain bash command', cls: 'read' }
  }
  // 6/7. verb table; unknown verb confirms rather than passes.
  const verdict = classifyByVerb(toolName)
  if (verdict.cls === 'read') {
    return { action: 'allow', reason: verdict.reason, cls: 'read' }
  }
  return { action: 'confirm', reason: verdict.reason, cls: verdict.cls }
}
