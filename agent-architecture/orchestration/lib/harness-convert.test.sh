#!/usr/bin/env bash
# Юнит-тесты lib/harness-convert.sh: посев идентичности в обе стороны и обратная адаптация.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/harness-convert.sh
. "$HERE/harness-convert.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
check() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $name" >&2; fi
}

# --- claude → codex: посев AGENTS.src.md из CLAUDE.md ---
WS="$TMP/a"; mkdir -p "$WS/core" "$WS/tools"
cat > "$WS/CLAUDE.md" <<'EOF'
# Dev
Правила в ~/.claude/CLAUDE.md.

## Talking to the operator (channel) -- mandatory
Claude: ответь обычным сообщением.

## Shared brain
хвост
EOF
printf 'см ~/.claude/CLAUDE.md\n' > "$WS/core/AGENTS.md"
check "codex: посев прошёл" harness_preseed_identity "$WS" codex dev
check "codex: AGENTS.src.md создан" test -f "$WS/AGENTS.src.md"
check "codex: codex-путь в идентичности" grep -q '\.codex/AGENTS.md' "$WS/AGENTS.src.md"
check "codex: раздел канала стал codex" grep -q 'delivered to the operator automatically' "$WS/AGENTS.src.md"
# идемпотентность: повторный посев ничего не меняет (установщик потом тоже не трогает)
cp "$WS/AGENTS.src.md" "$TMP/snap"
check "codex: посев идемпотентен" harness_preseed_identity "$WS" codex dev
check "codex: файл не изменён повторным посевом" diff -q "$TMP/snap" "$WS/AGENTS.src.md"

# --- codex → claude: посев CLAUDE.md из AGENTS.src.md (codex-born агент, без CLAUDE.md) ---
WS2="$TMP/b"; mkdir -p "$WS2/core" "$WS2/tools"
cp "$WS/AGENTS.src.md" "$WS2/AGENTS.src.md"
printf 'см ~/.claude-lab/dev/.codex/AGENTS.md\n' > "$WS2/core/AGENTS.md"
check "claude: посев прошёл" harness_preseed_identity "$WS2" claude dev
check "claude: CLAUDE.md создан" test -f "$WS2/CLAUDE.md"
check "claude: раздел канала — claude (не codex)" \
  bash -c "! grep -q 'delivered to the operator automatically' '$WS2/CLAUDE.md'"
check "claude: заголовок раздела канала на месте" \
  grep -q '## Talking to the operator (channel)' "$WS2/CLAUDE.md"
check "claude: claude-путь в идентичности" grep -q '~/.claude/CLAUDE.md' "$WS2/CLAUDE.md"
check "claude: codex-путь из идентичности убран" \
  bash -c "! grep -q '\.codex/AGENTS.md' '$WS2/CLAUDE.md'"

# обратная адаптация доков памяти (установщик claude их не трогает)
check "claude: обратная адаптация прошла" harness_reverse_adapt_core "$WS2" dev
check "claude: упоминание в памяти вернулось к claude" \
  grep -q '~/.claude/CLAUDE.md' "$WS2/core/AGENTS.md"

echo "harness-convert.test.sh: $PASS ok, $FAIL fail"
[ "$FAIL" -eq 0 ]
