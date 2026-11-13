// Media descriptor rendering and voice transcription.
//
// Ports the BEHAVIOR of gateway.py:863-931 (download_telegram_file +
// transcribe_audio) and gateway.py:2117-2171 (auto-transcribe voice in
// groups) for the inbound-prompt path. Each inbound media message produces
// one MediaDescriptor that the prompt builder renders as a single
// `<media kind="..." ... />` tag concatenated above the user's text.
//
// Why a tag, not free-form prose: Claude needs to distinguish operator-typed
// caption ("trusted") from attachment metadata ("structured fact"). A tag is
// trivially parseable and never confused with a sentence the user actually
// typed.
//
// Voice transcription is OPTIONAL: a missing or unreachable local transcriber
// does NOT crash the handler — we emit `transcription_status="unavailable"`
// (or "failed") plus a short note, and let Claude tell the user.

import { escapeHtmlAttr } from '../format/html.js'
import { z } from 'zod'
import type { AppConfig } from '../config.js'
import { downloadViaLocalApi, type LocalApiConfig } from './local-api.js'

// ─────────────────────────────────────────────────────────────────────
// MediaDescriptor — discriminated union over the eight media kinds the
// inbound Telegram handlers recognize. Fields stay minimal: anything that
// requires a download (full file content) goes through the
// download_attachment tool on Claude's request — the descriptor is just
// the metadata the agent needs to decide whether to download.
// ─────────────────────────────────────────────────────────────────────

export type MediaDescriptor =
  | {
      kind: 'photo'
      fileId: string
      uniqueId?: string
      localPath?: string
      width?: number
      height?: number
      size?: number
    }
  | {
      kind: 'document'
      fileId: string
      name?: string
      mime?: string
      size?: number
    }
  | {
      kind: 'voice'
      fileId: string
      mime?: string
      size?: number
      durationSec?: number
      transcript?: string
      transcriptionStatus: VoiceTranscriptionStatus
    }
  | {
      kind: 'audio'
      fileId: string
      name?: string
      title?: string
      performer?: string
      mime?: string
      size?: number
      durationSec?: number
    }
  | {
      kind: 'video'
      fileId: string
      name?: string
      mime?: string
      size?: number
      durationSec?: number
      width?: number
      height?: number
    }
  | {
      kind: 'video_note'
      fileId: string
      size?: number
      durationSec?: number
    }
  | {
      kind: 'sticker'
      fileId: string
      emoji?: string
      setName?: string
      size?: number
    }

// ─────────────────────────────────────────────────────────────────────
// Filename sanitation — same character class as gateway.py:896-898
// (server.ts:safeName equivalent in this codebase). We strip the
// characters that break HTML attribute parsing or could be mistaken for
// shell metacharacters by downstream tooling.
//
// We do NOT replace path separators — `name` is metadata only, never
// concatenated into a filesystem path here (downloads use uuid-derived
// names via downloadFile / downloadPhotoToInbox).
// ─────────────────────────────────────────────────────────────────────

const UNSAFE_NAME_CHARS = /[<>[\]\r\n;]/g

export function safeMediaName(s: string | undefined): string | undefined {
  if (s === undefined || s === null) return undefined
  if (s === '') return undefined
  return s.replace(UNSAFE_NAME_CHARS, '_')
}

// ─────────────────────────────────────────────────────────────────────
// renderMediaDescriptor — emits a single self-closing XML-ish tag with
// HTML-attribute-escaped values. Numbers are stringified; undefined
// attributes are omitted (so the rendered tag is deterministic for a
// given input shape and tests can grep for exact substrings).
//
// The tag name is always `media`; the `kind` attribute discriminates.
// Why `media` and not `attachment`: keeps it short and distinct from
// gateway.py's `[attached file X]` plain-text prefix that we are
// deliberately replacing.
// ─────────────────────────────────────────────────────────────────────

function attr(name: string, value: string | number | undefined): string {
  if (value === undefined) return ''
  if (typeof value === 'string' && value.length === 0) return ''
  const str = typeof value === 'number' ? String(value) : value
  return ` ${name}="${escapeHtmlAttr(str)}"`
}

export function renderMediaDescriptor(media: MediaDescriptor): string {
  const parts: string[] = [`<media kind="${media.kind}"`]
  parts.push(attr('file_id', media.fileId))

  switch (media.kind) {
    case 'photo': {
      parts.push(attr('unique_id', media.uniqueId))
      parts.push(attr('width', media.width))
      parts.push(attr('height', media.height))
      parts.push(attr('size', media.size))
      parts.push(attr('local_path', media.localPath))
      break
    }
    case 'document': {
      parts.push(attr('name', safeMediaName(media.name)))
      parts.push(attr('mime', media.mime))
      parts.push(attr('size', media.size))
      break
    }
    case 'voice': {
      parts.push(attr('mime', media.mime))
      parts.push(attr('size', media.size))
      parts.push(attr('duration_sec', media.durationSec))
      // Transcript is potentially long — escapeHtmlAttr handles quotes/<>.
      // Status is always emitted so Claude can act on unavailable / failed
      // without inferring it from the absence of `transcript`.
      parts.push(attr('transcript', media.transcript))
      parts.push(attr('transcription_status', media.transcriptionStatus))
      if (media.transcriptionStatus !== 'ok') {
        parts.push(attr('note', VOICE_UNAVAILABLE_NOTE))
      }
      break
    }
    case 'audio': {
      parts.push(attr('name', safeMediaName(media.name)))
      parts.push(attr('title', safeMediaName(media.title)))
      parts.push(attr('performer', safeMediaName(media.performer)))
      parts.push(attr('mime', media.mime))
      parts.push(attr('size', media.size))
      parts.push(attr('duration_sec', media.durationSec))
      break
    }
    case 'video': {
      parts.push(attr('name', safeMediaName(media.name)))
      parts.push(attr('mime', media.mime))
      parts.push(attr('size', media.size))
      parts.push(attr('duration_sec', media.durationSec))
      parts.push(attr('width', media.width))
      parts.push(attr('height', media.height))
      break
    }
    case 'video_note': {
      parts.push(attr('size', media.size))
      parts.push(attr('duration_sec', media.durationSec))
      break
    }
    case 'sticker': {
      parts.push(attr('emoji', media.emoji))
      parts.push(attr('set_name', safeMediaName(media.setName)))
      parts.push(attr('size', media.size))
      break
    }
  }

  parts.push(' />')
  return parts.join('')
}

// ─────────────────────────────────────────────────────────────────────
// Voice transcription (local voice-transcriber, faster-whisper on this host).
//
// Audio goes ONLY to the local service. No external provider exists as a
// fallback: voice may carry personal data, and the owner's decision is that
// it never leaves the host. If the service is down or not configured, the
// descriptor carries a short "transcription unavailable" note instead.
//
//   - The service token is never written to log or error messages.
//   - The service URL must be a loopback address; anything else is refused
//     before a single byte of audio is read.
//   - Returns a discriminated result, never `null` — the descriptor
//     ALWAYS includes a transcription_status attribute so Claude does
//     not need to guess "is empty transcript a bug or a silent file?".
// ─────────────────────────────────────────────────────────────────────

// Telegram Bot API serves files up to 20MB; the service enforces the same cap.
const VOICE_MAX_BYTES = 20 * 1024 * 1024

// Default address of the service (deploy/voice-transcriber.env.example).
const DEFAULT_TRANSCRIBER_URL = 'http://127.0.0.1:8310'

// Upper bound for one request: queue wait (20s) + a long voice message on CPU.
const TRANSCRIBE_TIMEOUT_MS = 180_000

// Hosts the audio may be sent to. Anything else is treated as misconfiguration.
const LOOPBACK_HOSTS: ReadonlySet<string> = new Set(['127.0.0.1', 'localhost', '[::1]'])

// Short note for the model when there is no transcript (kept as a constant so
// tests and the prompt renderer agree on the exact wording).
export const VOICE_UNAVAILABLE_NOTE = 'голосовое сообщение: расшифровка недоступна'

const TranscribeResponseSchema = z.object({
  text: z.string(),
  language: z.string().optional(),
  duration_sec: z.number().optional(),
})

export type VoiceTranscriptionStatus = 'ok' | 'unavailable' | 'failed' | 'skipped'

export interface VoiceTranscriptionInput {
  fileId: string
  durationSec?: number
  size?: number
  mime?: string
  // Dependency injection so tests can stub without spinning a Telegram
  // mock. Production wires this to telegramApi.downloadFile bound to the
  // inbox directory.
  downloadFile: (fileId: string) => Promise<{ path: string; mime?: string; size?: number }>
  // Optional override for tests — `fetch` global is used otherwise.
  fetchImpl?: typeof fetch
  // Optional file-reader override so unit tests can avoid touching disk.
  readFile?: (path: string) => Promise<Uint8Array>
}

export interface VoiceTranscriptionResult {
  transcript?: string
  status: VoiceTranscriptionStatus
  errorMessage?: string
}

/** Environment of the local transcriber client: address (optional) and Bearer token. */
export interface VoiceTranscriberEnv {
  VOICE_TRANSCRIBER_URL?: string
  VOICE_TRANSCRIBER_TOKEN?: string
}

// Remove any occurrence of the token from a string. We compare on the full
// token in case an HTTP client embeds it verbatim into an error.
function redactToken(message: string, token: string): string {
  if (!token) return message
  return message.split(token).join('[REDACTED]')
}

/** True when the URL points to this host, so audio cannot leave it. */
function isLoopbackUrl(raw: string): boolean {
  try {
    const url = new URL(raw)
    return url.protocol === 'http:' && LOOPBACK_HOSTS.has(url.hostname)
  } catch {
    return false
  }
}

/**
 * Transcribe one Telegram voice message via the local voice-transcriber.
 *
 * Never throws: every failure becomes a `failed`/`skipped`/`unavailable`
 * status so the inbound handler keeps working without a transcript.
 */
export async function maybeTranscribeVoice(
  input: VoiceTranscriptionInput,
  config: AppConfig,
  env: VoiceTranscriberEnv,
): Promise<VoiceTranscriptionResult> {
  const token = env.VOICE_TRANSCRIBER_TOKEN
  if (!token) {
    return { status: 'unavailable', errorMessage: 'VOICE_TRANSCRIBER_TOKEN is not set' }
  }

  // Voice provider can be disabled in config.json (provider: 'none').
  if (config.voice.provider === 'none') {
    return { status: 'skipped', errorMessage: 'voice provider disabled in config' }
  }

  const baseUrl = (env.VOICE_TRANSCRIBER_URL ?? DEFAULT_TRANSCRIBER_URL).replace(/\/+$/, '')
  if (!isLoopbackUrl(baseUrl)) {
    return {
      status: 'unavailable',
      errorMessage: 'VOICE_TRANSCRIBER_URL must be a loopback http URL',
    }
  }

  // Size guard BEFORE download. `input.size` is the Telegram-reported
  // file size and is reliable for voice/audio attachments.
  if (input.size !== undefined && input.size > VOICE_MAX_BYTES) {
    return {
      status: 'skipped',
      errorMessage: `voice file too large (${input.size} > ${VOICE_MAX_BYTES} bytes)`,
    }
  }

  const fetchFn = input.fetchImpl ?? fetch

  try {
    const downloaded = await input.downloadFile(input.fileId)

    // Re-check actual size after download — Telegram metadata can lag.
    if (downloaded.size !== undefined && downloaded.size > VOICE_MAX_BYTES) {
      return {
        status: 'skipped',
        errorMessage: `voice file too large (${downloaded.size} > ${VOICE_MAX_BYTES} bytes)`,
      }
    }

    // Read bytes — prefer injected reader, otherwise dynamic import of
    // node:fs/promises so the module stays usable from environments
    // where the test fully stubs downloadFile/readFile.
    let bytes: Uint8Array
    if (input.readFile) {
      bytes = await input.readFile(downloaded.path)
    } else {
      const fs = await import('node:fs/promises')
      bytes = await fs.readFile(downloaded.path)
    }

    const mime = downloaded.mime ?? input.mime ?? 'audio/ogg'
    const query = new URLSearchParams({ language: config.voice.language })
    const res = await fetchFn(`${baseUrl}/transcribe?${query.toString()}`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': mime },
      body: new Blob([new Uint8Array(bytes)], { type: mime }),
      signal: AbortSignal.timeout(TRANSCRIBE_TIMEOUT_MS),
    })

    if (!res.ok) {
      // Only the status code is reported: the response body of the service
      // is an error detail we do not need, and it never carries the transcript.
      return { status: 'failed', errorMessage: `voice-transcriber HTTP ${res.status}` }
    }

    const parsed = TranscribeResponseSchema.safeParse(await res.json())
    if (!parsed.success) {
      return { status: 'failed', errorMessage: 'voice-transcriber returned an unexpected body' }
    }
    // Empty transcript = the audio was silent or unintelligible. Not a
    // failure of the pipeline — surface it as status=ok with empty
    // transcript so Claude can mention "I couldn't make out the audio"
    // instead of pretending the user typed nothing.
    return { transcript: parsed.data.text.trim(), status: 'ok' }
  } catch (err) {
    const raw = err instanceof Error ? err.message : String(err)
    return { status: 'failed', errorMessage: redactToken(raw, token) }
  }
}

// ─────────────────────────────────────────────────────────────────────
// Photo download (post-allowlist).
//
// Ports gateway.py:863-901 photo branch. The Bot API getFile call gives
// us a relative `file_path` we suffix onto the file-CDN URL with the
// bot token. We persist into the inbox directory under a name derived
// from the unique_id + extension so Claude can Read the file later via
// download_attachment.
//
// Returns `undefined` on any failure — callers should still emit a
// descriptor without `local_path`, so Claude knows the file exists
// and can re-request it via the download_attachment tool.
// ─────────────────────────────────────────────────────────────────────

interface GetFileResult {
  file_id?: string
  file_unique_id?: string
  file_path?: string
  file_size?: number
}

export interface BotApiForDownload {
  api: {
    getFile: (fileId: string) => Promise<GetFileResult>
  }
}

export interface DownloadPhotoDeps {
  // Локальный Bot API (TELEGRAM_API_ROOT): файл берётся с диска сервера или
  // по его URL, потолка 20 МБ нет. Не задан -- прежнее облачное поведение.
  localApi?: LocalApiConfig
  fetchImpl?: typeof fetch
  writeFile?: (path: string, data: Uint8Array) => Promise<void>
  mkdir?: (path: string) => Promise<void>
  now?: () => number
}

export async function downloadPhotoToInbox(
  bot: BotApiForDownload,
  token: string,
  fileId: string,
  inboxDir: string,
  deps: DownloadPhotoDeps = {},
): Promise<string | undefined> {
  const fetchFn = deps.fetchImpl ?? fetch
  try {
    const file = await bot.api.getFile(fileId)
    if (!file.file_path) return undefined

    if (deps.localApi !== undefined) {
      const saved = await downloadViaLocalApi(
        { file_path: file.file_path, file_unique_id: file.file_unique_id },
        token,
        inboxDir,
        deps.localApi,
        {
          ...(deps.fetchImpl !== undefined ? { fetchImpl: deps.fetchImpl } : {}),
          ...(deps.now !== undefined ? { now: deps.now } : {}),
        },
        'photo',
      )
      return saved.path
    }

    // 20MB Bot API download cap — matches Telegram's documented limit
    // and gateway.py:873 TG_MAX_FILE_MB default.
    const maxBytes = 20 * 1024 * 1024
    if (file.file_size !== undefined && file.file_size > maxBytes) return undefined

    const url = `https://api.telegram.org/file/bot${token}/${file.file_path}`
    const res = await fetchFn(url)
    if (!res.ok) return undefined
    const buf = new Uint8Array(await res.arrayBuffer())

    const rawExt = file.file_path.includes('.') ? (file.file_path.split('.').pop() ?? 'jpg') : 'jpg'
    const ext = rawExt.replace(/[^a-zA-Z0-9]/g, '') || 'jpg'
    const uniqueId = (file.file_unique_id ?? '').replace(/[^a-zA-Z0-9_-]/g, '') || 'photo'
    const ts = deps.now ? deps.now() : Date.now()
    const path = `${inboxDir}/${ts}-${uniqueId}.${ext}`

    if (deps.mkdir) {
      await deps.mkdir(inboxDir)
    } else {
      const fs = await import('node:fs/promises')
      await fs.mkdir(inboxDir, { recursive: true })
    }
    if (deps.writeFile) {
      await deps.writeFile(path, buf)
    } else {
      const fs = await import('node:fs/promises')
      await fs.writeFile(path, buf)
    }
    return path
  } catch {
    // Any failure → undefined; caller emits descriptor without local_path.
    return undefined
  }
}
