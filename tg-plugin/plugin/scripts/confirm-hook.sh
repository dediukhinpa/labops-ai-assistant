#!/usr/bin/env bash
# confirm-hook.sh — launcher for confirm-hook.ts.
#
# Why a launcher instead of calling bun directly from settings.json:
#
# bun installs to ~/.bun/bin, which is NOT in systemd's default PATH.
# start-agent.sh already exports it for the tmux session, and its own comment
# records what happens when it does not — «claude не поднимает свой канальный
# MCP-сервер ... агент молча остаётся без Telegram». The gate inherits that
# hazard, and for a gate the consequence is worse: a PreToolUse hook that
# fails to execute writes nothing to stdout, empty stdout means "no opinion",
# and the call proceeds. The gate would be installed, look configured in
# settings.json, and never run once. A gate that silently does not run is
# worse than no gate, because it is believed.
#
# So: resolve bun the same way start-agent.sh does, and if it genuinely
# cannot be found, say so instead of disappearing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_TS="$SCRIPT_DIR/confirm-hook.ts"

BUN=""
if command -v bun >/dev/null 2>&1; then
  BUN="$(command -v bun)"
elif [ -x "${BUN_INSTALL:-$HOME/.bun}/bin/bun" ]; then
  BUN="${BUN_INSTALL:-$HOME/.bun}/bin/bun"
fi

if [ -n "$BUN" ] && [ -f "$HOOK_TS" ]; then
  exec "$BUN" "$HOOK_TS"
fi

# Cannot run the gate at all. The branch below mirrors the hook's own
# provisioning rule: if a channel is configured, every failure denies; if
# there is no channel in this environment, the gate was never provisioned
# here and must not block anything.
if [ -n "${CONFIRM_WEBHOOK_URL:-}" ] || [ -n "${TELEGRAM_WEBHOOK_PORT:-}" ]; then
  echo "confirm-gate: bun not found (looked in PATH and ${BUN_INSTALL:-$HOME/.bun}/bin)" >&2
  printf '%s' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"гейт подтверждений не запустился: не найден bun. Проверь PATH сессии агента (~/.bun/bin) — до устранения все вызовы блокируются"}}'
fi
exit 0
