#!/usr/bin/env bash
# Юнит-тесты switch-harness.sh: разбор аргументов, dry-run, полный мок-прогон перехода
# (реально установленный агент, systemd/вход/pii замоканы) и автоматический откат при сбое.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"          # orchestration
ROOT="$(cd "$HERE/.." && pwd)"                 # agent-architecture
SWITCH="$HERE/switch-harness.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
check() {
  local name="$1"; shift
  if "$@"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $name" >&2; fi
}
eq() { [ "$1" = "$2" ] || { echo "  ожидалось '$2', получено '$1'" >&2; return 1; }; }
harness_of() { sed -n 's/^HARNESS=//p' "$1/shared/swarm.env"; }

# Пустой каркас лаборатории (для быстрых проверок аргументов).
skel_lab() {
  local lab="$TMP/lab-$1"
  mkdir -p "$lab/shared" "$lab/developer/.claude/core" "$lab/vanessa/.claude/core"
  printf 'HARNESS=%s\n' "${2:-claude}" > "$lab/shared/swarm.env"
  printf '%s' "$lab"
}
# Лаборатория с ОДНИМ реально установленным claude-агентом (для прогонов перехода).
real_lab() {
  local lab="$TMP/real-$1" home="$TMP/home-$1"
  mkdir -p "$lab/shared" "$home"
  printf 'HARNESS=claude\n' > "$lab/shared/swarm.env"
  env -i PATH="$PATH" HOME="$home" CLAUDE_LAB="$lab" NONINTERACTIVE=1 ENABLE_ALL=n CONFIRM=y \
    AGENT_NAME=developer LANGUAGE=Russian COMMIT_LANGUAGE=English GITHUB_USERNAME=op \
    MCP_HOST=127.0.0.1 AGENT_BEARER=bearer-x AGENT_SCOPES=decisions \
    bash "$ROOT/agent-template/install.sh" >/dev/null 2>&1
  echo 'ФАКТ-ПАМЯТИ-SW-4242' >> "$lab/developer/.claude/core/USER.md"
  printf '%s %s' "$lab" "$home"
}
run() { CLAUDE_LAB="$1" bash "$SWITCH" "${@:2}" >/dev/null 2>&1; }

# 1-3. Разбор аргументов и no-op.
lab="$(skel_lab 1)"
run "$lab" gemini; check "неизвестный харнес -> rc 1" eq "$?" "1"
run "$lab";        check "без харнеса -> rc 1" eq "$?" "1"
run "$lab" claude; check "claude→claude no-op -> rc 0" eq "$?" "0"

# 4. dry-run ничего не меняет.
lab="$(skel_lab 4)"
CLAUDE_LAB="$lab" bash "$SWITCH" codex --dry-run >/dev/null 2>&1
check "dry-run -> rc 0" eq "$?" "0"
check "dry-run не создал бэкап" eq "$(ls "$lab/shared/backups" 2>/dev/null | wc -l)" "0"
check "dry-run не тронул swarm.env" eq "$(harness_of "$lab")" "claude"

# 5. Полный прогон claude→codex (systemd/вход/pii/рантайм замоканы): переход состоялся.
read -r lab home <<<"$(real_lab 5)"
CLAUDE_LAB="$lab" HOME="$home" SKIP_LOGIN=1 SKIP_PII_PROXY=1 SKIP_RUNTIME_INSTALL=1 \
  SWITCH_UNITCTL=true bash "$SWITCH" codex >/dev/null 2>&1
check "полный прогон claude→codex -> rc 0" eq "$?" "0"
check "swarm.env переключён на codex" eq "$(harness_of "$lab")" "codex"
check "codex config.toml отрендерен" eq "$([ -f "$lab/developer/.codex/config.toml" ] && echo y)" "y"
check "идентичность codex посеяна" eq "$([ -f "$lab/developer/.claude/AGENTS.src.md" ] && echo y)" "y"
check "память сохранена при переходе" \
  eq "$(grep -c 'ФАКТ-ПАМЯТИ-SW-4242' "$lab/developer/.claude/core/USER.md")" "1"
check "бэкап создан" eq "$([ -d "$lab/shared/backups" ] && echo y)" "y"

# 6. Пустая лаборатория — отказ.
empty="$TMP/empty"; mkdir -p "$empty/shared"; printf 'HARNESS=claude\n' > "$empty/shared/swarm.env"
run "$empty" codex; check "пустой рой -> rc 1" eq "$?" "1"

# 7. Откат: сбой на перезапуске юнитов (SWITCH_UNITCTL=false) -> swarm.env возвращён к claude.
read -r lab home <<<"$(real_lab 7)"
CLAUDE_LAB="$lab" HOME="$home" SKIP_LOGIN=1 SKIP_PII_PROXY=1 SKIP_RUNTIME_INSTALL=1 \
  SWITCH_UNITCTL=false bash "$SWITCH" codex >/dev/null 2>&1
check "сбой перезапуска -> rc 1" eq "$?" "1"
check "откат вернул swarm.env к claude" eq "$(harness_of "$lab")" "claude"
check "откат убрал codex-конфиг" eq "$([ -e "$lab/developer/.codex/config.toml" ] && echo y || echo n)" "n"
check "память цела после отката" \
  eq "$(grep -c 'ФАКТ-ПАМЯТИ-SW-4242' "$lab/developer/.claude/core/USER.md")" "1"

echo "switch-harness.test.sh: $PASS ok, $FAIL fail"
[ "$FAIL" -eq 0 ]
