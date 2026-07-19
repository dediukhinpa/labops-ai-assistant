#!/usr/bin/env bash
# brain-flush.test.sh — unit test for brain-flush.sh (no network: curl stubbed).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$HERE/brain-flush.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { echo "✓ $*"; pass=$((pass+1)); }
bad() { echo "✗ $*"; fail=$((fail+1)); }

# fake workspace
WS="$TMP/lab/tester/.claude"
mkdir -p "$WS/core/active" "$WS/logs" "$WS/state"
echo "- did a thing" > "$WS/core/active/episodic.md"
echo "next: continue" > "$WS/core/active/handoff.md"

# curl stub: records the request body, returns success JSON
mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<EOF
#!/usr/bin/env bash
prev=""
for a in "\$@"; do
  [ "\$prev" = "--data" ] && printf '%s' "\$a" > "$TMP/last-request.json"
  prev="\$a"
done
echo '{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"ok"}]}}'
EOF
chmod +x "$TMP/bin/curl"

run() {
  PATH="$TMP/bin:$PATH" AGENT_WORKSPACE="$WS" AGENT_ID=tester \
  AGENT_BEARER="${BEARER_OVERRIDE-realtoken123}" \
  SECOND_BRAIN_MEMORY_URL="${URL_OVERRIDE-http://127.0.0.1:5001/mcp}" \
  bash "$SUT" --reason precompact
}

# 1: placeholder bearer → skip, no request
rm -f "$TMP/last-request.json"
BEARER_OVERRIDE="CHANGE_ME" run
[ ! -f "$TMP/last-request.json" ] && ok "CHANGE_ME bearer → no request" || bad "sent request with placeholder bearer"

# 2: unset URL → skip
rm -f "$TMP/last-request.json"
URL_OVERRIDE="" run
[ ! -f "$TMP/last-request.json" ] && ok "no URL → no request" || bad "sent request without URL"

# 3: real flush → create_handoff call with episodic + handoff content
run; rc=$?
[ $rc -eq 0 ] && ok "flush exits 0" || bad "flush rc=$rc"
if [ -f "$TMP/last-request.json" ]; then
  grep -q '"create_handoff"' "$TMP/last-request.json" && ok "calls create_handoff" || bad "wrong tool"
  grep -q 'did a thing' "$TMP/last-request.json" && ok "episodic tail included" || bad "episodic missing"
  grep -q 'next: continue' "$TMP/last-request.json" && ok "handoff included" || bad "handoff missing"
  grep -q '"from_agent": "tester"' "$TMP/last-request.json" && ok "agent id set" || bad "agent id missing"
else
  bad "no request sent on real flush"
fi

# 4: dedup — same content, second flush skipped
rm -f "$TMP/last-request.json"
run
[ ! -f "$TMP/last-request.json" ] && ok "unchanged content → dedup skip" || bad "dedup failed"

# 5: content changed → flush again
echo "- another thing" >> "$WS/core/active/episodic.md"
rm -f "$TMP/last-request.json"
run
[ -f "$TMP/last-request.json" ] && ok "changed content → flushed again" || bad "no flush after change"

# 6: backend down (curl fails) → still exit 0, marker not advanced
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
exit 7
EOF
echo "- yet another" >> "$WS/core/active/episodic.md"
sha_before="$(cat "$WS/state/brain-flush.sha")"
run; rc=$?
[ $rc -eq 0 ] && ok "backend down → fail-open exit 0" || bad "backend down rc=$rc"
[ "$(cat "$WS/state/brain-flush.sha")" = "$sha_before" ] && ok "marker not advanced on failure" || bad "marker advanced despite failure"

echo
echo "passed=$pass failed=$fail"
[ $fail -eq 0 ]
