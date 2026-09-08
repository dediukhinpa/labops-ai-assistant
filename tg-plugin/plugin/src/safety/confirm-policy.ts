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
