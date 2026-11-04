// Media descriptor + voice transcription tests.
//
// Covers:
//   - safeMediaName strips the same characters server.ts:safeName drops
//   - renderMediaDescriptor for every kind emits well-formed <media ... />
//   - attribute escaping handles quotes/<>/& without corrupting structure
//   - undefined attributes are omitted (no orphan `name=""` for example)
//   - maybeTranscribeVoice handles a missing token/service without crashing
//   - maybeTranscribeVoice returns ok / failed paths with stub fetch
//   - audio goes only to a loopback URL; the token is redacted in every error path

import { describe, expect, test } from 'bun:test'

import {
  maybeTranscribeVoice,
  VOICE_UNAVAILABLE_NOTE,
  renderMediaDescriptor,
  safeMediaName,
  type MediaDescriptor,
} from '../../src/telegram/media.js'
import type { AppConfig } from '../../src/config.js'

// Minimal AppConfig stub — only voice.* is touched by media.ts. Other
// fields stay structural so the type-check passes without recreating the
// full default tree.
const voiceConfig: AppConfig = {
  bot_id: 1,
  dm_only: true,
  allowed_user_ids: [1],
  allowed_chat_ids: [1],
  status: { enabled: true, interval_ms: 700, ttl_ms: 300_000, delete_on_complete: true, delete_on_expire: true, suppress_typing_bubble: false },
  album: { flush_ms: 2000 },
  voice: { provider: 'local', language: 'ru' },
  webhook: { enabled: false, host: '127.0.0.1', port: 0 },
  permission_relay: { enabled: true, allowed_user_ids: [1], bash_only_proof: true },
  commands: { help: true, status: true, stop: true, reset: true },
  memory: {
    enabled: false,
    source_tag: 'tg',
    max_active_bytes: 20480,
    trim_keep_lines: 600,
    buffer_ttl_ms: 5 * 60 * 1000,
    buffer_max_entries: 100,
  },
  progress: {
    enabled: true,
    edit_throttle_ms: 3000,
    recent_buffer: 10,
    session_ttl_ms: 600000,
  },
  task_mirror: {
    enabled: true,
    edit_throttle_ms: 3000,
    session_ttl_ms: 600000,
    collapse_completed_after: 5,
  },
  watcher: {
    enabled: true,
    debounce_ms: 10_000,
    busy_threshold_ms: 30_000,
  },
  tmux_mirror: { enabled: false, pane_target: '', poll_interval_ms: 5000, line_count: 50, hide_segments: ['boot_banner', 'inbound_warning', 'footer_hints', 'input_box'], mode: 'latest_inbound_only', max_lines: 14 },
  multichat: { enabled: false },
  ask_user_question: { enabled: false, timeout_ms: 300_000, max_preview_chars: 1000 },
}

// ─────────────────────────────────────────────────────────────────────
// safeMediaName
// ─────────────────────────────────────────────────────────────────────

describe('safeMediaName', () => {
  test('strips dangerous chars from filename', () => {
    expect(safeMediaName('a<b>c[d]e;f\rg\nh')).toBe('a_b_c_d_e_f_g_h')
  })
  test('returns undefined for falsy', () => {
    expect(safeMediaName(undefined)).toBeUndefined()
    expect(safeMediaName('')).toBeUndefined()
  })
  test('keeps benign filenames unchanged', () => {
    expect(safeMediaName('report-2026-05-15.pdf')).toBe('report-2026-05-15.pdf')
  })
})

// ─────────────────────────────────────────────────────────────────────
// renderMediaDescriptor
// ─────────────────────────────────────────────────────────────────────

describe('renderMediaDescriptor', () => {
  test('builds photo tag with width/height/local_path', () => {
    const md: MediaDescriptor = {
      kind: 'photo',
      fileId: 'photoFile1',
      width: 1280,
      height: 720,
      localPath: '/abs/inbox/123-abc.jpg',
    }
    const out = renderMediaDescriptor(md)
    expect(out).toBe(
      '<media kind="photo" file_id="photoFile1" width="1280" height="720" local_path="/abs/inbox/123-abc.jpg" />',
    )
  })

  test('builds document tag with name/mime/size', () => {
    const md: MediaDescriptor = {
      kind: 'document',
      fileId: 'docF',
      name: 'foo.pdf',
      mime: 'application/pdf',
      size: 12345,
    }
    const out = renderMediaDescriptor(md)
    expect(out).toBe(
      '<media kind="document" file_id="docF" name="foo.pdf" mime="application/pdf" size="12345" />',
    )
  })

  test('builds voice tag with transcript when status=ok', () => {
    const md: MediaDescriptor = {
      kind: 'voice',
      fileId: 'voiceF',
      mime: 'audio/ogg',
      size: 12345,
      durationSec: 5,
      transcript: 'привет мой оператор',
      transcriptionStatus: 'ok',
    }
    const out = renderMediaDescriptor(md)
    expect(out).toBe(
      '<media kind="voice" file_id="voiceF" mime="audio/ogg" size="12345" duration_sec="5" transcript="привет мой оператор" transcription_status="ok" />',
    )
  })

  test('builds voice tag with transcription_status=unavailable when no service', () => {
    const md: MediaDescriptor = {
      kind: 'voice',
      fileId: 'voiceF2',
      durationSec: 5,
      transcriptionStatus: 'unavailable',
    }
    const out = renderMediaDescriptor(md)
    expect(out).toBe(
      '<media kind="voice" file_id="voiceF2" duration_sec="5" transcription_status="unavailable" note="голосовое сообщение: расшифровка недоступна" />',
    )
    // No phantom transcript attribute.
    expect(out).not.toContain('transcript=')
  })

  test('builds video tag', () => {
    const md: MediaDescriptor = {
      kind: 'video',
      fileId: 'vF',
      mime: 'video/mp4',
      durationSec: 30,
      width: 640,
      height: 480,
    }
    const out = renderMediaDescriptor(md)
    expect(out).toContain('kind="video"')
    expect(out).toContain('width="640"')
    expect(out).toContain('height="480"')
    expect(out).toContain('duration_sec="30"')
  })

  test('builds sticker tag with emoji and set_name', () => {
    const md: MediaDescriptor = {
      kind: 'sticker',
      fileId: 'sF',
      emoji: '🔥',
      setName: 'labops_pack',
      size: 4096,
    }
    const out = renderMediaDescriptor(md)
    expect(out).toBe(
      '<media kind="sticker" file_id="sF" emoji="🔥" set_name="labops_pack" size="4096" />',
    )
  })

  test('builds video_note tag', () => {
    const md: MediaDescriptor = {
      kind: 'video_note',
      fileId: 'vnF',
      size: 1024,
      durationSec: 12,
    }
    expect(renderMediaDescriptor(md)).toBe(
      '<media kind="video_note" file_id="vnF" size="1024" duration_sec="12" />',
    )
  })

  test('omits undefined attributes', () => {
    const md: MediaDescriptor = {
      kind: 'document',
      fileId: 'd',
    }
    const out = renderMediaDescriptor(md)
    // Only kind + file_id should appear.
    expect(out).toBe('<media kind="document" file_id="d" />')
    expect(out).not.toContain('name=')
    expect(out).not.toContain('mime=')
    expect(out).not.toContain('size=')
  })

  test('escapes attribute values containing quotes and angle brackets', () => {
    const md: MediaDescriptor = {
      kind: 'document',
      fileId: 'd',
      name: 'evil".pdf',
      mime: 'application/x<script>',
    }
    const out = renderMediaDescriptor(md)
    // Quote is HTML-encoded so it never closes the attribute early.
    expect(out).toContain('name="evil&quot;.pdf"')
    expect(out).toContain('mime="application/x&lt;script&gt;"')
    // Outer structure intact — exactly one self-close.
    expect(out.match(/\/>/g)).toHaveLength(1)
  })
})

// ─────────────────────────────────────────────────────────────────────
// maybeTranscribeVoice
// ─────────────────────────────────────────────────────────────────────

describe('maybeTranscribeVoice', () => {
  const ENV = { VOICE_TRANSCRIBER_TOKEN: 'tok_test_123' }
  const okInput = {
    fileId: 'v',
    size: 1000,
    mime: 'audio/ogg',
    downloadFile: async () => ({ path: '/tmp/voice.oga', size: 1000, mime: 'audio/ogg' }),
    readFile: async () => new Uint8Array([1, 2, 3, 4]),
  }
  const jsonResponse = (body: unknown, status = 200): Response =>
    new Response(JSON.stringify(body), { status })

  test('returns unavailable when token absent', async () => {
    const r = await maybeTranscribeVoice(
      {
        fileId: 'v1',
        downloadFile: async () => {
          throw new Error('should not be called when token missing')
        },
      },
      voiceConfig,
      {},
    )
    expect(r.status).toBe('unavailable')
    expect(r.transcript).toBeUndefined()
  })

  test('returns skipped when file size exceeds 20MB', async () => {
    const r = await maybeTranscribeVoice(
      {
        fileId: 'big',
        size: 30 * 1024 * 1024,
        downloadFile: async () => {
          throw new Error('should not download when oversized')
        },
      },
      voiceConfig,
      ENV,
    )
    expect(r.status).toBe('skipped')
    expect(r.errorMessage).toContain('too large')
  })

  test('posts raw audio to the local service and returns trimmed text', async () => {
    let fetchedUrl = ''
    let headers: Record<string, string> = {}
    let sent = 0
    const r = await maybeTranscribeVoice(
      {
        ...okInput,
        fetchImpl: (async (url: string | URL, init?: RequestInit) => {
          fetchedUrl = String(url)
          headers = (init?.headers ?? {}) as Record<string, string>
          sent = (init?.body as Blob).size
          return jsonResponse({ text: '  привет мир  ', language: 'ru', duration_sec: 2 })
        }) as unknown as typeof fetch,
      },
      voiceConfig,
      ENV,
    )
    expect(r.status).toBe('ok')
    expect(r.transcript).toBe('привет мир')
    expect(fetchedUrl).toBe('http://127.0.0.1:8310/transcribe?language=ru')
    expect(headers.Authorization).toBe('Bearer tok_test_123')
    expect(headers['Content-Type']).toBe('audio/ogg')
    expect(sent).toBe(4)
  })

  test('uses VOICE_TRANSCRIBER_URL when it is loopback', async () => {
    let fetchedUrl = ''
    await maybeTranscribeVoice(
      {
        ...okInput,
        fetchImpl: (async (url: string | URL) => {
          fetchedUrl = String(url)
          return jsonResponse({ text: 'x' })
        }) as unknown as typeof fetch,
      },
      voiceConfig,
      { ...ENV, VOICE_TRANSCRIBER_URL: 'http://localhost:9999/' },
    )
    expect(fetchedUrl).toStartWith('http://localhost:9999/transcribe?')
  })

  test('refuses a non-loopback URL and never reads or sends audio', async () => {
    let touched = false
    const r = await maybeTranscribeVoice(
      {
        fileId: 'v',
        downloadFile: async () => {
          touched = true
          return { path: '/tmp/x.oga' }
        },
        fetchImpl: (async () => {
          touched = true
          return jsonResponse({ text: 'x' })
        }) as unknown as typeof fetch,
      },
      voiceConfig,
      { ...ENV, VOICE_TRANSCRIBER_URL: 'https://api.example.com' },
    )
    expect(r.status).toBe('unavailable')
    expect(touched).toBe(false)
  })

  test('empty transcript is ok, not a failure', async () => {
    const r = await maybeTranscribeVoice(
      { ...okInput, fetchImpl: (async () => jsonResponse({ text: '' })) as unknown as typeof fetch },
      voiceConfig,
      ENV,
    )
    expect(r).toEqual({ transcript: '', status: 'ok' })
  })

  test('returns failed on stubbed fetch error (service down)', async () => {
    const r = await maybeTranscribeVoice(
      {
        ...okInput,
        fetchImpl: (async () => {
          throw new Error('connect ECONNREFUSED 127.0.0.1:8310')
        }) as unknown as typeof fetch,
      },
      voiceConfig,
      ENV,
    )
    expect(r.status).toBe('failed')
    expect(r.errorMessage).toContain('ECONNREFUSED')
  })

  test('returns failed with HTTP status on non-2xx response (503 busy)', async () => {
    const r = await maybeTranscribeVoice(
      {
        ...okInput,
        fetchImpl: (async () =>
          jsonResponse({ detail: 'service is busy' }, 503)) as unknown as typeof fetch,
      },
      voiceConfig,
      ENV,
    )
    expect(r.status).toBe('failed')
    expect(r.errorMessage).toContain('503')
  })

  test('returns failed on a malformed response body', async () => {
    const r = await maybeTranscribeVoice(
      { ...okInput, fetchImpl: (async () => jsonResponse({ nope: 1 })) as unknown as typeof fetch },
      voiceConfig,
      ENV,
    )
    expect(r.status).toBe('failed')
  })

  test('redacts the token in failure message', async () => {
    const secret = 'tok_super_secret_AAAA1111'
    const r = await maybeTranscribeVoice(
      {
        ...okInput,
        fetchImpl: (async () => {
          throw new Error(`upstream rejected Bearer ${secret} at line 7`)
        }) as unknown as typeof fetch,
      },
      voiceConfig,
      { VOICE_TRANSCRIBER_TOKEN: secret },
    )
    expect(r.status).toBe('failed')
    expect(r.errorMessage).not.toContain(secret)
    expect(r.errorMessage).toContain('[REDACTED]')
  })

  test('returns skipped when voice provider disabled in config', async () => {
    const cfg: AppConfig = { ...voiceConfig, voice: { ...voiceConfig.voice, provider: 'none' } }
    const r = await maybeTranscribeVoice(
      {
        fileId: 'v',
        downloadFile: async () => {
          throw new Error('should not download when provider=none')
        },
      },
      cfg,
      ENV,
    )
    expect(r.status).toBe('skipped')
  })
})

describe('renderMediaDescriptor voice note', () => {
  test('adds the unavailable note when there is no transcript', () => {
    const out = renderMediaDescriptor({
      kind: 'voice',
      fileId: 'v',
      transcriptionStatus: 'failed',
    })
    expect(out).toContain('transcription_status="failed"')
    expect(out).toContain(`note="${VOICE_UNAVAILABLE_NOTE}"`)
    expect(VOICE_UNAVAILABLE_NOTE).toBe('голосовое сообщение: расшифровка недоступна')
  })

  test('has no note when transcription succeeded', () => {
    const out = renderMediaDescriptor({
      kind: 'voice',
      fileId: 'v',
      transcript: 'привет',
      transcriptionStatus: 'ok',
    })
    expect(out).not.toContain('note=')
  })
})
