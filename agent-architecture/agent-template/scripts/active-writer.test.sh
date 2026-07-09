#!/usr/bin/env bash
set -euo pipefail

# Unit + integration tests for active-writer.sh (episodic writer + salience).
# Run: bash active-writer.test.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/active-writer.sh"   # provides classify_salience (main is guarded)

pass=0; fail=0
check() { # check <expected> <actual> <label>
    if [ "$1" = "$2" ]; then pass=$((pass+1)); else
        fail=$((fail+1)); echo "  FAIL: $3 -- expected '$1' got '$2'"; fi
}

echo "== classify_salience =="
check ephemeral  "$(classify_salience 'ок')"                              "ru ack"
check ephemeral  "$(classify_salience 'thanks')"                         "en ack"
check ephemeral  "$(classify_salience 'ok.')"                            "ack with dot"
check error      "$(classify_salience 'deploy failed with a traceback')" "en error"
check error      "$(classify_salience 'сервис упал, не работает')"        "ru error"
check decision   "$(classify_salience 'решили взять Postgres')"           "ru decision"
check decision   "$(classify_salience 'we will use pgvector for recall')" "en decision"
check preference "$(classify_salience 'оператор предпочитает краткость')" "ru preference"
check preference "$(classify_salience 'always quote shell variables')"    "en preference"
check fact       "$(classify_salience 'the watchdog runs under systemd')" "default fact"
# a long ack-like string is NOT ephemeral (only short acks are)
check fact       "$(classify_salience 'yes and here is a long substantive follow up about the router')" "long non-ephemeral"

echo "== integration: main appends a tagged entry =="
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export AGENT_WORKSPACE="$TMP/.claude"
mkdir -p "$AGENT_WORKSPACE/core/active"
EP="$AGENT_WORKSPACE/core/active/episodic.md"

printf '%s' 'решили выкатить через systemd' | bash "$SCRIPT_DIR/active-writer.sh" --source stop-hook >/dev/null
grep -q '\[stop-hook\] {decision}' "$EP"; check 0 $? "entry header has source+salience"
grep -q 'systemd' "$EP";               check 0 $? "entry body preserved"

# --text path + snippet cap
bash "$SCRIPT_DIR/active-writer.sh" --source channel --text 'a plain observation' >/dev/null
grep -q '\[channel\] {fact}' "$EP";     check 0 $? "text-arg path + fact class"

# JSON payload extraction
printf '{"assistant_response":"the build broke on CI"}' | bash "$SCRIPT_DIR/active-writer.sh" --source stop-hook >/dev/null
grep -q '{error}' "$EP";                check 0 $? "json payload extraction + error class"

echo ""
echo "active-writer.test.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
