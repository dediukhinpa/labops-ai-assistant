#!/bin/bash
set -euo pipefail

# memory-rotate.sh -- Archive ARCHIVE memory when it gets too large
# ARCHIVE (MEMORY.md) > 5KB -> archived/YYYY-MM.md

WS="${AGENT_WORKSPACE:-.claude}"
ARCHIVE="$WS/core/MEMORY.md"
ARCHIVE_DIR="$WS/core/archived"
LOG="/tmp/memory-rotate.log"

echo "=== memory-rotate.sh $(date -u +%Y-%m-%dT%H:%M:%SZ) ===" >> "$LOG"

[ ! -f "$ARCHIVE" ] && echo "No MEMORY.md" >> "$LOG" && exit 0

SIZE=$(wc -c < "$ARCHIVE")
echo "MEMORY.md: ${SIZE}b (rotate if >5000b)" >> "$LOG"

if [ "$SIZE" -lt 5000 ]; then
    echo "Too small, skip" >> "$LOG"
    exit 0
fi

MONTH=$(date -u -d "last month" +%Y-%m)
mkdir -p "$ARCHIVE_DIR"
cp "$ARCHIVE" "$ARCHIVE_DIR/${MONTH}.md"
echo "Archived to archived/${MONTH}.md" >> "$LOG"

# Keep only the header in MEMORY.md
head -5 "$ARCHIVE" > "${ARCHIVE}.tmp"
mv "${ARCHIVE}.tmp" "$ARCHIVE"
echo "MEMORY.md trimmed to header only" >> "$LOG"
