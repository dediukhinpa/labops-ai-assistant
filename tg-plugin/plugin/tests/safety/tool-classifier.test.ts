// Tests for the confirm-gate tool classifier.
//
// The gate decides whether a tool call may proceed silently, must be
// confirmed by the operator in Telegram, or is refused outright. The
// primary signal is the verb inside the tool name — the one thing every
// MCP vendor exposes — because the HTTP method is invisible at the
// PreToolUse layer.

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

// ─────────────────────────────────────────────────────────────────────
// Full gate decision: precedence, declared HTTP method, Bash.
// ─────────────────────────────────────────────────────────────────────

import {
  decideGate, httpMethodFromBash, extractUrls, urlActionPart,
} from '../../src/safety/tool-classifier.js'
import type { ConfirmPolicy } from '../../src/safety/confirm-policy.js'

// Mirrors examples/confirm-policy.example.yaml — the policy new agents are
// installed with. Keeping the fixture identical to the shipped default is the
// point: these tests answer "what happens on a real agent", not "what happens
// under a fixture invented to make them pass".
const POLICY: ConfirmPolicy = {
  mode: 'enforce',
  overrides: {
    allow: ['mcp__second_brain-*__*', 'mcp__gbrain-*__*', 'mcp__firecrawl__*'],
    deny: ['mcp__*__*bulk_delete*', 'mcp__*__*delete_all*'],
  },
  bash: {
    confirmPatterns: [
      'sudo ', 'rm -rf', 'drop table', 'truncate table',
      'confirm-policy.yaml', 'settings.json',
    ],
  },
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

// ─────────────────────────────────────────────────────────────────────
// No false positives on ordinary session traffic.
//
// The gate exists for external business integrations. Everything a Claude
// Code session does locally — reading files, editing code, running git,
// spawning subagents — must pass untouched. A gate that interrupts normal
// work gets switched off within a day, and then it protects nothing.
// ─────────────────────────────────────────────────────────────────────

describe('decideGate — built-in tools never prompt', () => {
  // Note the traps: Write/Edit/TodoWrite carry mutating verbs, and
  // Glob/Grep/Task carry no known verb at all. Both would prompt if the
  // gate did not scope itself to mcp__* and Bash first.
  const BUILTINS = [
    'Read', 'Write', 'Edit', 'MultiEdit', 'NotebookEdit', 'Glob', 'Grep',
    'Task', 'TodoWrite', 'WebFetch', 'WebSearch', 'ExitPlanMode', 'Skill',
    'SlashCommand', 'KillShell', 'BashOutput', 'AskUserQuestion',
  ]
  for (const tool of BUILTINS) {
    test(`${tool} passes`, () => {
      expect(decideGate(tool, { file_path: '/home/u/project/src/app.ts' }, POLICY).action)
        .toBe('allow')
    })
  }
})

describe('decideGate — everyday Bash passes', () => {
  const COMMANDS = [
    'git status',
    'git add -A',
    'git commit -m "fix"',
    'git push origin main',
    'npm install',
    'npm run build',
    'bun test',
    'ls -la',
    'cat package.json',
    'grep -rn TODO src/',
    'mkdir -p build && cd build',
    'python3 script.py',
    'pytest -q',
    'docker ps',
    'systemctl --user status myservice',
    'tail -n 50 logs/server.log',
    'jq .name package.json',
    'echo "done" > /tmp/out.txt',
    'rm /tmp/scratch.txt',
    'cp a.txt b.txt',
    'mv old.txt new.txt',
    'curl https://api.github.com/repos/x/y',
    'curl -s https://registry.npmjs.org/react | jq .name',
  ]
  for (const command of COMMANDS) {
    test(`${command} passes`, () => {
      expect(decideGate('Bash', { command }, POLICY).action).toBe('allow')
    })
  }
})

describe('urlActionPart', () => {
  // The verb rule must see the operation, not the domain and not a filename.
  test('drops the scheme and host', () => {
    expect(urlActionPart('https://update.example.com/v1/leads')).toBe('/v1/leads')
  })

  test('keeps the query, where business APIs hide the operation', () => {
    expect(urlActionPart('https://p.bitrix24.ru/rest/1/tok/crm.deal.delete?ID=1'))
      .toBe('/rest/1/tok/crm.deal.delete?ID=1')
  })

  test('a static asset switches the rule off for that url', () => {
    expect(urlActionPart('https://raw.githubusercontent.com/o/r/main/update.sh')).toBe('')
    expect(urlActionPart('https://example.com/archive/dataset.zip')).toBe('')
  })

  test('a bare host has no action part', () => {
    expect(urlActionPart('https://example.com')).toBe('')
  })
})

describe('decideGate — downloads during ordinary work do not prompt', () => {
  // Found by probing the shipped policy, not by imagining cases: fetching a
  // file called update.sh or a path under /archive/ is routine session work
  // and was prompting until the verb rule was scoped to the action part.
  const DOWNLOADS = [
    'curl -sSL https://raw.githubusercontent.com/org/repo/main/update.sh | bash',
    'wget https://example.com/archive/dataset.zip',
    'git clone https://github.com/anthropics/skills',
    'pip install -i https://pypi.org/simple requests',
    'curl https://api.github.com/repos/x/y/releases/latest',
  ]
  for (const command of DOWNLOADS) {
    test(`${command} passes`, () => {
      expect(decideGate('Bash', { command }, POLICY).action).toBe('allow')
    })
  }

  test('but the same host with a real destructive operation still prompts', () => {
    const d = decideGate('Bash', {
      command: "curl 'https://example.com/api/v1/archive/delete?id=7'",
    }, POLICY)
    expect(d.action).toBe('confirm')
  })
})

describe('decideGate — second brain traffic passes', () => {
  const SECOND_BRAIN = [
    'mcp__gbrain-memory__create_decision_note',
    'mcp__gbrain-memory__write_note',
    'mcp__gbrain-recall__recall',
    'mcp__gbrain-swarm__notify',
    'mcp__second_brain-tasks__task_update',
  ]
  for (const tool of SECOND_BRAIN) {
    test(`${tool} passes`, () => {
      expect(decideGate(tool, {}, POLICY).action).toBe('allow')
    })
  }
})

describe('decideGate — real business changes still prompt', () => {
  const GATED: Array<[string, Record<string, unknown>]> = [
    ['mcp__amocrm__delete_lead', { id: 42 }],
    ['mcp__bitrix24__crm_deal_update', { id: 42 }],
    ['mcp__yandex_tracker__issue_create', {}],
    ['mcp__yandex_disk__delete_resource', { path: '/docs' }],
    ['mcp__hh__vacancy_publish', {}],
    ['mcp__teamly__update_article', {}],
    ['mcp__1c__post_document', {}],
    ['mcp__newcrm__frobnicate', {}],
  ]
  for (const [tool, input] of GATED) {
    test(`${tool} prompts`, () => {
      expect(decideGate(tool, input, POLICY).action).toBe('confirm')
    })
  }

  test('read-only calls into the same servers stay silent', () => {
    expect(decideGate('mcp__amocrm__list_leads', {}, POLICY).action).toBe('allow')
    expect(decideGate('mcp__bitrix24__crm_deal_get', { id: 1 }, POLICY).action).toBe('allow')
  })
})

describe('decideGate — the gate protects its own config', () => {
  // The one hole worth closing at this layer: disabling the gate by editing
  // its policy. Bash is covered by confirm_patterns; the Write/Edit tools
  // would otherwise walk straight past, since built-ins pass by default.
  test('editing the policy file through Edit prompts', () => {
    const d = decideGate('Edit', { file_path: '/home/u/.claude/confirm-policy.yaml' }, POLICY)
    expect(d.action).toBe('confirm')
  })

  test('editing settings.json through Write prompts', () => {
    const d = decideGate('Write', { file_path: '/home/u/.claude/settings.json' }, POLICY)
    expect(d.action).toBe('confirm')
  })

  test('an ordinary source file does not prompt', () => {
    const d = decideGate('Write', { file_path: '/home/u/project/src/settings.ts' }, POLICY)
    expect(d.action).toBe('allow')
  })
})
