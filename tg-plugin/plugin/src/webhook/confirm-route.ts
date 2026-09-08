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
