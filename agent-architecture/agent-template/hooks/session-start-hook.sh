#!/usr/bin/env bash
set -euo pipefail

# sdk-guard: skip when running as Agent SDK child to prevent recursion (issue #143)
if [ "${CLAUDE_SDK_CHILD:-0}" = "1" ]; then
    exit 0
fi

# SessionStart hook -- runs once at the start of a Claude Code session and logs it.
# Сборки рабочего набора (working-set.md) здесь больше нет: файл ни во что не
# подгружался, агент его не читал, а на каждом старте уходил запрос в общую память.
# Под задачу агент ищет в памяти сам -- так велит CLAUDE.md.
#
# Wire via templates/settings.json.template (SessionStart hook).
# Non-blocking: any failure exits 0.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="${AGENT_WORKSPACE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
AGENT_ID="${AGENT_ID:-$(basename "$(dirname "$WS")")}"
LOGDIR="$WS/logs"
HOOK_LOG="$LOGDIR/hooks.log"
HANDOFF="$WS/core/active/handoff.md"

mkdir -p "$LOGDIR"
touch "$HOOK_LOG"

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [session-start] $1" >> "$HOOK_LOG"; }

log "session started (agent=${AGENT_ID})"

# Surface handoff to the user via stderr (visible in hook output)
if [ -f "$HANDOFF" ] && [ -s "$HANDOFF" ]; then
    log "handoff present: $(wc -l <"$HANDOFF") lines"
fi

exit 0
