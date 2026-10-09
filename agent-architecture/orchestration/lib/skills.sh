# shellcheck shell=bash
# Общие скиллы агентов: копия в $CLAUDE_LAB/shared/skills, а не ссылка в репозиторий.
#
# Раньше skills/ каждого агента был симлинком на agent-architecture/skills.
# Удалили или перенесли клон — у всех агентов разом пропадали скиллы, а
# незакоммиченная правка в репозитории мгновенно становилась «живой». Теперь
# установка копирует скиллы в общую папку лаборатории, а агенты ссылаются на неё.
# Обновление после git pull — orchestration/sync-skills.sh.
#
# Скиллы, которые оператор положил в общую папку сам, не трогаются: удаляется
# только то, что ранее скопировала сама установка (список в .labops-managed).

SKILLS_MANAGED_LIST=".labops-managed"
# Путь к agent-architecture, из которого сделана копия: скопированному
# create-agent/new-agent.sh больше не найти репозиторий через ../.. .
SKILLS_REPO_MARK=".labops-repo"

# shared_skills_dir <lab-dir> — путь общей папки скиллов.
shared_skills_dir() {
  printf '%s/shared/skills' "$1"
}

# sync_shared_skills <repo-skills-dir> <lab-dir> [force]
# Копирует каждый скилл репозитория в общую папку. Замена атомарна для
# читателя: новая копия собирается рядом и подменяет старую переименованием,
# так что работающий агент не увидит полускопированный скилл. Тесты
# (*.test.sh, tests/) и кэш Python не копируются.
#
# Общая папка одна на всех агентов, поэтому чужой источник её не перезаписывает:
# если метка указывает на ДРУГОЙ agent-architecture, копирование пропускается
# (код 3). Иначе создание одного агента из устаревшего клона откатывало скиллы
# у всего роя. Явные действия оператора (sync-skills.sh, деплой копии роя)
# передают force=1 — там источник выбран осознанно.
sync_shared_skills() {
  local src="$1" lab="$2" force="${3:-0}" dst name tmp old repo known
  dst="$(shared_skills_dir "$lab")"
  [ -d "$src" ] || { echo "нет каталога скиллов: $src" >&2; return 1; }
  repo="$(cd "$src/.." && pwd)"
  if [ "$force" != "1" ] && [ -f "$dst/$SKILLS_REPO_MARK" ]; then
    known="$(cat "$dst/$SKILLS_REPO_MARK")"
    if [ -n "$known" ] && [ "$known" != "$repo" ]; then
      echo "  общие скиллы оставлены как есть: они из $known, а не из $repo" >&2
      echo "  обновить осознанно: bash $repo/orchestration/sync-skills.sh" >&2
      return 3
    fi
  fi
  mkdir -p "$dst"

  local -a names=()
  for tmp in "$src"/*/; do
    [ -f "$tmp/SKILL.md" ] || continue
    names+=("$(basename "$tmp")")
  done

  for name in "${names[@]}"; do
    tmp="$(mktemp -d "$dst/.$name.new.XXXXXX")"
    (cd "$src/$name" && tar -cf - --exclude='*.test.sh' --exclude='./tests' \
       --exclude='__pycache__' --exclude='*.pyc' .) | tar -xf - -C "$tmp"
    chmod 755 "$tmp"
    if [ -e "$dst/$name" ]; then
      old="$dst/.$name.old.$$"
      mv "$dst/$name" "$old"
      mv "$tmp" "$dst/$name"
      rm -rf "$old"
    else
      mv "$tmp" "$dst/$name"
    fi
  done
  [ -f "$src/README.md" ] && cp "$src/README.md" "$dst/README.md"

  # Снятые из репозитория скиллы убираем, только если их ставили мы.
  if [ -f "$dst/$SKILLS_MANAGED_LIST" ]; then
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      case "$name" in */*|.*) continue ;; esac
      printf '%s\n' "${names[@]}" | grep -qxF "$name" && continue
      rm -rf "${dst:?}/$name"
      echo "  убран снятый скилл: $name"
    done < "$dst/$SKILLS_MANAGED_LIST"
  fi
  printf '%s\n' "${names[@]}" > "$dst/$SKILLS_MANAGED_LIST"
  printf '%s\n' "$repo" > "$dst/$SKILLS_REPO_MARK"
  echo "  общие скиллы (${#names[@]}): $dst"
}

# Метка, которой оператор закрепляет свою ссылку skills/ в воркспейсе агента:
# деплой копии роя зовёт sync-skills.sh при каждом запуске, и без метки такая
# ссылка молча сбрасывалась бы на общую папку раз за разом.
SKILLS_KEEP_MARK=".labops-keep-skills"

# link_workspace_skills <workspace> <lab-dir>
# Направляет <workspace>/skills на общую папку. Не трогает: настоящий каталог
# (код 2 — в нём могут быть скиллы только этого агента) и всё, что закреплено
# меткой .labops-keep-skills (код 3).
link_workspace_skills() {
  local ws="$1" lab="$2" target link tmp old
  target="$(shared_skills_dir "$lab")"
  link="$ws/skills"
  if [ -e "$ws/$SKILLS_KEEP_MARK" ]; then
    echo "  $link оставлен как есть: метка $SKILLS_KEEP_MARK" >&2
    return 3
  fi
  if [ -L "$link" ]; then
    old="$(readlink "$link")"
    [ "$old" = "$target" ] && return 0
    tmp="$ws/.skills.link.$$"
    ln -sfn "$target" "$tmp"
    mv -Tf "$tmp" "$link"
    echo "  $link → $target (было: $old)"
  elif [ -e "$link" ]; then
    echo "  $link — собственный каталог агента, оставлен как есть" >&2
    return 2
  else
    ln -s "$target" "$link"
    echo "  $link → $target"
  fi
}
