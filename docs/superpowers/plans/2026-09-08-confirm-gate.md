# Confirm Gate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** PreToolUse-хук удерживает изменяющий вызов стороннего MCP-инструмента (или HTTP-запрос через Bash) и пропускает его только после подтверждения оператором в Telegram.

**Architecture:** Классификация по глаголу в имени инструмента, а не по HTTP-методу — на уровне хука метода не видно. Хук синхронно POST-ит запрос плагину и блокирует вызов до вердикта, по образцу уже работающего `ask-user-question-hook.ts`. Все отказные пути fail-closed: нет политики, нет плагина, истёк таймаут — deny.

**Tech Stack:** Bun + TypeScript, grammy (Telegram), js-yaml (уже в зависимостях `plugin/package.json`), `bun test`.

**Spec:** `docs/superpowers/specs/2026-09-08-confirm-gate-spec.md`

## Global Constraints

- Рабочий каталог для всех путей: `/home/myaiagent/repos/labops-ai-assistant`
- Тесты плагина: `cd tg-plugin/plugin && bun test`. Перед первым запуском обязателен `bun install`, иначе около 30 тестов падают на отсутствующем `zod`.
- Тесты архитектуры: `bash agent-architecture/test.sh`
- Комментарии и имена — английский; коммиты — русский (глобальный CLAUDE.md)
- Хук ВСЕГДА завершается `exit 0`. Решение передаётся через stdout JSON; ненулевой код обрывает этот канал и жёстко блокирует вызов без внятного сигнала оператору.
- Формат вывода хука — ровно как в `scripts/ask-user-question-hook.ts:330-346`:
  `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}`
  либо `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"<текст>"}}`
  либо пустой stdout (passthrough).
- Bearer-токен плагина НИКОГДА не попадает в stdout/stderr и в `settings.json`.
- Hooks подхватываются только при старте сессии — после правки `settings.json` агента обязателен рестарт.

---

### Task 1: Токенизация имени инструмента и таблицы глаголов

**Files:**
- Create: `tg-plugin/plugin/src/safety/tool-classifier.ts`
- Test: `tg-plugin/plugin/tests/safety/tool-classifier.test.ts`

**Interfaces:**
- Consumes: ничего
- Produces:
  - `export type ToolClass = 'read' | 'mutate' | 'destroy' | 'unknown'`
  - `export function tokenizeToolName(toolName: string): string[]`
  - `export function classifyByVerb(toolName: string): { cls: ToolClass; reason: string }`

- [ ] **Step 1: Write the failing test**

```typescript
// tg-plugin/plugin/tests/safety/tool-classifier.test.ts
import { describe, expect, test } from 'bun:test'
import { tokenizeToolName, classifyByVerb } from '../../src/safety/tool-classifier.js'

describe('tokenizeToolName', () => {
  test('strips mcp__<server>__ prefix, server name may contain underscores', () => {
    expect(tokenizeToolName('mcp__claude_ai_Notion__notion-update-page'))
      .toEqual(['notion', 'update', 'page'])
  })

  test('splits camelCase', () => {
    expect(tokenizeToolName('mcp__gcal__deleteEvent')).toEqual(['delete', 'event'])
  })

  test('handles bare tool names without prefix', () => {
    expect(tokenizeToolName('Bash')).toEqual(['bash'])
  })

  test('splits on dots and hyphens', () => {
    expect(tokenizeToolName('mcp__x__calendar.events-delete'))
      .toEqual(['calendar', 'events', 'delete'])
  })
})

describe('classifyByVerb', () => {
  test('read verb passes', () => {
    expect(classifyByVerb('mcp__gsheets__list_rows').cls).toBe('read')
  })

  test('mutate verb', () => {
    expect(classifyByVerb('mcp__claude_ai_Notion__notion-update-page').cls).toBe('mutate')
  })

  test('destroy wins over read in the same name', () => {
    expect(classifyByVerb('mcp__crm__list_and_delete').cls).toBe('destroy')
  })

  test('exact token match only: "deleted" is not "delete"', () => {
    expect(classifyByVerb('mcp__crm__list_deleted_items').cls).toBe('read')
  })

  test('unknown verb is unknown, never read', () => {
    expect(classifyByVerb('mcp__firecrawl__scrape').cls).toBe('unknown')
  })

  test('reason names the matched token', () => {
    expect(classifyByVerb('mcp__crm__delete_deal').reason).toContain('delete')
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tg-plugin/plugin && bun test tests/safety/tool-classifier.test.ts`
Expected: FAIL — `Cannot find module '../../src/safety/tool-classifier.js'`

- [ ] **Step 3: Write minimal implementation**

```typescript
// tg-plugin/plugin/src/safety/tool-classifier.ts
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd tg-plugin/plugin && bun test tests/safety/tool-classifier.test.ts`
Expected: PASS, 10 tests

- [ ] **Step 5: Commit**

```bash
git add tg-plugin/plugin/src/safety/tool-classifier.ts tg-plugin/plugin/tests/safety/tool-classifier.test.ts
git commit -m "feat(safety): классификация вызова по глаголу в имени инструмента"
```

---

### Task 2: Загрузка и валидация политики (fail-closed)

**Files:**
- Create: `tg-plugin/plugin/src/safety/confirm-policy.ts`
- Test: `tg-plugin/plugin/tests/safety/confirm-policy.test.ts`

**Interfaces:**
- Consumes: `ToolClass` из Task 1
- Produces:
  - `export interface ConfirmPolicy { mode: 'enforce' | 'off'; overrides: { allow: string[]; deny: string[] }; bash: { confirmPatterns: string[] } }`
  - `export type PolicyLoadResult = { ok: true; policy: ConfirmPolicy } | { ok: false; reason: string }`
  - `export function loadConfirmPolicy(path: string): PolicyLoadResult`
  - `export function matchesGlob(value: string, pattern: string): boolean`

- [ ] **Step 1: Write the failing test**

```typescript
// tg-plugin/plugin/tests/safety/confirm-policy.test.ts
import { describe, expect, test } from 'bun:test'
import { mkdtempSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { loadConfirmPolicy, matchesGlob } from '../../src/safety/confirm-policy.js'

function writePolicy(body: string): string {
  const dir = mkdtempSync(join(tmpdir(), 'confirm-policy-'))
  const p = join(dir, 'confirm-policy.yaml')
  writeFileSync(p, body, 'utf8')
  return p
}

describe('loadConfirmPolicy — fail-closed', () => {
  test('missing file is an error, not an empty policy', () => {
    const r = loadConfirmPolicy('/nonexistent/confirm-policy.yaml')
    expect(r.ok).toBe(false)
    if (!r.ok) expect(r.reason).toContain('not found')
  })

  test('malformed yaml is an error', () => {
    const p = writePolicy('mode: enforce\n  bad indent: [')
    const r = loadConfirmPolicy(p)
    expect(r.ok).toBe(false)
  })

  test('unknown mode is an error', () => {
    const p = writePolicy('mode: maybe\n')
    const r = loadConfirmPolicy(p)
    expect(r.ok).toBe(false)
    if (!r.ok) expect(r.reason).toContain('mode')
  })

  test('valid policy loads with defaults for missing sections', () => {
    const p = writePolicy('mode: enforce\n')
    const r = loadConfirmPolicy(p)
    expect(r.ok).toBe(true)
    if (r.ok) {
      expect(r.policy.mode).toBe('enforce')
      expect(r.policy.overrides.allow).toEqual([])
      expect(r.policy.bash.confirmPatterns).toEqual([])
    }
  })

  test('full policy round-trips', () => {
    const p = writePolicy([
      'mode: enforce',
      'overrides:',
      '  allow: ["mcp__gbrain-*__*"]',
      '  deny: ["mcp__*__*bulk_delete*"]',
      'bash:',
      '  confirm_patterns: ["sudo ", "rm -rf"]',
    ].join('\n'))
    const r = loadConfirmPolicy(p)
    expect(r.ok).toBe(true)
    if (r.ok) {
      expect(r.policy.overrides.allow).toEqual(['mcp__gbrain-*__*'])
      expect(r.policy.overrides.deny).toEqual(['mcp__*__*bulk_delete*'])
      expect(r.policy.bash.confirmPatterns).toEqual(['sudo ', 'rm -rf'])
    }
  })
})

describe('matchesGlob', () => {
  test('star matches within a segment', () => {
    expect(matchesGlob('mcp__gbrain-memory__write', 'mcp__gbrain-*__*')).toBe(true)
  })

  test('non-matching server is rejected', () => {
    expect(matchesGlob('mcp__crm__write', 'mcp__gbrain-*__*')).toBe(false)
  })

  test('regex metacharacters in the pattern are literal', () => {
    expect(matchesGlob('a.b', 'a.b')).toBe(true)
    expect(matchesGlob('axb', 'a.b')).toBe(false)
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tg-plugin/plugin && bun test tests/safety/confirm-policy.test.ts`
Expected: FAIL — `Cannot find module '../../src/safety/confirm-policy.js'`

- [ ] **Step 3: Write minimal implementation**

```typescript
// tg-plugin/plugin/src/safety/confirm-policy.ts
// Policy file for the confirm gate. Fail-closed by construction: every
// load failure returns { ok: false } and the caller MUST deny. An empty
// or unreadable policy is never treated as "allow everything".

import { readFileSync } from 'node:fs'
import { load as yamlLoad } from 'js-yaml'

export interface ConfirmPolicy {
  readonly mode: 'enforce' | 'off'
  readonly overrides: { readonly allow: string[]; readonly deny: string[] }
  readonly bash: { readonly confirmPatterns: string[] }
}

export type PolicyLoadResult =
  | { ok: true; policy: ConfirmPolicy }
  | { ok: false; reason: string }

function asStringArray(v: unknown): string[] {
  if (!Array.isArray(v)) return []
  return v.filter((x): x is string => typeof x === 'string')
}

export function loadConfirmPolicy(path: string): PolicyLoadResult {
  let raw: string
  try {
    raw = readFileSync(path, 'utf8')
  } catch {
    return { ok: false, reason: `policy not found or unreadable: ${path}` }
  }

  let doc: unknown
  try {
    doc = yamlLoad(raw)
  } catch (err) {
    return {
      ok: false,
      reason: `policy yaml parse failed: ${err instanceof Error ? err.message : String(err)}`,
    }
  }
  if (doc === null || typeof doc !== 'object') {
    return { ok: false, reason: 'policy root is not a mapping' }
  }

  const d = doc as Record<string, unknown>
  const mode = d.mode
  if (mode !== 'enforce' && mode !== 'off') {
    return {
      ok: false,
      reason: `policy mode must be "enforce" or "off", got ${JSON.stringify(mode)}`,
    }
  }

  const overrides = (d.overrides ?? {}) as Record<string, unknown>
  const bash = (d.bash ?? {}) as Record<string, unknown>

  return {
    ok: true,
    policy: {
      mode,
      overrides: {
        allow: asStringArray(overrides.allow),
        deny: asStringArray(overrides.deny),
      },
      bash: { confirmPatterns: asStringArray(bash.confirm_patterns) },
    },
  }
}

// fnmatch-style glob: only `*` is special, everything else is literal.
export function matchesGlob(value: string, pattern: string): boolean {
  const parts = pattern.split('*').map(p => p.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'))
  return new RegExp(`^${parts.join('.*')}$`).test(value)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd tg-plugin/plugin && bun test tests/safety/confirm-policy.test.ts`
Expected: PASS, 8 tests

- [ ] **Step 5: Commit**

```bash
git add tg-plugin/plugin/src/safety/confirm-policy.ts tg-plugin/plugin/tests/safety/confirm-policy.test.ts
git commit -m "feat(safety): загрузка политики confirm-gate с fail-closed валидацией"
```

---

### Task 3: Полное решение — HTTP-метод, Bash, порядок правил

**Files:**
- Modify: `tg-plugin/plugin/src/safety/tool-classifier.ts` (дописать в конец)
- Test: `tg-plugin/plugin/tests/safety/tool-classifier.test.ts` (дописать новые `describe`)

**Interfaces:**
- Consumes: `classifyByVerb` (Task 1), `ConfirmPolicy` + `matchesGlob` (Task 2)
- Produces:
  - `export type GateDecision = { action: 'allow' | 'confirm' | 'deny'; reason: string; cls: ToolClass }`
  - `export function decideGate(toolName: string, toolInput: Record<string, unknown>, policy: ConfirmPolicy): GateDecision`
  - `export function httpMethodFromBash(command: string): string | null`
  - `export function extractUrls(command: string): string[]`

- [ ] **Step 1: Write the failing test**

```typescript
// дописать в tg-plugin/plugin/tests/safety/tool-classifier.test.ts
import { decideGate, httpMethodFromBash, extractUrls } from '../../src/safety/tool-classifier.js'
import type { ConfirmPolicy } from '../../src/safety/confirm-policy.js'

const POLICY: ConfirmPolicy = {
  mode: 'enforce',
  overrides: {
    allow: ['mcp__gbrain-*__*', 'mcp__firecrawl__*'],
    deny: ['mcp__*__*bulk_delete*'],
  },
  bash: { confirmPatterns: ['sudo ', 'rm -rf'] },
}

describe('httpMethodFromBash', () => {
  test('-X DELETE', () => expect(httpMethodFromBash('curl -X DELETE https://x')).toBe('DELETE'))
  test('--request PATCH', () => expect(httpMethodFromBash('curl --request PATCH https://x')).toBe('PATCH'))
  test('lowercase -X post', () => expect(httpMethodFromBash('curl -X post https://x')).toBe('POST'))
  test('-d without -X implies POST', () => expect(httpMethodFromBash("curl -d '{}' https://x")).toBe('POST'))
  test('plain GET curl has no method', () => expect(httpMethodFromBash('curl https://x')).toBeNull())
  test('non-http command has no method', () => expect(httpMethodFromBash('git status')).toBeNull())
})

describe('extractUrls', () => {
  test('pulls a quoted url out of a curl command', () => {
    expect(extractUrls("curl 'https://portal.bitrix24.ru/rest/1/tok/crm.deal.delete?ID=1'"))
      .toEqual(['https://portal.bitrix24.ru/rest/1/tok/crm.deal.delete?ID=1'])
  })
  test('command without a url yields nothing', () => {
    expect(extractUrls('git add .')).toEqual([])
  })
})

describe('decideGate — business APIs over Bash', () => {
  // Bitrix24 deletes over GET. A method-only rule would wave this through.
  test('destructive verb in a Bitrix24 GET url confirms', () => {
    const cmd = "curl 'https://portal.bitrix24.ru/rest/1/tok/crm.deal.delete?ID=1'"
    const d = decideGate('Bash', { command: cmd }, POLICY)
    expect(d.action).toBe('confirm')
    expect(d.cls).toBe('destroy')
  })

  test('mutating verb in an HH.ru url confirms', () => {
    const cmd = 'curl https://api.hh.ru/vacancies/create'
    expect(decideGate('Bash', { command: cmd }, POLICY).action).toBe('confirm')
  })

  test('read verb in a url passes', () => {
    const cmd = 'curl https://api.hh.ru/vacancies/list'
    expect(decideGate('Bash', { command: cmd }, POLICY).action).toBe('allow')
  })

  test('bare git command is not tokenized as a url — "add" must not confirm', () => {
    expect(decideGate('Bash', { command: 'git add .' }, POLICY).action).toBe('allow')
  })
})

describe('decideGate — precedence', () => {
  test('mode off short-circuits to allow', () => {
    const d = decideGate('mcp__crm__delete_deal', {}, { ...POLICY, mode: 'off' })
    expect(d.action).toBe('allow')
  })

  test('overrides.deny beats everything', () => {
    expect(decideGate('mcp__crm__bulk_delete_all', {}, POLICY).action).toBe('deny')
  })

  test('overrides.allow lets second brain through', () => {
    expect(decideGate('mcp__gbrain-memory__write_note', {}, POLICY).action).toBe('allow')
  })

  test('tool_input.method wins over the verb', () => {
    const d = decideGate('mcp__api__fetch', { method: 'DELETE' }, POLICY)
    expect(d.action).toBe('confirm')
    expect(d.reason).toContain('DELETE')
  })

  test('tool_input.method GET allows despite unknown verb', () => {
    expect(decideGate('mcp__api__fetch', { method: 'GET' }, POLICY).action).toBe('allow')
  })

  test('plain bash passes untouched', () => {
    expect(decideGate('Bash', { command: 'git status' }, POLICY).action).toBe('allow')
  })

  test('bash with DELETE confirms', () => {
    expect(decideGate('Bash', { command: 'curl -X DELETE https://api' }, POLICY).action).toBe('confirm')
  })

  test('bash confirm_patterns confirm', () => {
    expect(decideGate('Bash', { command: 'sudo systemctl stop x' }, POLICY).action).toBe('confirm')
  })

  test('read verb allows', () => {
    expect(decideGate('mcp__gsheets__list_rows', {}, POLICY).action).toBe('allow')
  })

  test('unknown verb confirms, never allows', () => {
    expect(decideGate('mcp__newcrm__frobnicate', {}, POLICY).action).toBe('confirm')
  })

  test('destroy verb confirms', () => {
    expect(decideGate('mcp__gcal__deleteEvent', {}, POLICY).action).toBe('confirm')
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tg-plugin/plugin && bun test tests/safety/tool-classifier.test.ts`
Expected: FAIL — `decideGate is not a function`

- [ ] **Step 3: Write minimal implementation**

```typescript
// дописать в конец tg-plugin/plugin/src/safety/tool-classifier.ts
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd tg-plugin/plugin && bun test tests/safety/tool-classifier.test.ts`
Expected: PASS, 33 tests

- [ ] **Step 5: Commit**

```bash
git add tg-plugin/plugin/src/safety/tool-classifier.ts tg-plugin/plugin/tests/safety/tool-classifier.test.ts
git commit -m "feat(safety): порядок правил гейта, HTTP-метод и разбор Bash"
```

---

### Task 4: Карточка подтверждения в Telegram

**Files:**
- Create: `tg-plugin/plugin/src/telegram/confirm-card.ts`
- Test: `tg-plugin/plugin/tests/telegram/confirm-card.test.ts`

**Interfaces:**
- Consumes: `GateDecision` (Task 3); `InlineKeyboardLike` из `src/channel/tools.js`
- Produces:
  - `export function newConfirmId(): string`
  - `export function renderConfirmCard(toolName: string, decision: GateDecision, inputPreview: string, requestId?: string): { text: string; replyMarkup: InlineKeyboardLike; requestId: string }`
  - `export function parseConfirmCallback(data: string): { behavior: 'allow' | 'deny' | 'more'; requestId: string } | null`

- [ ] **Step 1: Write the failing test**

```typescript
// tg-plugin/plugin/tests/telegram/confirm-card.test.ts
import { describe, expect, test } from 'bun:test'
import { renderConfirmCard, parseConfirmCallback } from '../../src/telegram/confirm-card.js'
import type { GateDecision } from '../../src/safety/tool-classifier.js'

const DESTROY: GateDecision = {
  action: 'confirm',
  reason: 'destructive verb "delete"',
  cls: 'destroy',
}

describe('renderConfirmCard', () => {
  test('names the tool and the reason', () => {
    const c = renderConfirmCard('mcp__crm__delete_deal', DESTROY, '{"id":42}')
    expect(c.text).toContain('mcp__crm__delete_deal')
    expect(c.text).toContain('delete')
  })

  test('keyboard carries confirm/deny/more callbacks', () => {
    const c = renderConfirmCard('mcp__crm__delete_deal', DESTROY, '{}')
    const data = c.replyMarkup.inline_keyboard.flat().map(b => b.callback_data)
    expect(data.some(d => d?.startsWith('confirm:allow:'))).toBe(true)
    expect(data.some(d => d?.startsWith('confirm:deny:'))).toBe(true)
    expect(data.some(d => d?.startsWith('confirm:more:'))).toBe(true)
  })

  test('callback ids match the returned requestId', () => {
    const c = renderConfirmCard('mcp__crm__delete_deal', DESTROY, '{}')
    expect(c.replyMarkup.inline_keyboard[0]?.[1]?.callback_data)
      .toBe(`confirm:allow:${c.requestId}`)
  })

  test('escapes HTML in the tool name', () => {
    const c = renderConfirmCard('mcp__x__<b>evil</b>', DESTROY, '{}')
    expect(c.text).not.toContain('<b>evil')
  })
})

describe('parseConfirmCallback', () => {
  test('parses allow', () => {
    expect(parseConfirmCallback('confirm:allow:abcde'))
      .toEqual({ behavior: 'allow', requestId: 'abcde' })
  })
  test('rejects the permission relay namespace', () => {
    expect(parseConfirmCallback('perm:allow:abcde')).toBeNull()
  })
  test('rejects a malformed id', () => {
    expect(parseConfirmCallback('confirm:allow:TOOLONGID')).toBeNull()
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tg-plugin/plugin && bun test tests/telegram/confirm-card.test.ts`
Expected: FAIL — `Cannot find module '../../src/telegram/confirm-card.js'`

- [ ] **Step 3: Write minimal implementation**

```typescript
// tg-plugin/plugin/src/telegram/confirm-card.ts
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
  const mark = decision.cls === 'destroy' ? 'DESTRUCTIVE' : 'CHANGE'
  const text =
    `<b>${mark} — подтверди операцию</b>\n\n`
    + `инструмент: <code>${escapeHtml(toolName)}</code>\n`
    + `причина: ${escapeHtml(decision.reason)}\n`
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd tg-plugin/plugin && bun test tests/telegram/confirm-card.test.ts`
Expected: PASS, 7 tests

- [ ] **Step 5: Commit**

```bash
git add tg-plugin/plugin/src/telegram/confirm-card.ts tg-plugin/plugin/tests/telegram/confirm-card.test.ts
git commit -m "feat(telegram): карточка подтверждения операции с инлайн-кнопками"
```

---

### Task 5: Реестр ожидающих подтверждений и роут плагина

**Files:**
- Create: `tg-plugin/plugin/src/webhook/confirm-route.ts`
- Modify: `tg-plugin/plugin/src/webhook/server.ts:322-338` (регистрация роута рядом с `/hooks/ask-user-question/request`)
- Test: `tg-plugin/plugin/tests/webhook/confirm-route.test.ts`

**Interfaces:**
- Consumes: `newConfirmId` (Task 4), `GateDecision` (Task 3)
- Produces:
  - `export interface PendingConfirmEntry { toolName: string; decision: GateDecision; inputPreview: string }`
  - `export interface ConfirmRegistry { create(toolName, decision, inputPreview): { requestId: string; wait: Promise<'allow' | 'deny'> }; settle(requestId, behavior): boolean; get(requestId): PendingConfirmEntry | undefined }`
  - `export function createConfirmRegistry(timeoutMs: number): ConfirmRegistry`

- [ ] **Step 1: Write the failing test**

```typescript
// tg-plugin/plugin/tests/webhook/confirm-route.test.ts
import { describe, expect, test } from 'bun:test'
import { createConfirmRegistry } from '../../src/webhook/confirm-route.js'
import type { GateDecision } from '../../src/safety/tool-classifier.js'

const D: GateDecision = { action: 'confirm', reason: 'destructive verb "delete"', cls: 'destroy' }

describe('createConfirmRegistry', () => {
  test('settle(allow) resolves the waiter', async () => {
    const reg = createConfirmRegistry(5000)
    const { requestId, wait } = reg.create('mcp__crm__delete_deal', D, '{}')
    expect(reg.settle(requestId, 'allow')).toBe(true)
    expect(await wait).toBe('allow')
  })

  test('settle(deny) resolves deny', async () => {
    const reg = createConfirmRegistry(5000)
    const { requestId, wait } = reg.create('mcp__crm__delete_deal', D, '{}')
    reg.settle(requestId, 'deny')
    expect(await wait).toBe('deny')
  })

  test('timeout resolves deny, never allow', async () => {
    const reg = createConfirmRegistry(30)
    const { wait } = reg.create('mcp__crm__delete_deal', D, '{}')
    expect(await wait).toBe('deny')
  })

  test('settling twice is a no-op', async () => {
    const reg = createConfirmRegistry(5000)
    const { requestId, wait } = reg.create('mcp__crm__delete_deal', D, '{}')
    expect(reg.settle(requestId, 'allow')).toBe(true)
    expect(reg.settle(requestId, 'deny')).toBe(false)
    expect(await wait).toBe('allow')
  })

  test('unknown id cannot be settled', () => {
    const reg = createConfirmRegistry(5000)
    expect(reg.settle('zzzzz', 'allow')).toBe(false)
  })

  test('entry is retrievable for the "more" button until settled', () => {
    const reg = createConfirmRegistry(5000)
    const { requestId } = reg.create('mcp__crm__delete_deal', D, '{"id":42}')
    expect(reg.get(requestId)?.inputPreview).toBe('{"id":42}')
    reg.settle(requestId, 'deny')
    expect(reg.get(requestId)).toBeUndefined()
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tg-plugin/plugin && bun test tests/webhook/confirm-route.test.ts`
Expected: FAIL — `Cannot find module '../../src/webhook/confirm-route.js'`

- [ ] **Step 3: Write minimal implementation**

```typescript
// tg-plugin/plugin/src/webhook/confirm-route.ts
// Pending-confirmation registry. One entry per held tool call: the HTTP
// handler awaits `wait`, the Telegram callback calls `settle`.
//
// The timeout resolves to 'deny', never 'allow' — a confirmation nobody
// answered is not a confirmation.

import { newConfirmId } from '../telegram/confirm-card.js'
import type { GateDecision } from '../safety/tool-classifier.js'

export interface PendingConfirmEntry {
  readonly toolName: string
  readonly decision: GateDecision
  readonly inputPreview: string
}

export interface ConfirmRegistry {
  create(
    toolName: string,
    decision: GateDecision,
    inputPreview: string,
  ): { requestId: string; wait: Promise<'allow' | 'deny'> }
  settle(requestId: string, behavior: 'allow' | 'deny'): boolean
  get(requestId: string): PendingConfirmEntry | undefined
}

interface Slot extends PendingConfirmEntry {
  settle(behavior: 'allow' | 'deny'): void
  timer: ReturnType<typeof setTimeout>
}

export function createConfirmRegistry(timeoutMs: number): ConfirmRegistry {
  const slots = new Map<string, Slot>()

  return {
    create(toolName, decision, inputPreview) {
      let requestId = newConfirmId()
      while (slots.has(requestId)) requestId = newConfirmId()

      let settleFn: (v: 'allow' | 'deny') => void = () => {}
      const wait = new Promise<'allow' | 'deny'>(resolve => {
        settleFn = resolve
      })
      const timer = setTimeout(() => {
        const slot = slots.get(requestId)
        if (slot) {
          slots.delete(requestId)
          slot.settle('deny')
        }
      }, timeoutMs)
      slots.set(requestId, { toolName, decision, inputPreview, settle: settleFn, timer })
      return { requestId, wait }
    },

    settle(requestId, behavior) {
      const slot = slots.get(requestId)
      if (!slot) return false
      clearTimeout(slot.timer)
      slots.delete(requestId)
      slot.settle(behavior)
      return true
    },

    get(requestId) {
      return slots.get(requestId)
    },
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd tg-plugin/plugin && bun test tests/webhook/confirm-route.test.ts`
Expected: PASS, 6 tests

- [ ] **Step 5: Wire the HTTP route**

В `src/webhook/server.ts` перед веткой `/hooks/agent` (рядом со строками 322-331) добавить:

```typescript
if (method === 'POST' && path === '/hooks/confirm/request') {
  return await handleConfirmRequest(req, deps)
}
```

`handleConfirmRequest` разбирает тело `{ tool_name, tool_input }`, загружает политику через `loadConfirmPolicy`. При `{ ok: false }` — немедленно `{"status":"deny","reason":"<причина загрузки>"}` (fail-closed). Иначе считает `decideGate`:
- `allow` — сразу `{"status":"allow"}`
- `deny` — сразу `{"status":"deny","reason":...}`
- `confirm` — `registry.create(...)`, рассылка карточки всем `config.permission_relay.allowed_user_ids` через `telegramApi.sendMessage(chatId, text, { parse_mode: 'HTML', reply_markup })`, затем `await wait` и ответ `{"status":"allow"}` либо `{"status":"deny","reason":"отклонено оператором"}`.

- [ ] **Step 6: Wire the Telegram callback**

В обработчике `callback_query:data` (там же, где `registerPermissionCallback`) добавить ветку: `parseConfirmCallback(data)` → при непустом результате проверить `isPermissionApprover(ctx.from.id, config)` из `src/channel/permissions.js`, при отказе — `answerCallbackQuery({ text: 'Not authorized.' })`. Для `more` — показать `registry.get(requestId)?.inputPreview` в pretty-JSON. Для `allow`/`deny` — `registry.settle(...)` и `editMessageText` с итогом.

Каждый вердикт дописывать строкой в append-only jsonl рядом с `statePaths.logs.permissions`.

- [ ] **Step 7: Run the full plugin suite**

Run: `cd tg-plugin/plugin && bun test`
Expected: PASS, регрессий нет

- [ ] **Step 8: Commit**

```bash
git add tg-plugin/plugin/src/webhook/ tg-plugin/plugin/src/telegram/ tg-plugin/plugin/tests/webhook/confirm-route.test.ts
git commit -m "feat(webhook): роут /hooks/confirm/request с удержанием вызова до вердикта"
```

---

### Task 6: Хук-обёртка `confirm-hook.ts`

**Files:**
- Create: `tg-plugin/plugin/scripts/confirm-hook.ts`
- Test: `tg-plugin/plugin/tests/hooks/confirm-hook.test.ts`
- Reference: `tg-plugin/plugin/scripts/ask-user-question-hook.ts` — тот же каркас

**Interfaces:**
- Consumes: роут из Task 5
- Produces:
  - `export type HookDecision = { kind: 'allow' } | { kind: 'deny'; reason: string } | { kind: 'passthrough' }`
  - `export function decisionFromResponse(status: unknown, reason?: string): HookDecision`
  - `export function renderHookStdout(decision: HookDecision): string`

- [ ] **Step 1: Write the failing test**

```typescript
// tg-plugin/plugin/tests/hooks/confirm-hook.test.ts
import { describe, expect, test } from 'bun:test'
import { decisionFromResponse, renderHookStdout } from '../../scripts/confirm-hook.js'

describe('decisionFromResponse — fail-closed', () => {
  test('allow', () => expect(decisionFromResponse('allow')).toEqual({ kind: 'allow' }))

  test('deny carries the reason', () => {
    expect(decisionFromResponse('deny', 'отклонено оператором'))
      .toEqual({ kind: 'deny', reason: 'отклонено оператором' })
  })

  test('timeout denies', () => {
    expect(decisionFromResponse('timeout').kind).toBe('deny')
  })

  test('unknown status denies, never allows', () => {
    expect(decisionFromResponse('banana').kind).toBe('deny')
  })

  test('undefined status denies', () => {
    expect(decisionFromResponse(undefined).kind).toBe('deny')
  })
})

describe('renderHookStdout', () => {
  test('allow emits permissionDecision allow', () => {
    expect(JSON.parse(renderHookStdout({ kind: 'allow' }))).toEqual({
      hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'allow' },
    })
  })

  test('deny carries a human-readable reason', () => {
    const out = JSON.parse(renderHookStdout({ kind: 'deny', reason: 'таймаут' }))
    expect(out.hookSpecificOutput.permissionDecision).toBe('deny')
    expect(out.hookSpecificOutput.permissionDecisionReason).toBe('таймаут')
  })

  test('passthrough emits empty stdout', () => {
    expect(renderHookStdout({ kind: 'passthrough' })).toBe('')
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tg-plugin/plugin && bun test tests/hooks/confirm-hook.test.ts`
Expected: FAIL — `Cannot find module '../../scripts/confirm-hook.js'`

- [ ] **Step 3: Write minimal implementation**

```typescript
#!/usr/bin/env bun
// tg-plugin/plugin/scripts/confirm-hook.ts
// PreToolUse hook: holds a mutating tool call until the operator confirms it
// in Telegram. Structural twin of ask-user-question-hook.ts, with ONE
// deliberate difference — this hook is fail-CLOSED. Where the question hook
// falls back to Claude's native UI when the plugin is unreachable, this one
// denies: an unreachable plugin must never turn into a silent approval.
//
// Always exits 0; the verdict travels on stdout.

export type HookDecision =
  | { kind: 'allow' }
  | { kind: 'deny'; reason: string }
  | { kind: 'passthrough' }

export function decisionFromResponse(status: unknown, reason?: string): HookDecision {
  if (status === 'allow') return { kind: 'allow' }
  if (status === 'deny') return { kind: 'deny', reason: reason ?? 'отклонено оператором' }
  if (status === 'timeout') {
    return { kind: 'deny', reason: 'таймаут подтверждения — вызов заблокирован' }
  }
  return { kind: 'deny', reason: `непонятный ответ плагина: ${JSON.stringify(status)}` }
}

export function renderHookStdout(decision: HookDecision): string {
  if (decision.kind === 'passthrough') return ''
  if (decision.kind === 'allow') {
    return JSON.stringify({
      hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'allow' },
    })
  }
  return JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'deny',
      permissionDecisionReason: decision.reason,
    },
  })
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd tg-plugin/plugin && bun test tests/hooks/confirm-hook.test.ts`
Expected: PASS, 8 tests

- [ ] **Step 5: Add the main() wiring**

Дописать `main()` по образцу `ask-user-question-hook.ts:350-400`: прочитать stdin, распарсить конверт PreToolUse; при `CONFIRM_GATE=off` вернуть `passthrough`; POST на `process.env.CONFIRM_WEBHOOK_URL` с заголовком `Authorization: Bearer ${process.env.TELEGRAM_WEBHOOK_TOKEN}` и телом `{ tool_name, tool_input }`; сетевая ошибка или не-2xx → `{ kind: 'deny', reason: 'плагин недоступен — вызов заблокирован' }`; иначе `decisionFromResponse(body.status, body.reason)`. Токен не логировать ни при какой ошибке. Финал: `process.stdout.write(renderHookStdout(d))`, `process.exit(0)`.

- [ ] **Step 6: Commit**

```bash
git add tg-plugin/plugin/scripts/confirm-hook.ts tg-plugin/plugin/tests/hooks/confirm-hook.test.ts
git commit -m "feat(hooks): fail-closed PreToolUse-хук подтверждения операций"
```

---

### Task 7: Конфиги, регистрация, страж в self-test, документация

**Files:**
- Create: `tg-plugin/examples/confirm-policy.example.yaml`
- Create: `tg-plugin/examples/settings.confirm-gate.example.json`
- Create: `tg-plugin/docs/confirm-gate.md`
- Modify: `agent-architecture/test.sh` (добавить блок проверок в конец)

**Interfaces:**
- Consumes: всё предыдущее
- Produces: рабочую установку

- [ ] **Step 1: Write the policy example**

```yaml
# tg-plugin/examples/confirm-policy.example.yaml
# Политика confirm-gate. Копируется в
# ~/.claude-lab/<agent>/.claude/confirm-policy.yaml
#
# enforce — гейт работает; off — аварийный рубильник (нужен рестарт агента).
mode: enforce

overrides:
  # Только собственная инфраструктура и читающие утилиты.
  # Бизнес-интеграции клиента (1С, amoCRM, Bitrix24, Teamly, Yandex Tracker,
  # Yandex Disk, HH.ru и последующие) сюда НЕ добавляются: они и есть то,
  # ради чего существует гейт.
  allow:
    - "mcp__second_brain-*__*"
    - "mcp__gbrain-*__*"
    - "mcp__firecrawl__*"
  # Никогда, даже с подтверждением: массовое удаление в CRM.
  deny:
    - "mcp__*__*bulk_delete*"
    - "mcp__*__*delete_all*"

bash:
  # Подстрока, без учёта регистра. HTTP-методы (-X DELETE и подобные)
  # ловятся кодом отдельно, здесь их дублировать не нужно.
  confirm_patterns:
    - "sudo "
    - "rm -rf"
    - "drop table"
    # Правка самой политики и настроек агента — тоже под подтверждение:
    # иначе гейт снимается одной командой Bash.
    - "confirm-policy.yaml"
    - "settings.json"
```

- [ ] **Step 2: Write the settings example**

```json
{
  "_comment_1": "PreToolUse hook confirm-gate: удерживает изменяющий вызов до подтверждения в Telegram.",
  "_comment_2": "Замени <repo> на абсолютный путь к монорепо, <port> на порт плагина из его config.json.",
  "_comment_3": "TELEGRAM_WEBHOOK_TOKEN и CONFIRM_GATE задаются в env сессии агента, НЕ здесь.",
  "_comment_4": "Timeout 310 = 300с ожидания оператора + 5с маржа обёртки + 5с маржа Claude Code.",
  "_comment_5": "matcher '*' обязателен: гейт должен видеть все инструменты, включая ещё не подключённые MCP.",
  "_comment_6": "Маркер labops-channel-confirm-gate позволяет install-hooks.sh обновлять запись идемпотентно.",
  "hooks": {
    "PreToolUse": [
      {
        "marker": "labops-channel-confirm-gate",
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "CONFIRM_WEBHOOK_URL='http://127.0.0.1:<port>/hooks/confirm/request' bun '<repo>/tg-plugin/plugin/scripts/confirm-hook.ts'",
            "timeout": 310
          }
        ]
      }
    ]
  }
}
```

- [ ] **Step 3: Add the self-test guard**

```bash
# дописать в конец agent-architecture/test.sh
echo "── 20. Confirm-gate установлен и политика валидна ──"
if [ -f "../tg-plugin/plugin/scripts/confirm-hook.ts" ] \
   || [ -f "tg-plugin/plugin/scripts/confirm-hook.ts" ]; then
  ok "confirm-hook.ts на месте"
else
  bad "confirm-hook.ts отсутствует — гейт не установлен, изменяющие вызовы проходят молча"
fi
# Политика обязана парситься: при ошибке гейт fail-closed заблокирует ВСЁ.
POLICY_PATH="$(ls ../tg-plugin/examples/confirm-policy.example.yaml \
                  tg-plugin/examples/confirm-policy.example.yaml 2>/dev/null | head -1)"
if [ -n "$POLICY_PATH" ] && python3 -c "
import sys, yaml
d = yaml.safe_load(open('$POLICY_PATH'))
sys.exit(0 if isinstance(d, dict) and d.get('mode') in ('enforce', 'off') else 1)
" 2>/dev/null; then
  ok "confirm-policy.example.yaml парсится, mode валиден"
else
  bad "confirm-policy.example.yaml не парсится или mode неверный"
fi
```

- [ ] **Step 4: Run both suites**

Run: `bash agent-architecture/test.sh && cd tg-plugin/plugin && bun test`
Expected: обе PASS

- [ ] **Step 5: Write the doc**

`tg-plugin/docs/confirm-gate.md` — разделы: что гейтится и что нет; порядок правил (7 пунктов из спеки); как читать карточку; как добавить исключение в `overrides.allow`; как выключить (`CONFIRM_GATE=off` плюс рестарт сессии); почему таймаут означает отказ; граница защиты (гейт от ошибок, не от намеренного обхода).

- [ ] **Step 6: Commit**

```bash
git add tg-plugin/examples/ tg-plugin/docs/confirm-gate.md agent-architecture/test.sh
git commit -m "feat(confirm-gate): примеры конфигов, страж в self-test и документация"
```

---

## Порядок боевого включения

1. Установить на ОДНОГО агента — `marketer`.
2. Рестарт сессии: хуки читаются только при старте.
3. Проверить, что обычная работа не встала — попросить агента сделать что-нибудь читающее плюс `git status`.
4. Проверить срабатывание по методу: `curl -X DELETE https://example.invalid/x` — должна прийти карточка.
5. Проверить срабатывание по глаголу в URL (главный сценарий для Bitrix24 и 1С):
   `curl 'https://example.invalid/rest/1/tok/crm.deal.delete?ID=1'` — метод GET, карточка обязана прийти.
6. Проверить отказ: нажать «Отклонить», убедиться, что агент получил внятную причину, а не молчание.
7. Проверить таймаут: не отвечать 5 минут, убедиться, что вызов заблокирован, а сессия жива.
8. Раскатить на `arthas`, `elpablo`, `inbox-agent`.

При подключении каждой новой бизнес-интеграции — прогнать по ней шаги 4-5 до того, как
агент получит к ней боевой доступ.

Откат: `CONFIRM_GATE=off` в окружении сессии плюс рестарт.
