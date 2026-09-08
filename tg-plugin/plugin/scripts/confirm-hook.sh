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
# NOT `set -e`, deliberately: every path in this script must reach `exit 0`
# after writing a decision. errexit would abandon the script mid-way on any
# non-zero command and leave stdout empty — the exact silent pass this file
# exists to prevent.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_TS="$SCRIPT_DIR/confirm-hook.ts"

deny_or_passthrough() {
  # Mirrors the hook's own provisioning rule: if a channel is configured,
  # every failure denies; if there is no channel in this environment, the
  # gate was never provisioned here and must not block anything.
  if [ -n "${CONFIRM_WEBHOOK_URL:-}" ] || [ -n "${TELEGRAM_WEBHOOK_PORT:-}" ]; then
    echo "confirm-gate: $1" >&2
    printf '%s' "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"гейт подтверждений не запустился ($1) — вызов заблокирован\"}}"
  fi
  exit 0
}

BUN=""
if command -v bun >/dev/null 2>&1; then
  BUN="$(command -v bun)"
elif [ -x "${BUN_INSTALL:-$HOME/.bun}/bin/bun" ]; then
  BUN="${BUN_INSTALL:-$HOME/.bun}/bin/bun"
fi

# Each failure names its own cause. Saying "bun not found" when bun was found
# and the script was missing sends the operator to debug the wrong thing.
if [ -z "$BUN" ]; then
  deny_or_passthrough "не найден bun (искали в PATH и в ${BUN_INSTALL:-$HOME/.bun}/bin)"
fi
if [ ! -f "$HOOK_TS" ]; then
  deny_or_passthrough "не найден confirm-hook.ts по пути $HOOK_TS"
fi

# Run, don't exec. `exec` hands the shell's PID to bun, so bun's exit code
# becomes the hook's exit code and its startup failures — a missing
# dependency after a partial install, a broken module — would leave this
# script unable to answer at all. Capturing lets a failed run still produce
# a decision.
OUT="$("$BUN" "$HOOK_TS")"
RC=$?
if [ "$RC" -eq 0 ]; then
  # Empty stdout with rc=0 is the hook's own passthrough. Forward it verbatim.
  printf '%s' "$OUT"
  exit 0
fi

deny_or_passthrough "bun завершился с кодом $RC"
