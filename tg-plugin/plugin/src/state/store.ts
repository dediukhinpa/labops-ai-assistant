// On-disk state store for the labops-channel plugin.
//
// Owns the durable filesystem layout under the state root: directory
// provisioning, the Telegram update-offset (atomic tmp+rename), the one-shot
// legacy allowlist migration, and the dead-letter buckets. All paths are
// resolved upstream by getStatePaths() (config.ts); this module only creates
// and mutates them. Contract is pinned by tests/state.test.ts.

import {
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  unlinkSync,
  writeFileSync,
} from 'fs'
import { dirname, join } from 'path'

import type { StatePaths } from '../config.js'

/** Owner-only permission mode for the state root (rwx------). */
const STATE_DIR_MODE = 0o700

/** Owner-only permission mode for state files (rw-------). */
const STATE_FILE_MODE = 0o600

/** Dead-letter buckets: one per ingress source that can fail to process. */
export type DeadLetterBucket = 'updates' | 'webhook'

/**
 * Wrapper persisted for every dead-lettered payload. `ts` is an ISO-8601
 * timestamp; `bucket` records which ingress path failed; `value` is the
 * original, unmodified payload.
 */
type DeadLetterEnvelope<T> = {
  ts: string
  bucket: DeadLetterBucket
  value: T
}

/**
 * Process-local counter guaranteeing unique tmp/dead-letter filenames even
 * within the same millisecond. Not persisted — uniqueness only needs to hold
 * for the lifetime of a single process.
 */
let uniqueCounter = 0

/**
 * Create every directory the plugin writes to, making the state root
 * owner-only. Idempotent: safe to call on every boot.
 *
 * @param paths - Resolved state paths for this agent.
 */
export function ensureStateDirs(paths: StatePaths): void {
  // Root first, with a restrictive mode so secrets/state are never group- or
  // world-readable. recursive:true tolerates a pre-existing root.
  mkdirSync(paths.root, { recursive: true, mode: STATE_DIR_MODE })

  // Directory-valued locations under the root. dead-letter buckets pull in
  // their shared `dead-letter` parent via recursive:true.
  const dirs: readonly string[] = [
    paths.inbox,
    paths.sessionIds,
    paths.deadLetterUpdates,
    paths.deadLetterWebhook,
    dirname(paths.logs.server),
  ]
  for (const dir of dirs) {
    mkdirSync(dir, { recursive: true })
  }
}

/**
 * Read the persisted Telegram getUpdates offset.
 *
 * @param paths - Resolved state paths for this agent.
 * @returns The stored offset, or undefined if none has been written yet.
 */
export function readUpdateOffset(paths: StatePaths): number | undefined {
  if (!existsSync(paths.updateOffset)) {
    return undefined
  }
  const raw = readFileSync(paths.updateOffset, 'utf8').trim()
  if (raw === '') {
    return undefined
  }
  const parsed = Number(raw)
  return Number.isFinite(parsed) ? parsed : undefined
}

/**
 * Persist the Telegram getUpdates offset atomically. Writes to a temp file in
 * the same directory, then renames over the target so a crash mid-write can
 * never leave a truncated offset. On rename failure the temp file is removed
 * and the error re-thrown, leaving the target untouched.
 *
 * @param paths - Resolved state paths for this agent.
 * @param offset - The offset to persist.
 */
export function writeUpdateOffset(paths: StatePaths, offset: number): void {
  const tmpPath = `${paths.updateOffset}.tmp.${process.pid}.${uniqueCounter++}`
  writeFileSync(tmpPath, String(offset), { encoding: 'utf8', mode: STATE_FILE_MODE })
  try {
    renameSync(tmpPath, paths.updateOffset)
  } catch (err) {
    // Clean up the orphaned temp file so no stray *.tmp.* is left behind.
    try {
      unlinkSync(tmpPath)
    } catch {
      // Best-effort cleanup; surface the original rename failure below.
    }
    throw err
  }
}

/**
 * One-shot boot migration of the legacy `access.json` allowlist to the current
 * `allowlist.json`. No-op when the current file already exists (operator keeps
 * ownership of the stale legacy file) or when neither file is present.
 *
 * @param paths - Resolved state paths for this agent.
 * @returns true if a migration was performed, false otherwise.
 */
export function migrateLegacyAllowlist(paths: StatePaths): boolean {
  // Current file wins: never clobber live state with legacy data.
  if (existsSync(paths.allowlist)) {
    return false
  }
  const legacyPath = join(dirname(paths.allowlist), 'access.json')
  if (!existsSync(legacyPath)) {
    return false
  }
  renameSync(legacyPath, paths.allowlist)
  return true
}

/**
 * Persist a payload that could not be processed into its dead-letter bucket for
 * later inspection or replay.
 *
 * @param paths - Resolved state paths for this agent.
 * @param bucket - Which ingress source produced the failed payload.
 * @param value - The original payload to preserve.
 * @returns Absolute path of the written dead-letter file.
 */
export function writeDeadLetter<T>(
  paths: StatePaths,
  bucket: DeadLetterBucket,
  value: T,
): string {
  const dir = bucket === 'updates' ? paths.deadLetterUpdates : paths.deadLetterWebhook
  const ts = new Date().toISOString()
  const envelope: DeadLetterEnvelope<T> = { ts, bucket, value }
  // Colons from the ISO timestamp are filesystem-safe on Linux but replaced for
  // portability; counter + pid guarantee uniqueness within the process.
  const fileName = `${ts.replace(/[:.]/g, '-')}.${process.pid}.${uniqueCounter++}.json`
  const filePath = join(dir, fileName)
  writeFileSync(filePath, JSON.stringify(envelope, null, 2), { encoding: 'utf8', mode: STATE_FILE_MODE })
  return filePath
}
