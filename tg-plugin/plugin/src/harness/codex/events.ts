// Перевод событий codex app-server в формат хуков Claude Code, который уже понимают
// StatusManager, ProgressReporter, TaskMirror и MemoryWriter.
//
// Так весь код статуса и прогресса в Telegram работает для обоих харнесов без изменений:
// у Claude события приходят хуками по HTTP, у Codex их рождает драйвер из потока app-server.
// Имена инструментов приводятся к тем, что знает отрисовщик (Bash, Edit, WebSearch, ...),
// иначе строка прогресса показала бы внутренние имена Codex.

/** Минимальная общая часть элемента нити app-server (ThreadItem). */
export interface CodexItem {
  type: string
  id: string
  [key: string]: unknown
}

/** Имя сервера MCP канала Telegram в config.toml агента. */
export const CHANNEL_SERVER_NAME = 'labops-channel'
/** Инструмент канала, которым агент отвечает оператору. */
export const REPLY_TOOL = 'reply'

/** Инструмент в терминах отрисовщика статуса. */
export interface MappedTool {
  toolName: string
  toolInput: Record<string, unknown>
}

function str(value: unknown): string {
  return typeof value === 'string' ? value : ''
}

function record(value: unknown): Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {}
}

/**
 * Сопоставить элемент нити инструменту для статуса.
 *
 * @param item Элемент из item/started или item/completed.
 * @returns Инструмент или undefined (сообщения, рассуждения и прочее — не инструменты).
 */
export function mapItemToTool(item: CodexItem): MappedTool | undefined {
  switch (item.type) {
    case 'commandExecution':
      return { toolName: 'Bash', toolInput: { command: str(item.command) } }
    case 'fileChange': {
      const changes = Array.isArray(item.changes) ? item.changes : []
      const first = record(changes[0])
      return { toolName: 'Edit', toolInput: { file_path: str(first.path) } }
    }
    case 'mcpToolCall':
      return {
        toolName: `mcp__${str(item.server)}__${str(item.tool)}`,
        toolInput: record(item.arguments),
      }
    case 'dynamicToolCall':
      return { toolName: str(item.tool) || 'tool', toolInput: record(item.arguments) }
    case 'webSearch':
      return { toolName: 'WebSearch', toolInput: { query: str(item.query) } }
    case 'imageView':
      return { toolName: 'Read', toolInput: { file_path: str(item.path) } }
    case 'collabAgentToolCall':
      return {
        toolName: 'Agent',
        toolInput: { description: str(item.prompt).slice(0, 80) },
      }
    default:
      return undefined
  }
}

/** Текст ответа, который агент отправил оператору инструментом reply, если это он. */
export function replyTextOf(item: CodexItem): { chatId: string; text: string } | undefined {
  if (item.type !== 'mcpToolCall') return undefined
  if (item.server !== CHANNEL_SERVER_NAME || item.tool !== REPLY_TOOL) return undefined
  const args = record(item.arguments)
  const text = str(args.text)
  if (text === '') return undefined
  return { chatId: String(args.chat_id ?? ''), text }
}

/** Нормализация для сравнения финального сообщения с уже отправленным reply. */
export function normalizeForDedup(text: string): string {
  return text.replace(/\s+/g, ' ').trim()
}

/** Общие поля полезной нагрузки хука. */
export interface HookContext {
  chatId: string
  threadId: string
  cwd: string
  /** Путь к журналу нити (rollout) — схема хука требует непустую строку. */
  transcriptPath: string
}

function common(ctx: HookContext): Record<string, unknown> {
  return {
    chatId: ctx.chatId,
    session_id: ctx.threadId,
    transcript_path: ctx.transcriptPath,
    cwd: ctx.cwd,
  }
}

/** PreToolUse / PostToolUse для элемента-инструмента. */
export function toolHook(
  phase: 'PreToolUse' | 'PostToolUse',
  item: CodexItem,
  ctx: HookContext,
): Record<string, unknown> | undefined {
  const tool = mapItemToTool(item)
  if (tool === undefined) return undefined
  const payload: Record<string, unknown> = {
    ...common(ctx),
    hook_event_name: phase,
    tool_name: tool.toolName,
    tool_use_id: item.id,
    tool_input: tool.toolInput,
  }
  if (phase === 'PostToolUse') {
    const failed = item.status === 'failed' || item.status === 'declined'
    payload.tool_result = failed ? { is_error: true } : { ok: true }
  }
  return payload
}

/** Шаг плана Codex (turn/plan/updated). */
export interface PlanStep {
  step: string
  status: string
}

const PLAN_STATUS: Record<string, 'pending' | 'in_progress' | 'completed'> = {
  pending: 'pending',
  inProgress: 'in_progress',
  completed: 'completed',
}

/** План Codex как TodoWrite — его рисует TaskMirror. */
export function planHook(plan: readonly PlanStep[], turnId: string, ctx: HookContext): Record<string, unknown> {
  return {
    ...common(ctx),
    hook_event_name: 'PostToolUse',
    tool_name: 'TodoWrite',
    tool_use_id: `plan-${turnId}`,
    tool_input: {
      todos: plan.map(s => ({ content: s.step, status: PLAN_STATUS[s.status] ?? 'pending' })),
    },
  }
}

/** UserPromptSubmit — начало хода (статус «думает»). Текст запроса в статус не попадает. */
export function promptHook(ctx: HookContext): Record<string, unknown> {
  return { ...common(ctx), hook_event_name: 'UserPromptSubmit', prompt: '' }
}

/** Stop — конец хода. */
export function stopHook(ctx: HookContext): Record<string, unknown> {
  return { ...common(ctx), hook_event_name: 'Stop' }
}

/** Последнее сообщение агента в элементах хода. */
export function lastAgentMessage(items: readonly unknown[]): string {
  for (let i = items.length - 1; i >= 0; i -= 1) {
    const item = record(items[i])
    if (item.type === 'agentMessage' && str(item.text).trim() !== '') return str(item.text)
  }
  return ''
}
