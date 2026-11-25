#!/usr/bin/env bash
# lib/harness-convert.sh — конвертация воркспейса агента между харнесами (для switch-harness.sh).
#
# Рендер конфигов целевого харнеса (config.toml ⇄ settings.json/.mcp.json, глобальные правила,
# .codex home, symlink скиллов) делает штатный agent-template/install.sh: его fill_template —
# skip-if-exists, поэтому память (core/), канал и agent.env/bearer он сохраняет. Здесь — только
# то, чего установщик при переводе сам НЕ делает:
#   1) harness_preseed_identity — посеять идентичность целевого харнеса из уже существующей
#      «души» (а не из шаблона), чтобы ручные правки характера сохранились побайтно;
#   2) harness_reverse_adapt_core — при переходе НА claude вернуть упоминания в доках памяти
#      (установщик адаптирует их только В сторону codex).
#
# Подключается через source; set -e не включает. Нужен python3 и agent-template/codex_workspace.py.

# shellcheck shell=bash

# _hc_root — корень agent-architecture (на два уровня выше этого lib).
_hc_root() { (cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd); }

# harness_preseed_identity <workspace> <to_harness> <agent_id>
# Создаёт файл идентичности целевого харнеса из исходного, если его ещё нет. Идемпотентно:
# если целевой файл уже есть — ничего не делает (установщик его потом не тронет).
harness_preseed_identity() {
  local ws="$1" to="$2" agent="$3"
  local root at py codex_section claude_section span rc=0
  root="$(_hc_root)"; at="$root/agent-template"; py="$at/codex_workspace.py"
  codex_section="$at/templates/codex/channel-section.md"

  if [ "$to" = "codex" ]; then
    [ -f "$ws/AGENTS.src.md" ] && return 0
    if [ ! -f "$ws/CLAUDE.md" ]; then
      echo "convert: нет $ws/CLAUDE.md — нечем посеять идентичность codex" >&2
      return 1
    fi
    python3 "$py" identity --agent-id "$agent" --channel-section "$codex_section" \
      "$ws/CLAUDE.md" "$ws/AGENTS.src.md" || rc=$?
  else
    [ -f "$ws/CLAUDE.md" ] && return 0
    if [ ! -f "$ws/AGENTS.src.md" ]; then
      echo "convert: нет $ws/AGENTS.src.md — нечем посеять идентичность claude" >&2
      return 1
    fi
    # claude-раздел канала берём из шаблона (у codex-born агента своего claude-раздела нет);
    # span codex-раздела = число ## -секций в codex/channel-section.md (канал + web-search).
    claude_section="$(mktemp)"
    awk '
      /^## / {
        if ($0 ~ /^## Talking to the operator \(channel\)/) { inblk=1 }
        else if (inblk) { exit }
      }
      inblk { print }
    ' "$at/templates/CLAUDE.md.template" > "$claude_section"
    if [ ! -s "$claude_section" ]; then
      rm -f "$claude_section"
      echo "convert: в CLAUDE.md.template не найден раздел о канале" >&2
      return 1
    fi
    span="$(grep -c '^## ' "$codex_section")"
    python3 "$py" identity --reverse --agent-id "$agent" --channel-section "$claude_section" \
      --channel-span "$span" "$ws/AGENTS.src.md" "$ws/CLAUDE.md" || rc=$?
    rm -f "$claude_section"
  fi
  return "$rc"
}

# harness_reverse_adapt_core <workspace> <agent_id>
# Обратная адаптация упоминаний в доках памяти при переходе codex→claude (установщик claude их
# не трогает, а они остались с codex-упоминаниями). Идемпотентно, содержимое памяти сохраняется.
harness_reverse_adapt_core() {
  local ws="$1" agent="$2" root at py f
  root="$(_hc_root)"; at="$root/agent-template"; py="$at/codex_workspace.py"
  local files=()
  for f in "$ws/core/AGENTS.md" "$ws/core/USER.md" "$ws/core/rules.md" "$ws/tools/TOOLS.md"; do
    [ -f "$f" ] && files+=("$f")
  done
  [ "${#files[@]}" -eq 0 ] && return 0
  python3 "$py" adapt --reverse --agent-id "$agent" "${files[@]}"
}

# harness_render_agent <agent_id> <target_harness> <model>
# Отрендерить конфиги целевого харнеса поверх существующего воркспейса, переиспользуя штатный
# agent-template/install.sh. Его fill_template — skip-if-exists, поэтому память (core/), канал,
# agent.env/bearer и уже посеянную идентичность он СОХРАНЯЕТ; создаются только недостающие файлы
# целевого харнеса (config.toml ⇄ settings.json/.mcp.json, глобальные правила, .codex home,
# symlink скиллов). Харнес установщик берёт из swarm.env — он уже должен быть переключён.
# Значения берём из сохранённого agent.env; pii-адрес (codex) детерминирован через pii_proxy_port.
harness_render_agent() {
  local agent="$1" target="$2" model="$3"
  local root at lab ws env_file bearer scopes lang pii_env=""
  root="$(_hc_root)"; at="$root/agent-template"
  lab="${CLAUDE_LAB:-$HOME/.claude-lab}"
  ws="$lab/$agent/.claude"; env_file="$ws/agent.env"
  bearer="$(sed -n 's/^AGENT_BEARER=//p'   "$env_file" 2>/dev/null | tail -1)"
  scopes="$(sed -n 's/^AGENT_SCOPES=//p'    "$env_file" 2>/dev/null | tail -1)"
  lang="$(sed -n 's/^SUMMARY_LANGUAGE=//p'  "$env_file" 2>/dev/null | tail -1)"
  : "${lang:=Russian}"; : "${bearer:=CHANGE_ME}"; : "${scopes:=decisions}"
  if [ "$target" = "codex" ]; then
    # shellcheck source=/dev/null
    . "$root/orchestration/lib/agents.sh" 2>/dev/null || true
    # shellcheck source=/dev/null
    . "$root/orchestration/lib/pii.sh" 2>/dev/null || true
    local port; port="$(CLAUDE_LAB="$lab" pii_proxy_port "$agent" 2>/dev/null || true)"
    [ -n "$port" ] && pii_env="http://127.0.0.1:$port"
  fi
  env -i PATH="$PATH" HOME="$HOME" CLAUDE_LAB="$lab" \
    NONINTERACTIVE=1 ENABLE_ALL=n CONFIRM=y \
    AGENT_NAME="$agent" LANGUAGE="$lang" COMMIT_LANGUAGE=English GITHUB_USERNAME=labops \
    PRIMARY_MODEL="$model" MCP_HOST=127.0.0.1 \
    AGENT_BEARER="$bearer" AGENT_SCOPES="$scopes" \
    ${pii_env:+PII_PROXY_URL="$pii_env"} \
    bash "$at/install.sh"
}
