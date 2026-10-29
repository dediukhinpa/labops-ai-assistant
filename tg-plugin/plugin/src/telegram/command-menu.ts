// Command menu («/» autocomplete) sync with Telegram at startup.
//
// By default the bot registers BOT_COMMANDS. A bot whose DMs serve outside
// clients (the support bot: client-relay.ts) must not show operator commands
// like /doctor or /reset to them, so TELEGRAM_COMMAND_MENU=off clears the menu
// instead. Clearing on every start matters: a menu set once by an older build
// stays in Telegram until someone deletes it.
import type { Logger } from '../log.js'

const MENU_OFF_RE = /^(0|false|no|off)$/i

export interface BotCommandEntry {
  readonly command: string
  readonly description: string
}

export interface CommandMenuApi {
  setMyCommands(commands: BotCommandEntry[]): Promise<unknown>
  deleteMyCommands(): Promise<unknown>
}

/**
 * Whether the command menu should be shown.
 *
 * @param env - Process environment; reads TELEGRAM_COMMAND_MENU.
 * @returns false only for an explicit off value; unset keeps the menu.
 */
export function isCommandMenuEnabled(env: NodeJS.ProcessEnv): boolean {
  const raw = env.TELEGRAM_COMMAND_MENU?.trim() ?? ''
  return !MENU_OFF_RE.test(raw)
}

/**
 * Register or clear the command menu. Best-effort: never throws, so a network
 * failure cannot block the poller from starting.
 *
 * @param api - Bot API subset.
 * @param commands - Commands to register when the menu is enabled.
 * @param env - Process environment.
 * @param log - Logger.
 */
export async function syncCommandMenu(
  api: CommandMenuApi,
  commands: readonly BotCommandEntry[],
  env: NodeJS.ProcessEnv,
  log: Logger,
): Promise<void> {
  const enabled = isCommandMenuEnabled(env)
  try {
    if (enabled) {
      await api.setMyCommands(commands.map((c) => ({ command: c.command, description: c.description })))
      log.info('telegram commands registered', { count: commands.length })
    } else {
      await api.deleteMyCommands()
      log.info('telegram command menu cleared (TELEGRAM_COMMAND_MENU=off)')
    }
  } catch (err) {
    log.warn(enabled ? 'setMyCommands failed (ignored)' : 'deleteMyCommands failed (ignored)', {
      error: err instanceof Error ? err.message : String(err),
    })
  }
}
