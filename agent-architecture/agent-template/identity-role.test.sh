#!/usr/bin/env bash
# Тест идентичности нового агента: имя, роль и зелёная зона (agent-template/install.sh).
#
# developer (по умолчанию, первый агент роя) — как всегда: зона «код, git, деплой».
# custom (агенты, которых заводит первый) — роль словами оператора из NEW_AGENT_ROLE, как
#   есть (с $, &, |, {{…}}); без неё — заготовка «роль не задана», а не «программист».
# Имя — как назвал оператор («Игорь»), служебный id — из NEW_AGENT_ID.
# Гоняется настоящий install.sh в песочнице: HOME и CLAUDE_LAB во временном каталоге.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
check() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $name" >&2; fi
}

# render <каталог> <харнес|-> [переменные...] — установка без сети и без вопросов.
render() {
  local out="$1" harness="$2"; shift 2
  mkdir -p "$out/home" "$out/lab"
  if [ "$harness" != "-" ]; then
    mkdir -p "$out/lab/shared"
    printf 'HARNESS=%s\n' "$harness" > "$out/lab/shared/swarm.env"
  fi
  env -i PATH="$PATH" HOME="$out/home" CLAUDE_LAB="$out/lab" NONINTERACTIVE=1 ENABLE_ALL=n \
    CONFIRM=y LANGUAGE=Russian COMMIT_LANGUAGE=English GITHUB_USERNAME=op \
    MCP_HOST=127.0.0.1 AGENT_BEARER=bearer-x AGENT_SCOPES=decisions \
    PII_PROXY_URL=http://127.0.0.1:6391 "$@" \
    bash "$HERE/install.sh" > "$out/install.log" 2>&1
}

ROLE="$(cat <<'ROLE'
Помогаю команде рекрутеров Анастасии: вакансии, разбор резюме, вопросы к интервью.
Цены — в $ и ₽; «A & B | C» \ {{NOT_A_PLACEHOLDER}} ${AGENT_BEARER}
ROLE
)"

# --- developer: первый агент, как раньше ---
D="$TMP/dev"
render "$D" - AGENT_NAME=Dev
F="$D/lab/dev/.claude/CLAUDE.md"
check "developer: установка прошла" grep -q "Done." "$D/install.log"
check "developer: зона — код и git" grep -q "Code, scripts, configs" "$F"
check "developer: роль разработчика роя" grep -q "the swarm's developer" "$F"
check "developer: меток не осталось" bash -c "! grep -q 'labops:' '$F'"
check "developer: нет TODO вместо роли" bash -c "! grep -q 'TODO: fill in' '$F'"

# --- custom с ролью: Игорь ---
C="$TMP/custom"
render "$C" - AGENT_NAME=Игорь NEW_AGENT_ID=igor AGENT_PROFILE=custom NEW_AGENT_ROLE="$ROLE"
F="$C/lab/igor/.claude/CLAUDE.md"
check "custom: установка прошла" grep -q "Done." "$C/install.log"
check "custom: воркспейс по NEW_AGENT_ID" test -f "$F"
check "custom: заголовок — имя от оператора" test "$(head -n1 "$F")" = "# Игорь"
check "custom: роль — первая строка как есть" grep -qxF "$(printf '%s\n' "$ROLE" | sed -n 1p)" "$F"
check "custom: роль — спецсимволы как есть" grep -qxF "$(printf '%s\n' "$ROLE" | sed -n 2p)" "$F"
check "custom: bearer не подставлен в текст роли" bash -c "! grep -q 'bearer-x' '$F'"
check "custom: роль в разделе Role" bash -c "sed -n '/^## Role/,/^## SOUL/p' '$F' | grep -q 'рекрутеров'"
check "custom: нет зоны программиста" bash -c "! grep -q 'Code, scripts, configs' '$F'"
check "custom: зона — работа в рамках роли" grep -q "Routine work within my role" "$F"
check "custom: красная зона на месте" grep -q '^\*\*Red zone' "$F"
check "custom: меток не осталось" bash -c "! grep -q 'labops:' '$F'"

# --- custom без роли: заготовка «роль не задана» ---
U="$TMP/unset"
render "$U" - AGENT_NAME=Denchik AGENT_PROFILE=custom
F="$U/lab/denchik/.claude/CLAUDE.md"
check "без роли: установка прошла" grep -q "Done." "$U/install.log"
check "без роли: агент знает, что роль не задана" grep -q "My role is not set yet" "$F"
check "без роли: не выдаёт себя за программиста" bash -c "! grep -q 'Code, scripts, configs' '$F'"

# --- нелатинское имя без NEW_AGENT_ID: отказ, воркспейс не создан ---
N="$TMP/noid"
render "$N" - AGENT_NAME=Игорь AGENT_PROFILE=custom
check "без id: отказ с подсказкой" grep -q "NEW_AGENT_ID" "$N/install.log"
check "без id: воркспейса нет" bash -c "! ls '$N/lab' 2>/dev/null | grep -qv shared"

# --- codex: роль доходит до AGENTS.src.md и собранного AGENTS.md ---
X="$TMP/codex"
render "$X" codex AGENT_NAME=Игорь NEW_AGENT_ID=igor AGENT_PROFILE=custom NEW_AGENT_ROLE="$ROLE"
WS="$X/lab/igor/.claude"
check "codex: установка прошла" grep -q "Done." "$X/install.log"
check "codex: заголовок AGENTS.src.md — имя" test "$(head -n1 "$WS/AGENTS.src.md")" = "# Игорь"
check "codex: роль в AGENTS.src.md" grep -qxF "$(printf '%s\n' "$ROLE" | sed -n 2p)" "$WS/AGENTS.src.md"
check "codex: роль в собранном AGENTS.md" grep -q "рекрутеров Анастасии" "$WS/AGENTS.md"
check "codex: нет зоны программиста" bash -c "! grep -q 'Code, scripts, configs' '$WS/AGENTS.src.md'"

echo "identity-role: $PASS ok, $FAIL failed"
[ "$FAIL" -eq 0 ]
