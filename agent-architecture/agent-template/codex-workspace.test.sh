#!/usr/bin/env bash
# Тест рендера рабочей папки агента по харнесу роя (agent-template/install.sh).
#
# claude: всё как раньше (settings.json, .mcp.json, CLAUDE.md, ~/.claude), ничего от Codex.
# codex:  AGENTS.src.md + собранный AGENTS.md, CODEX_HOME/config.toml (валидный TOML, модель
#         по умолчанию, провайдер через pii-proxy), общие правила в CODEX_HOME/AGENTS.md, ни
#         одного файла Claude Code; без pii-proxy агент codex не ставится.
# Побайтное совпадение рендера claude с прежним установщиком проверено при переходе
# (22.11.2026) сравнением с git archive origin/main; здесь — поведенческие проверки.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
check() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $name" >&2; fi
}

# render <каталог> <харнес|-> [доп. переменные...] — установка в песочнице без сети.
render() {
  local out="$1" harness="$2"; shift 2
  mkdir -p "$out/home" "$out/lab"
  if [ "$harness" != "-" ]; then
    mkdir -p "$out/lab/shared"
    printf 'HARNESS=%s\n' "$harness" > "$out/lab/shared/swarm.env"
  fi
  env -i PATH="$PATH" HOME="$out/home" CLAUDE_LAB="$out/lab" NONINTERACTIVE=1 ENABLE_ALL=n \
    CONFIRM=y AGENT_NAME=Dev LANGUAGE=Russian COMMIT_LANGUAGE=English GITHUB_USERNAME=op \
    MCP_HOST=127.0.0.1 AGENT_BEARER=bearer-x AGENT_SCOPES=decisions \
    PII_PROXY_URL=http://127.0.0.1:6391 "$@" \
    bash "$HERE/install.sh" > "$out/install.log" 2>&1
}

# --- claude (по умолчанию: swarm.env нет) ---
C="$TMP/claude"
render "$C" -
WS="$C/lab/dev/.claude"
check "claude: установка прошла" grep -q "Done." "$C/install.log"
check "claude: settings.json" test -f "$WS/settings.json"
check "claude: .mcp.json" test -f "$WS/.mcp.json"
check "claude: CLAUDE.md" test -f "$WS/CLAUDE.md"
check "claude: ~/.claude/CLAUDE.md" test -f "$C/home/.claude/CLAUDE.md"
check "claude: нет .codex" test ! -e "$C/lab/dev/.codex"
check "claude: нет AGENTS.src.md" test ! -e "$WS/AGENTS.src.md"
check "claude: модель sonnet" grep -q '"model": "sonnet"' "$WS/settings.json"

# --- codex ---
X="$TMP/codex"
render "$X" codex
WS="$X/lab/dev/.claude"; CH="$X/lab/dev/.codex"
check "codex: установка прошла" grep -q "Done." "$X/install.log"
check "codex: AGENTS.src.md" test -f "$WS/AGENTS.src.md"
check "codex: AGENTS.md собран" grep -q "begin core/USER.md" "$WS/AGENTS.md"
check "codex: в AGENTS.md нет строк @-импорта" bash -c "! grep -qE '^@' '$WS/AGENTS.md'"
check "codex: раздел канала — вариант Codex" grep -q "delivered to the operator automatically" "$WS/AGENTS.md"
check "codex: раздела канала Claude нет" bash -c "! grep -q 'tmux pane nobody is watching' '$WS/AGENTS.md'"
check "codex: config.toml 600" test "$(stat -c %a "$CH/config.toml")" = "600"
check "codex: CODEX_HOME 700" test "$(stat -c %a "$CH")" = "700"
check "codex: config.toml — валидный TOML с моделью по умолчанию и провайдером pii" python3 - "$CH/config.toml" <<'PY'
import sys, tomllib
d = tomllib.load(open(sys.argv[1], "rb"))
assert d["model"] == "gpt-6.2-sol", d["model"]
assert d["model_provider"] == "labops-pii"
p = d["model_providers"]["labops-pii"]
assert p["base_url"] == "http://127.0.0.1:6391/backend-api/codex", p["base_url"]
assert p["requires_openai_auth"] is True and p["wire_api"] == "responses"
assert d["features"]["enable_request_compression"] is False
servers = d["mcp_servers"]
assert sorted(servers) == ["second_brain-agent_router", "second_brain-memory",
                           "second_brain-memory_router", "second_brain-tasks"], sorted(servers)
assert all(s["bearer_token_env_var"] == "AGENT_BEARER" for s in servers.values())
assert "bearer-x" not in open(sys.argv[1]).read()
PY
check "codex: общие правила в CODEX_HOME/AGENTS.md" grep -q "Commits in English" "$CH/AGENTS.md"
check "codex: правила языков вклеены" grep -q "### Python rules" "$CH/AGENTS.md"
check "codex: нет файлов Claude Code" bash -c "! ls '$WS/settings.json' '$WS/.mcp.json' '$WS/CLAUDE.md' 2>/dev/null | grep -q ."
check "codex: ~/.claude не создан" test ! -e "$X/home/.claude"
check "codex: нет упоминаний Claude в core/tools" bash -c "! grep -rqE 'Claude Code|~/.claude/|CLAUDE\.md' '$WS/core' '$WS/tools'"
check "codex: подагенты — Codex" grep -q "Codex's built-in sub-agents" "$WS/core/AGENTS.md"
check "codex: скрипт сборки AGENTS.md в рабочей папке" test -f "$WS/scripts/codex_workspace.py"

# Повторный прогон: ничего не дублируется (правила языков вклеены один раз).
render "$X" codex
check "codex: повтор — правила языков один раз" test "$(grep -c '### Python rules' "$CH/AGENTS.md")" = "1"

# Без pii-proxy агент codex не ставится.
N="$TMP/nopii"
render "$N" codex PII_PROXY_URL=
check "codex без pii-proxy — отказ" grep -q "needs pii-proxy" "$N/install.log"
check "codex без pii-proxy — config.toml не создан" test ! -e "$N/lab/dev/.codex/config.toml"

# --- codex_workspace.py: импорты ---
I="$TMP/imports"; mkdir -p "$I/core"
printf '# X\n\n@core/a.md\n@core/missing.md\n' > "$I/AGENTS.src.md"
printf 'AAA\n' > "$I/core/a.md"
python3 "$HERE/codex_workspace.py" agents-md "$I" 2>/dev/null
check "импорт развёрнут" grep -qx "AAA" "$I/AGENTS.md"
check "нет файла — пометка, не падение" grep -q "core/missing.md: файла нет" "$I/AGENTS.md"
printf '# X\n\nбез раздела канала\n' > "$I/claude.md"
check "нет раздела канала — ошибка" bash -c "! python3 '$HERE/codex_workspace.py' identity --agent-id x --channel-section '$HERE/templates/codex/channel-section.md' '$I/claude.md' '$I/out.md' 2>/dev/null"

echo "codex-workspace.test.sh: $PASS ok, $FAIL fail"
[ "$FAIL" -eq 0 ]
