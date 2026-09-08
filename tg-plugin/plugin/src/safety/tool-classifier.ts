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
