#!/usr/bin/env bash
# Профиль оператора (core/USER.md) для второго и следующих агентов.
#
# USER.md описывает человека, а не агента, и курс «Своя ИИ-команда» (урок 08)
# заполняет его у первого агента. Раньше new-agent.sh каждый раз заново
# спрашивал обращение и язык и клал свежий шаблон: новый агент не знал ни имени
# оператора, ни его часового пояса, ни того, как с ним говорить, пока оператор
# не повторит урок. Теперь профиль берётся у первого агента роя, у которого он
# есть; переписывать его под другую роль оператор может потом сам.
#
# Подключается через source, set -e не ставит.
#
#   operator_profile_source <lab_dir> <new_agent_id>  -> путь к USER.md или пусто
#   operator_profile_language <user_md>               -> язык из строки **Language:**
#   operator_profile_copy <src> <workspace>           -> кладёт core/USER.md, если его нет

# shellcheck shell=bash

# shellcheck source=agents.sh
. "$(dirname "${BASH_SOURCE[0]}")/agents.sh"

OPERATOR_PROFILE_REL="core/USER.md"

# operator_profile_source <lab_dir> <new_agent_id> — USER.md первого агента роя,
# кроме создаваемого. Порядок — как в list_agents (agents.conf, иначе каталоги).
# Явный USER_MD_SOURCE важнее: так оператор выбирает, у кого брать профиль.
operator_profile_source() {
  local lab_dir="$1" new_id="$2" id candidate
  if [ -n "${USER_MD_SOURCE:-}" ]; then
    [ -f "$USER_MD_SOURCE" ] && printf '%s\n' "$USER_MD_SOURCE"
    return 0
  fi
  while IFS= read -r id; do
    [ -n "$id" ] && [ "$id" != "$new_id" ] || continue
    candidate="$lab_dir/$id/.claude/$OPERATOR_PROFILE_REL"
    if [ -f "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done < <(CLAUDE_LAB="$lab_dir" list_agents)
  return 0
}

# operator_profile_language <user_md> — значение из «**Language:** X -- …».
# Нужно для SUMMARY_LANGUAGE в agent.env: на этом языке пишутся итоги сессий.
operator_profile_language() {
  sed -n 's/^\*\*Language:\*\*[[:space:]]*\(.*\)$/\1/p' "$1" 2>/dev/null \
    | head -n 1 | sed 's/[[:space:]]*--.*$//; s/[[:space:]]*$//'
}

# operator_profile_copy <src> <workspace> — копия профиля в новый воркспейс.
# Существующий USER.md не трогает (REUSE_EXISTING=1 донастраивает поверх).
operator_profile_copy() {
  local src="$1" dst="$2/$OPERATOR_PROFILE_REL"
  [ -f "$src" ] || return 1
  [ -e "$dst" ] && return 0
  mkdir -p "$(dirname "$dst")" || return 1
  cp -L "$src" "$dst" || return 1
  echo "профиль оператора скопирован: $src -> $dst"
}
