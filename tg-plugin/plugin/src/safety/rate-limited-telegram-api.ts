// Outbound rate-limit wrapper around TelegramApi.
//
// Goal: make Telegram's per-chat / per-bot rate limits invisible to callers.
// A burst of replies (e.g. a multi-part report) used to surface as a 429
// from Bot API with retry_after ≈ 300s — long enough that the operator lost
// sight of what the agent was doing. This wrapper enforces pacing BEFORE
// the request leaves the process and transparently retries on 429.
//
// Layers (independent, all consulted on every text-send):
//   1. Per-chat token bucket (default: 1 msg/sec sustained, burst 3).
//      Same-chat ordering is preserved via a FIFO tail-promise chain — a
//      second sendMessage to the same chat awaits the first before checking
//      its bucket. Different chats run in parallel.
//   2. Global token bucket (default: 25 msg/sec, burst 25). Caps total
//      throughput across all chats under Telegram's 30/sec bot-wide limit.
//   3. 429 handling (FloodGate): a 429 records a ban until now+retry_after
//      in a gate shared by the whole process. Every later call checks the
//      gate BEFORE touching the network - requests made during a flood ban
//      only extend it. A critical call (reply) waits for a SHORT ban
//      (<= maxInlineWaitMs) and retries; for a long ban it fails at once
//      with TelegramFloodError that carries the unban time. A background
//      call (progress mirror, typing, status edits; `background: true`)
//      never waits and never retries.
//
// Methods that don't consume the send-bucket: editMessageText (Telegram's
// edit limits are far more lenient), setMessageReaction, sendChatAction,
// deleteMessage, downloadFile. They still get the 429 retry wrapper so a
// stray 429 on an edit can recover without the caller seeing it.
//
// Test seams: `opts.now` and `opts.sleep` replace the real clock and
// setTimeout-based sleep, so tests can run instantly with deterministic
// virtual time.

import type { Logger } from '../log.js'
import { FloodGate, parseFlood429, type FloodGroup } from './flood-gate.js'
import type {
  ChatAction,
  DownloadResult,
  EditOpts,
  SendDocumentOpts,
  SendMessageOpts,
  TelegramApi,
} from '../channel/tools.js'

interface TokenBucket {
  tokens: number
  capacity: number
  refillPerMs: number
  lastRefill: number
}

function makeBucket(capacity: number, refillPerSec: number, now: number): TokenBucket {
  return {
    tokens: capacity,
    capacity,
    refillPerMs: refillPerSec / 1000,
    lastRefill: now,
  }
}

function refill(b: TokenBucket, now: number): void {
  const dt = now - b.lastRefill
  if (dt <= 0) return
  b.tokens = Math.min(b.capacity, b.tokens + dt * b.refillPerMs)
  b.lastRefill = now
}

// ms to wait before consuming one token; 0 means available now.
function waitMs(b: TokenBucket, now: number): number {
  refill(b, now)
  if (b.tokens >= 1) return 0
  return Math.ceil((1 - b.tokens) / b.refillPerMs)
}

function consume(b: TokenBucket): void {
  b.tokens -= 1
}

interface ChatState {
  bucket: TokenBucket
  // FIFO tail: every enqueued op awaits this before checking the bucket.
  // Replaced with a fresh deferred at each enqueue. Errors do NOT propagate
  // (we use `.catch(() => {})` on the await) so one failed send cannot
  // permanently break the chain for a chat.
  //
  // HEAD-OF-LINE BLOCKING: a slow op (e.g. a 429 retry holding the lock)
  // delays all subsequent sends to the SAME chat. That's intentional —
  // ordering matters more than throughput for a conversational channel.
  // Different chats run in parallel (separate ChatState entries) so a stuck
  // chat does not affect others. Worst-case per-chat stall is bounded by
  // `maxRetries * MAX_RETRY_AFTER_S`.
  tail: Promise<void>
}

export interface RateLimitOptions {
  perChatRefillPerSec?: number
  perChatBurstCapacity?: number
  globalRefillPerSec?: number
  globalBurstCapacity?: number
  maxRetries?: number
  jitterMaxMs?: number
  /** Общий для процесса учёт flood-бана; без него создаётся локальный. */
  gate?: FloodGate
  /**
   * Фоновый режим: при активном бане - сразу ошибка, при 429 - без ретраев.
   * Для зеркала прогресса, typing и правок статуса.
   */
  background?: boolean
  /** Дольше этого критичный вызов не ждёт снятия бана, а падает сразу. */
  maxInlineWaitMs?: number
  /**
   * Вызов не ушёл в сеть из-за активного flood-бана (для журнала Bot API).
   * Реакции и текст банятся независимо, метод передаётся как есть.
   */
  onSkippedBanned?: (method: string, chatId: string) => void
  /** Test seam: replace Date.now() for deterministic virtual time. */
  now?: () => number
  /** Test seam: replace setTimeout-based sleep. */
  sleep?: (ms: number) => Promise<void>
}

// Critical calls (reply) wait for a ban at most this long. A longer
// retry_after is returned to the caller immediately as TelegramFloodError:
// the agent learns the unban time at once instead of hanging for minutes,
// and no request is sent that would extend the ban.
const DEFAULT_MAX_INLINE_WAIT_MS = 15_000
// Total attempts for a critical call: the first one plus one retry.
const DEFAULT_MAX_ATTEMPTS = 2

// Реакции лимитируются Telegram отдельно от текста; всё остальное - группа message.
function groupOf(method: string): FloodGroup {
  return method === 'setMessageReaction' ? 'reaction' : 'message'
}

export function createRateLimitedTelegramApi(
  raw: TelegramApi,
  log: Logger,
  opts: RateLimitOptions = {},
): TelegramApi {
  const cfg = {
    perChatRefillPerSec: opts.perChatRefillPerSec ?? 1,
    perChatBurstCapacity: opts.perChatBurstCapacity ?? 3,
    globalRefillPerSec: opts.globalRefillPerSec ?? 25,
    globalBurstCapacity: opts.globalBurstCapacity ?? 25,
    maxRetries: opts.maxRetries ?? DEFAULT_MAX_ATTEMPTS,
    jitterMaxMs: opts.jitterMaxMs ?? 150,
    maxInlineWaitMs: opts.maxInlineWaitMs ?? DEFAULT_MAX_INLINE_WAIT_MS,
    background: opts.background ?? false,
  }
  const gate = opts.gate ?? new FloodGate({ log, ...(opts.now !== undefined ? { now: opts.now } : {}) })
  const now = opts.now ?? ((): number => Date.now())
  const sleep =
    opts.sleep ??
    ((ms: number): Promise<void> =>
      ms <= 0 ? Promise.resolve() : new Promise((r) => setTimeout(r, ms)))

  const globalBucket = makeBucket(cfg.globalBurstCapacity, cfg.globalRefillPerSec, now())
  const chatState = new Map<string, ChatState>()

  function getChatState(chatId: string): ChatState {
    let s = chatState.get(chatId)
    if (!s) {
      s = {
        bucket: makeBucket(cfg.perChatBurstCapacity, cfg.perChatRefillPerSec, now()),
        tail: Promise.resolve(),
      }
      chatState.set(chatId, s)
    }
    return s
  }

  // Wait until both the per-chat and global buckets have a token, then
  // consume one from each. Caller is responsible for holding the per-chat
  // FIFO lock so two enqueues for the same chat can't race this check.
  async function waitForCapacity(state: ChatState): Promise<void> {
    // Loop because after waking from sleep, another global consumer may
    // have stolen the token we expected. Recompute and re-sleep if so.
    // In single-threaded JS this is rare but the loop keeps invariants
    // robust against future async interleaving.
    for (;;) {
      const t = now()
      const chatWait = waitMs(state.bucket, t)
      const globalWait = waitMs(globalBucket, t)
      const w = Math.max(chatWait, globalWait)
      if (w === 0) {
        consume(state.bucket)
        consume(globalBucket)
        return
      }
      await sleep(w)
    }
  }

  // `maxRetries` is the MAX NUMBER OF ATTEMPTS including the initial call.
  // Background mode and reactions never retry. Before every attempt the
  // shared FloodGate is consulted: an active ban either makes the call wait
  // (short ban, critical call) or fails it locally without any request.
  async function withRetry<T>(
    method: string,
    chatId: string,
    op: () => Promise<T>,
  ): Promise<T> {
    const group = groupOf(method)
    const noRetry = cfg.background || group === 'reaction'
    let attempt = 0
    while (true) {
      attempt += 1
      const remaining = gate.remainingMs(group)
      if (remaining > 0) {
        if (noRetry || remaining > cfg.maxInlineWaitMs) {
          opts.onSkippedBanned?.(method, chatId)
          throw gate.errorFor(group)
        }
        const jitter =
          cfg.jitterMaxMs > 0 ? Math.floor(Math.random() * cfg.jitterMaxMs) : 0
        log.info('telegram flood ban active, waiting', { method, wait_ms: remaining + jitter })
        await sleep(remaining + jitter)
      }
      try {
        return await op()
      } catch (err) {
        const r = parseFlood429(err)
        if (r === null) throw err
        gate.recordBan(group, r.retryAfterSec)
        const retryMs = r.retryAfterSec * 1000
        if (noRetry || attempt >= cfg.maxRetries || retryMs > cfg.maxInlineWaitMs) {
          log.warn('telegram 429, giving up', {
            method,
            retry_after_s: r.retryAfterSec,
            attempt,
            background: noRetry,
          })
          // Long ban: replace the raw error so the message carries the unban time.
          if (retryMs > cfg.maxInlineWaitMs) throw gate.errorFor(group)
          throw err
        }
        log.warn('telegram 429, short backoff', {
          method,
          retry_after_s: r.retryAfterSec,
          attempt,
        })
        // The next iteration sleeps until the recorded ban expires.
      }
    }
  }

  // Serialize per-chat outbound work: each new op awaits the previous op
  // (without inheriting its error), then runs under the rate-limit gate.
  async function enqueueSend<T>(
    method: string,
    chatId: string,
    op: () => Promise<T>,
  ): Promise<T> {
    const state = getChatState(chatId)
    const prev = state.tail
    let release!: () => void
    state.tail = new Promise<void>((r) => {
      release = r
    })
    try {
      await prev.catch(() => {})
      await waitForCapacity(state)
      return await withRetry(method, chatId, op)
    } finally {
      release()
    }
  }

  return {
    async sendMessage(
      chatId: string,
      text: string,
      sendOpts: SendMessageOpts,
    ): Promise<{ message_id: number }> {
      return enqueueSend('sendMessage', chatId, () => raw.sendMessage(chatId, text, sendOpts))
    },

    async editMessageText(
      chatId: string,
      messageId: number,
      text: string,
      editOpts: EditOpts,
    ): Promise<void> {
      return withRetry('editMessageText', chatId, () =>
        raw.editMessageText(chatId, messageId, text, editOpts),
      )
    },

    async setMessageReaction(
      chatId: string,
      messageId: number,
      emoji: string,
    ): Promise<void> {
      return withRetry('setMessageReaction', chatId, () =>
        raw.setMessageReaction(chatId, messageId, emoji),
      )
    },

    async sendChatAction(chatId: string, action: ChatAction): Promise<void> {
      return withRetry('sendChatAction', chatId, () => raw.sendChatAction(chatId, action))
    },

    async sendDocument(
      chatId: string,
      filePath: string,
      docOpts: SendDocumentOpts,
    ): Promise<{ message_id: number }> {
      return enqueueSend('sendDocument', chatId, () => raw.sendDocument(chatId, filePath, docOpts))
    },

    async sendPhoto(
      chatId: string,
      filePath: string,
      photoOpts: SendDocumentOpts,
    ): Promise<{ message_id: number }> {
      return enqueueSend('sendPhoto', chatId, () => raw.sendPhoto(chatId, filePath, photoOpts))
    },

    async downloadFile(fileId: string, destDir: string): Promise<DownloadResult> {
      return raw.downloadFile(fileId, destDir)
    },

    async deleteMessage(chatId: string, messageId: number): Promise<void> {
      return withRetry('deleteMessage', chatId, () => raw.deleteMessage(chatId, messageId))
    },
  }
}
