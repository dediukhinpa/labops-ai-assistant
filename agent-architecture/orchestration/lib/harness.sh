#!/usr/bin/env bash
# lib/harness.sh — харнес роя: Claude Code или Codex CLI.
#
# Харнес выбирается ОДИН раз, первым вопросом установки, и действует на весь рой:
# все агенты на claude или все на codex (решение владельца 22.11.2026). Смешанного
# роя нет, поэтому значение хранится не у агента, а в общем файле
#   $CLAUDE_LAB/shared/swarm.env   (строка HARNESS=claude|codex)
# и все скрипты узнают харнес только через harness_current.
#
# Файла нет или в нём нет HARNESS — это рой, установленный до появления выбора, и он
# на claude. Поэтому умолчание claude: прежние установки работают без миграции.
#
# Файл читается разбором строки, а не через source: в shared/ лежат и секреты, и
# исполнять оттуда что-либо незачем.
#
# Подключается через source; set -e не включает.
#
# Использование:
#   harness_current                 печатает claude|codex (код 1 — в swarm.env мусор)
#   harness_set_swarm <харнес>      записывает выбор установщика (см. ниже правила)
#   harness_default_model <харнес>  модель по умолчанию для новых агентов
#   harness_bin <харнес>            имя исполняемого файла CLI

# shellcheck shell=bash

HARNESS_DEFAULT="claude"
HARNESS_KNOWN="claude codex"
# Модели по умолчанию выбрал владелец: sonnet для claude (13.09.2026),
# gpt-6.2-sol для codex (22.11.2026). Менять — только с владельцем.
HARNESS_MODEL_CLAUDE="sonnet"
HARNESS_MODEL_CODEX="gpt-6.2-sol"

# harness_swarm_env — путь к общему файлу настроек роя.
harness_swarm_env() {
  printf '%s/shared/swarm.env\n' "${CLAUDE_LAB:-$HOME/.claude-lab}"
}

# harness_is_known <харнес> — 0, если такой харнес поддерживается.
harness_is_known() {
  case " $HARNESS_KNOWN " in
    *" $1 "*) [ -n "$1" ] ;;
    *) return 1 ;;
  esac
}

# harness_read_swarm — значение HARNESS из swarm.env как есть (пусто — не задано).
# Последняя строка выигрывает, как при source; кавычки и пробелы по краям срезаются.
harness_read_swarm() {
  local file value=""
  file="$(harness_swarm_env)"
  [ -f "$file" ] || return 0
  value="$(sed -n 's/^[[:space:]]*HARNESS=//p' "$file" | tail -n 1)"
  value="${value%"${value##*[![:space:]]}"}"
  value="${value#\"}"; value="${value%\"}"
  value="${value#\'}"; value="${value%\'}"
  printf '%s' "$value"
}

# harness_current — харнес роя. Неизвестное значение в swarm.env — ошибка, а не
# тихий откат на claude: агент codex, запущенный как claude, ушёл бы мимо своего
# конфига и прокси.
harness_current() {
  local value
  value="$(harness_read_swarm)"
  if [ -z "$value" ]; then
    printf '%s\n' "$HARNESS_DEFAULT"
    return 0
  fi
  if ! harness_is_known "$value"; then
    echo "harness: неизвестный харнес '$value' в $(harness_swarm_env) (ожидается: $HARNESS_KNOWN)" >&2
    return 1
  fi
  printf '%s\n' "$value"
}

# harness_swarm_has_agents — 0, если в лаборатории уже есть агенты (любого харнеса).
# Смотрим на файлы, а не на list_agents: agents.conf может быть пуст, а воркспейсы — нет.
harness_swarm_has_agents() {
  local lab dir
  lab="${CLAUDE_LAB:-$HOME/.claude-lab}"
  [ -d "$lab" ] || return 1
  for dir in "$lab"/*/; do
    [ -d "$dir" ] || continue
    case "$(basename "$dir")" in shared) continue ;; esac
    if [ -d "$dir/.claude" ] || [ -d "$dir/.codex" ]; then
      return 0
    fi
  done
  return 1
}

# harness_set_swarm <харнес> — запись выбора установщика.
#   - тот же харнес уже записан — ничего не делает;
#   - другой записан (или не записан, то есть claude по умолчанию), а агенты уже
#     есть — отказ: рой целиком на одном харнесе, перевод — отдельная процедура;
#   - иначе пишет swarm.env (права 600, остальные строки файла сохраняются).
harness_set_swarm() {
  local want="$1" have file tmp
  if ! harness_is_known "$want"; then
    echo "harness: неизвестный харнес '$want' (ожидается: $HARNESS_KNOWN)" >&2
    return 1
  fi
  have="$(harness_current)" || return 1
  file="$(harness_swarm_env)"
  if [ "$have" = "$want" ] && [ -n "$(harness_read_swarm)" ]; then
    return 0
  fi
  if [ "$have" != "$want" ] && harness_swarm_has_agents; then
    echo "harness: рой уже работает на $have, а выбран $want. Все агенты роя на одном харнесе;" >&2
    echo "harness: смена харнеса у существующего роя установщиком не делается." >&2
    return 1
  fi
  mkdir -p "$(dirname "$file")"
  tmp="$(mktemp "${file}.XXXXXX")"
  if [ -f "$file" ]; then
    grep -v '^[[:space:]]*HARNESS=' "$file" > "$tmp" || true
  fi
  printf 'HARNESS=%s\n' "$want" >> "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$file"
  echo "harness: харнес роя — $want ($file)"
}

# harness_default_model <харнес> — модель по умолчанию для новых агентов.
harness_default_model() {
  case "$1" in
    claude) printf '%s\n' "$HARNESS_MODEL_CLAUDE" ;;
    codex)  printf '%s\n' "$HARNESS_MODEL_CODEX" ;;
    *) echo "harness: неизвестный харнес '$1'" >&2; return 1 ;;
  esac
}

# harness_bin <харнес> — имя исполняемого файла CLI харнеса.
harness_bin() {
  case "$1" in
    claude|codex) printf '%s\n' "$1" ;;
    *) echo "harness: неизвестный харнес '$1'" >&2; return 1 ;;
  esac
}

# harness_agent_user_homes — домашние каталоги кандидатов в пользователи агентов, по строке на
# каталог. Если задан AGENT_OS_USER — только его. Иначе все пользователи из passwd с домом
# (системные учётки без лаборатории всё равно отсеются по отсутствию swarm.env).
# HARNESS_PASSWD_FILE подменяет базу пользователей (тесты).
harness_agent_user_homes() {
  local passwd
  if [ -n "${HARNESS_PASSWD_FILE:-}" ]; then
    passwd="$(cat "$HARNESS_PASSWD_FILE" 2>/dev/null || true)"
  else
    passwd="$(getent passwd 2>/dev/null || cat /etc/passwd 2>/dev/null || true)"
  fi
  if [ -n "${AGENT_OS_USER:-}" ]; then
    printf '%s\n' "$passwd" | awk -F: -v u="$AGENT_OS_USER" '$1 == u && $6 != "" { print $6 }'
  else
    printf '%s\n' "$passwd" | awk -F: '$1 != "root" && $6 != "" && $6 != "/" { print $6 }'
  fi
}

# harness_read_swarm_agent_users — харнес, уже выбранный в лаборатории пользователя агентов.
#
# Зачем: установщик спрашивает харнес первым, ещё от root — до создания пользователя агентов и
# до перезапуска от его имени. А swarm.env лежит в лаборатории ЭТОГО пользователя, у root
# ($HOME=/root) его нет. Без этой функции повторный `sudo bash install.sh` для роя на codex брал
# умолчание claude: проверка хостов требовала api.anthropic.com и падала, интерактивно харнес
# переспрашивался, а NONINTERACTIVE=1 переписывал swarm.env на claude.
#
# Печатает значение HARNESS (пусто — нигде не выбран). Код 2 — у разных пользователей разные
# харнесы: какой из них имеется в виду, установщик не угадывает.
harness_read_swarm_agent_users() {
  local home value found=""
  while IFS= read -r home; do
    [ -n "$home" ] || continue
    value="$(CLAUDE_LAB="$home/.claude-lab" harness_read_swarm 2>/dev/null || true)"
    [ -n "$value" ] || continue
    if [ -z "$found" ]; then
      found="$value"
    elif [ "$found" != "$value" ]; then
      return 2
    fi
  done < <(harness_agent_user_homes)
  printf '%s' "$found"
  return 0
}
