#!/usr/bin/env bash
# Что агент показывает в чате, пока работает, — для второго и следующих агентов.
#
# Плашка активности (status.show_activity: какой инструмент сейчас идёт), карточка
# прогресса (progress.enabled) и зеркало задач (task_mirror.enabled) настраиваются в
# config.json канала. Оператор выключает их у первого агента, а new-agent.sh создавал
# следующим config.json с умолчаниями плагина, где всё включено: у новых агентов
# плашка, похожая на терминал, снова висела в чате (HRV, 26.11.2026). Теперь эти
# ключи берутся у первого агента роя, у которого есть config.json; чего там нет —
# остаётся умолчанием плагина, как раньше.
#
# Подключается через source, set -e не ставит.
#
#   channel_display_source <lab_dir> <new_agent_id>   -> config.json первого агента или пусто
#   channel_display_inherit <src_config> <dst_config> -> переносит ключи показа, печатает какие

# shellcheck shell=bash

# shellcheck source=agents.sh
. "$(dirname "${BASH_SOURCE[0]}")/agents.sh"

# Ключи config.json, которые определяют, что видно в чате во время работы агента.
CHANNEL_DISPLAY_KEYS="status.show_activity progress.enabled task_mirror.enabled"

# channel_display_source <lab_dir> <new_agent_id> — config.json канала первого агента
# роя, кроме создаваемого. Порядок — как в list_agents (agents.conf, иначе каталоги).
channel_display_source() {
  local lab_dir="$1" new_id="$2" id candidate
  while IFS= read -r id; do
    [ -n "$id" ] && [ "$id" != "$new_id" ] || continue
    candidate="$lab_dir/shared/state/$id/telegram/config.json"
    if [ -f "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done < <(CLAUDE_LAB="$lab_dir" list_agents)
  return 0
}

# channel_display_inherit <src_config> <dst_config> — перенести ключи показа, которые
# явно заданы у источника. Ключ, уже заданный в dst, не трогает: это выбор оператора
# (REUSE_EXISTING=1 донастраивает поверх). Печатает перенесённые «ключ=значение»;
# пусто — переносить нечего. Возвращает не 0, только если dst не удалось записать.
channel_display_inherit() {
  local src="$1" dst="$2"
  [ -n "$src" ] && [ -f "$src" ] && [ -f "$dst" ] || return 0
  python3 -I - "$src" "$dst" "$CHANNEL_DISPLAY_KEYS" <<'PY'
import json
import os
import sys

src_path, dst_path, keys = sys.argv[1], sys.argv[2], sys.argv[3].split()
try:
    with open(src_path, encoding="utf-8") as f:
        src = json.load(f)
    with open(dst_path, encoding="utf-8") as f:
        dst = json.load(f)
except (OSError, ValueError):
    sys.exit(0)  # битый или нечитаемый config.json — оставляем умолчания плагина
if not isinstance(src, dict) or not isinstance(dst, dict):
    sys.exit(0)
taken = []
for key in keys:
    section, name = key.split(".", 1)
    src_section = src.get(section)
    if not isinstance(src_section, dict) or name not in src_section:
        continue
    value = src_section[name]
    if not isinstance(value, bool):
        continue
    dst_section = dst.setdefault(section, {})
    if not isinstance(dst_section, dict) or name in dst_section:
        continue
    dst_section[name] = value
    taken.append(f"{key}={'true' if value else 'false'}")
if not taken:
    sys.exit(0)
tmp = dst_path + ".tmp"
try:
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(dst, f, ensure_ascii=False)
        f.write("\n")
    os.chmod(tmp, os.stat(dst_path).st_mode & 0o777)
    os.replace(tmp, dst_path)
except OSError:
    sys.exit(1)
print(" ".join(taken))
PY
}
