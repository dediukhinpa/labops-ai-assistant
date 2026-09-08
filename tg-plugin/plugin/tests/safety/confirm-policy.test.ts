// Tests for the confirm-gate policy loader.
//
// Every load failure MUST surface as { ok: false } so the caller denies.
// A policy that cannot be read is never the same as an empty policy —
// treating it as "nothing to gate" would silently disable the gate.

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
