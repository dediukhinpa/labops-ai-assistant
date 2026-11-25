#!/usr/bin/env bash
# Интеграционный тест конвертации воркспейса: ставим настоящего claude-агента штатным
# agent-template/install.sh, затем конвертируем его в codex теми же либ-функциями, что и
# switch-harness.sh (пред-посев идентичности + рендер целевого харнеса), и проверяем, что
# конфиги codex появились, идентичность взята из «души», а память сохранена нетронутой.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"          # orchestration/lib
ROOT="$(cd "$HERE/../.." && pwd)"              # agent-architecture
AT="$ROOT/agent-template"
# shellcheck source=lib/harness-convert.sh
. "$HERE/harness-convert.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
check() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $name" >&2; fi
}

HOME2="$TMP/home"; LAB="$TMP/lab"; mkdir -p "$HOME2" "$LAB/shared"

# 1. Свежий claude-агент штатным установщиком.
printf 'HARNESS=claude\n' > "$LAB/shared/swarm.env"
env -i PATH="$PATH" HOME="$HOME2" CLAUDE_LAB="$LAB" NONINTERACTIVE=1 ENABLE_ALL=n CONFIRM=y \
  AGENT_NAME=Dev LANGUAGE=Russian COMMIT_LANGUAGE=English GITHUB_USERNAME=op \
  MCP_HOST=127.0.0.1 AGENT_BEARER=bearer-x AGENT_SCOPES=decisions \
  bash "$AT/install.sh" > "$TMP/inst-claude.log" 2>&1
WS="$LAB/dev/.claude"
check "claude-агент создан" test -f "$WS/CLAUDE.md"
check "claude: нет codex-конфига" test ! -e "$LAB/dev/.codex/config.toml"

# Метка в памяти и ручная правка идентичности — должны пережить конвертацию.
echo 'ФАКТ-ПАМЯТИ-XYZ-7788' >> "$WS/core/USER.md"
printf '\nРУЧНАЯ-ПРАВКА-ДУШИ-9900\n' >> "$WS/CLAUDE.md"
cp "$WS/core/USER.md" "$TMP/user.before"

# 2. Конвертация claude → codex теми же функциями, что вызовет switch-harness.sh.
printf 'HARNESS=codex\n' > "$LAB/shared/swarm.env"                       # флип
CLAUDE_LAB="$LAB" harness_preseed_identity "$WS" codex dev                # посев «души»
HOME="$HOME2" CLAUDE_LAB="$LAB" harness_render_agent dev codex gpt-6.2-sol \
  > "$TMP/render-codex.log" 2>&1
RC=$?
check "рендер codex завершился успешно" test "$RC" -eq 0

check "codex: config.toml создан" test -f "$LAB/dev/.codex/config.toml"
check "codex: модель в config.toml" grep -q 'gpt-6.2-sol' "$LAB/dev/.codex/config.toml"
check "codex: AGENTS.src.md из CLAUDE.md" test -f "$WS/AGENTS.src.md"
check "codex: AGENTS.md собран" test -f "$WS/AGENTS.md"
check "codex: ручная правка «души» сохранена" grep -q 'РУЧНАЯ-ПРАВКА-ДУШИ-9900' "$WS/AGENTS.src.md"
check "codex: раздел канала стал codex" grep -q 'delivered to the operator automatically' "$WS/AGENTS.src.md"
check "память сохранена (ФАКТ в core/USER.md)" grep -q 'ФАКТ-ПАМЯТИ-XYZ-7788' "$WS/core/USER.md"
check "settings.json не тронут (инертен до удаления)" test -f "$WS/settings.json"

echo "harness-convert-integration.test.sh: $PASS ok, $FAIL fail"
[ "$FAIL" -eq 0 ]
