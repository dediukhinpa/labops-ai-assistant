#!/usr/bin/env bash
# plugin.test.sh — unit test for provision_plugin (no root, no network).
# Covers: private real dir (not a symlink), legacy symlink migration,
# node_modules shared via symlink, per-agent src/state preserved on refresh,
# two agents getting DISTINCT canonical cwd (the bug this exists to prevent).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/plugin.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { echo "✓ $*"; pass=$((pass+1)); }
bad() { echo "✗ $*"; fail=$((fail+1)); }

# ---- fake shared plugin checkout --------------------------------------------
SRC="$TMP/tg-plugin"
mkdir -p "$SRC/plugin/src" "$SRC/plugin/node_modules/dep" "$SRC/plugin/tests"
echo '{"name":"labops-channel"}' > "$SRC/plugin/package.json"
echo 'console.log(1)'            > "$SRC/plugin/src/server.ts"
mkdir -p "$SRC/plugin/src/state"
echo 'export const store={}'      > "$SRC/plugin/src/state/store.js"
echo '{"mcpServers":{"labops-channel":{}}}' > "$SRC/plugin/.mcp.json"
echo 'x'                         > "$SRC/plugin/node_modules/dep/index.js"

WS_A="$TMP/lab/alpha/.claude"; WS_B="$TMP/lab/beta/.claude"
mkdir -p "$WS_A" "$WS_B"

# ---- case 1: fresh provisioning ---------------------------------------------
provision_plugin "$SRC" "$WS_A" >/dev/null 2>&1 \
  && ok "provision succeeds" || bad "provision failed"
[ -d "$WS_A/labops-tg-plugin" ] && [ ! -L "$WS_A/labops-tg-plugin" ] \
  && ok "workspace plugin is a REAL dir, not a symlink" || bad "still a symlink"
[ -f "$WS_A/labops-tg-plugin/plugin/src/server.ts" ] \
  && ok "sources copied" || bad "sources missing"
# Regression: src/state is SOURCE, not runtime data. Excluding it broke the
# server with "Cannot find module './state/store.js'" on the live host.
[ -f "$WS_A/labops-tg-plugin/plugin/src/state/store.js" ] \
  && ok "src/state copied (it is source, not runtime state)" || bad "src/state missing — server will not start"
[ -L "$WS_A/labops-tg-plugin/plugin/node_modules" ] \
  && ok "node_modules symlinked (not duplicated)" || bad "node_modules not shared"
[ -f "$WS_A/labops-tg-plugin/plugin/node_modules/dep/index.js" ] \
  && ok "node_modules resolves through the symlink" || bad "node_modules broken"
# Regression: .mcp.json registers the labops-channel MCP server. Missing it,
# claude comes up with "no MCP server configured with that name".
grep -q 'labops-channel' "$WS_A/labops-tg-plugin/plugin/.mcp.json" 2>/dev/null \
  && ok "plugin/.mcp.json copied (registers the channel MCP server)" \
  || bad ".mcp.json missing — channel would not register"

# ---- case 2: THE BUG — two agents must not share a canonical cwd ------------
provision_plugin "$SRC" "$WS_B" >/dev/null 2>&1
ca="$(readlink -f "$WS_A/labops-tg-plugin/plugin")"
cb="$(readlink -f "$WS_B/labops-tg-plugin/plugin")"
[ "$ca" != "$cb" ] \
  && ok "agents get DISTINCT canonical cwd ($(basename "$(dirname "$(dirname "$ca")")") vs $(basename "$(dirname "$(dirname "$cb")")"))" \
  || bad "agents still share canonical cwd: $ca"

# ---- case 3: legacy shared symlink is migrated ------------------------------
WS_C="$TMP/lab/gamma/.claude"; mkdir -p "$WS_C"
ln -s "$SRC" "$WS_C/labops-tg-plugin"
[ -L "$WS_C/labops-tg-plugin" ] || bad "test setup: symlink not created"
provision_plugin "$SRC" "$WS_C" >/dev/null 2>&1
[ ! -L "$WS_C/labops-tg-plugin" ] && [ -d "$WS_C/labops-tg-plugin" ] \
  && ok "legacy symlink migrated to a private copy" || bad "legacy symlink survived"
[ "$(readlink -f "$WS_C/labops-tg-plugin/plugin")" != "$ca" ] \
  && ok "migrated agent no longer collides" || bad "migrated agent still collides"

# ---- case 4: refresh picks up upstream changes ------------------------------
echo 'console.log(2)' > "$SRC/plugin/src/server.ts"   # upstream moved on
provision_plugin "$SRC" "$WS_A" >/dev/null 2>&1
grep -q 'console.log(2)' "$WS_A/labops-tg-plugin/plugin/src/server.ts" \
  && ok "sources refreshed from upstream" || bad "sources not refreshed"
[ -f "$WS_A/labops-tg-plugin/plugin/src/state/store.js" ] \
  && ok "src/state still present after refresh" || bad "src/state lost on refresh"

# ---- case 5: missing source → non-zero, no partial dir ----------------------
WS_D="$TMP/lab/delta/.claude"; mkdir -p "$WS_D"
provision_plugin "$TMP/nope" "$WS_D" >/dev/null 2>&1 \
  && bad "expected failure on missing source" || ok "missing source → non-zero"

echo
echo "passed=$pass failed=$fail"
[ $fail -eq 0 ]
