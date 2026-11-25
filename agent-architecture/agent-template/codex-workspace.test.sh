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
check "codex: AGENTS.src.md — идентичность из шаблона" grep -q "Dev" "$WS/AGENTS.src.md"
check "codex: временный рендер идентичности не попал в журнал" \
  bash -c "! grep 'Created:' '$X/install.log' | grep -v '$X/' | grep -q ."
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
cat > "$I/AGENTS.src.md" <<'SRC'
# X

@core/a.md
@core/missing.md
@christopher_coderbot
@dataclass
Пишите @core/a.md в тексте — это не импорт.

```python
@dataclass
@core/a.md
```

~~~~md
@core/a.md
~~~
@core/a.md
~~~~

@core/a.md
SRC
printf 'AAA\n' > "$I/core/a.md"
python3 "$HERE/codex_workspace.py" agents-md "$I" 2>/dev/null
check "существующий импорт развёрнут" grep -qx "AAA" "$I/AGENTS.md"
check "импорт развёрнут только вне блоков кода (2 раза)" test "$(grep -c '^AAA$' "$I/AGENTS.md")" = "2"
check "несуществующий импорт остаётся строкой" grep -qx "@core/missing.md" "$I/AGENTS.md"
check "несуществующий импорт — без пометки «файла нет»" bash -c "! grep -q 'файла нет' '$I/AGENTS.md'"
check "@handle в тексте не пропадает" grep -qx "@christopher_coderbot" "$I/AGENTS.md"
check "@dataclass не пропадает (вне блока и в блоке — 2 строки)" test "$(grep -c '^@dataclass$' "$I/AGENTS.md")" = "2"
check 'импорт внутри блока ``` остаётся строкой' bash -c "sed -n '/^\`\`\`python/,/^\`\`\`\$/p' '$I/AGENTS.md' | grep -qx '@core/a.md'"
check "забор ~~~~ не закрывается короткой ~~~ (импорт в нём остаётся строкой дважды)" bash -c "sed -n '/^~~~~md/,/^~~~~\$/p' '$I/AGENTS.md' | test \"\$(grep -c '^@core/a.md\$')\" = 2"
check "@путь не в начале строки не трогается" grep -q "Пишите @core/a.md" "$I/AGENTS.md"

# Вложенный импорт и учёт размера: источники и статус-файл.
printf 'B1\n@c.md\n' > "$I/core/b.md"; printf 'CCC\n' > "$I/core/c.md"
printf '# X\n@core/b.md\n' > "$I/AGENTS.src.md"
python3 "$HERE/codex_workspace.py" agents-md "$I" 2>/dev/null
check "вложенный импорт развёрнут" grep -qx "CCC" "$I/AGENTS.md"
check "статус размера: ok, предел по умолчанию, источники" python3 - "$I" <<'PY'
import json, sys
d = json.load(open(sys.argv[1] + "/state/agents-md-size.json"))
assert d["level"] == "ok" and d["limit"] == 262144, d
assert d["bytes"] == len(open(sys.argv[1] + "/AGENTS.md", "rb").read()), d
assert {s["path"] for s in d["sources"]} == {"AGENTS.src.md", "core/b.md", "core/c.md"}, d
PY

# --- размер AGENTS.md: порог и предел из config.toml агента ---
# Рабочая папка agent/.claude, конфиг agent/.codex/config.toml (как у настоящего агента).
S="$TMP/size/agent"; mkdir -p "$S/.claude/core" "$S/.codex"
printf '# X\n@core/small.md\n@core/decisions.md\n' > "$S/.claude/AGENTS.src.md"
python3 -c 'print("s" * 100)' > "$S/.claude/core/small.md"
python3 -c 'print("d" * 800)' > "$S/.claude/core/decisions.md"
size_status() {  # <поле> — поле статус-файла размера
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' \
    "$S/.claude/state/agents-md-size.json" "$1"
}
build() { python3 "$HERE/codex_workspace.py" agents-md "$S/.claude" 2>"$TMP/size.err"; }

printf 'project_doc_max_bytes = 5000\n' > "$S/.codex/config.toml"
check "размер: сборка при малом размере успешна" build
check "размер: ok" test "$(size_status level)" = "ok"
check "размер: ok — без предупреждений" bash -c "! grep -q 'AGENTS.md занимает' '$TMP/size.err'"

printf 'project_doc_max_bytes = 1500\n' > "$S/.codex/config.toml"
check "размер: сборка выше порога успешна" build
check "размер: warn выше 75% предела" test "$(size_status level)" = "warn"
check "размер: предупреждение называет decisions.md" grep -q "core/decisions.md" "$TMP/size.err"
check "размер: предел из config.toml в статусе" test "$(size_status limit)" = "1500"

printf 'project_doc_max_bytes = 500\n' > "$S/.codex/config.toml"
check "размер: сборка сверх предела НЕ падает (агент стартует)" build
check "размер: over сверх предела" test "$(size_status level)" = "over"
check "размер: ошибка про предел и крупнейший источник" grep -q "при пределе 500 .*core/decisions.md" "$TMP/size.err"
check "размер: AGENTS.md собран целиком, не обрезан" grep -qE "^d{800}$" "$S/.claude/AGENTS.md"

printf 'project_doc_max_bytes = "много"\n' > "$S/.codex/config.toml"
build
check "размер: мусор в config.toml — предел по умолчанию" test "$(size_status limit)" = "262144"
printf 'это не toml [[[\n' > "$S/.codex/config.toml"
build
check "размер: битый config.toml — предел по умолчанию" test "$(size_status limit)" = "262144"
unlink "$S/.codex/config.toml"
build
check "размер: нет config.toml — предел по умолчанию" test "$(size_status limit)" = "262144"

printf '# X\n\nбез раздела канала\n' > "$I/claude.md"
check "нет раздела канала — ошибка" bash -c "! python3 '$HERE/codex_workspace.py' identity --agent-id x --channel-section '$HERE/templates/codex/channel-section.md' '$I/claude.md' '$I/out.md' 2>/dev/null"

# --- Обратимость перевода роя: claude → codex → claude возвращает исходную «душу» ---
# identity --reverse и adapt --reverse нужны switch-harness.sh для обратного перехода.
RT="$TMP/rt"; mkdir -p "$RT"
cat > "$RT/claude.md" <<'EOF'
# Dev

Идентичность. Правила живут в `~/.claude/CLAUDE.md`, ещё раз ~/.claude/CLAUDE.md.

## Talking to the operator (channel) -- mandatory
Claude: ответь обычным сообщением.

## Shared brain
хвост
EOF
cat > "$RT/claude-section.md" <<'EOF'
## Talking to the operator (channel) -- mandatory
Claude: ответь обычным сообщением.
EOF
python3 "$HERE/codex_workspace.py" identity --agent-id dev \
  --channel-section "$HERE/templates/codex/channel-section.md" \
  "$RT/claude.md" "$RT/AGENTS.src.md" 2>/dev/null
check "forward: codex-путь в AGENTS.src.md" grep -q "\.codex/AGENTS.md" "$RT/AGENTS.src.md"
check "forward: раздел канала стал codex" \
  bash -c "! grep -q 'ответь обычным сообщением' '$RT/AGENTS.src.md'"
CODEX_SPAN="$(grep -c '^## ' "$HERE/templates/codex/channel-section.md")"
python3 "$HERE/codex_workspace.py" identity --reverse --agent-id dev \
  --channel-section "$RT/claude-section.md" --channel-span "$CODEX_SPAN" \
  "$RT/AGENTS.src.md" "$RT/claude.rt.md" 2>/dev/null
check "round-trip: CLAUDE.md восстановлен побайтно" diff -q "$RT/claude.md" "$RT/claude.rt.md"

printf 'см. ~/.claude/CLAUDE.md тут\n' > "$RT/doc.md"
python3 "$HERE/codex_workspace.py" adapt --agent-id dev "$RT/doc.md" 2>/dev/null
check "adapt: путь стал codex" grep -q "\.codex/AGENTS.md" "$RT/doc.md"
python3 "$HERE/codex_workspace.py" adapt --reverse --agent-id dev "$RT/doc.md" 2>/dev/null
check "deadapt: путь вернулся к claude" grep -q "~/.claude/CLAUDE.md" "$RT/doc.md"

echo "codex-workspace.test.sh: $PASS ok, $FAIL fail"
[ "$FAIL" -eq 0 ]
