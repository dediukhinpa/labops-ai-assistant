# shellcheck shell=bash
# Внешние скиллы: ставятся в общую папку лаборатории из чужих репозиториев по
# манифесту skills/external-skills.manifest. Каждый скилл закреплён коммитом
# (тарболл по SHA неизменяем), файлы чужих авторов в этот репозиторий не
# копируются — у них свои лицензии.
#
# Нужен lib/skills.sh (shared_skills_dir, SKILLS_MANAGED_LIST): подключайте его первым.

# Список «<имя> <sha>» того, что поставили мы: по нему пропускаем уже
# актуальное и убираем скиллы, снятые из манифеста. Чужие не трогаем.
SKILLS_EXTERNAL_LIST=".labops-external"
SKILLS_EXTERNAL_DEFAULT_BASE="https://codeload.github.com"
SKILLS_EXTERNAL_TIMEOUT_SEC=120

# sync_external_skills <manifest> <lab-dir>
# Коды: 0 — всё актуально; 1 — нет манифеста или он испорчен (ничего не ставилось);
# 4 — часть скиллов не поставилась (сеть, нет пути в репозитории, симлинк в скилле).
# Остальные скиллы при коде 4 всё равно ставятся: установка агента не должна
# падать из-за недоступного GitHub.
# Env: SKILLS_EXTERNAL_BASE — база URL тарболлов (тесты подставляют file://).
sync_external_skills() {
  local manifest="$1" lab="$2" dst base work list_old
  dst="$(shared_skills_dir "$lab")"
  base="${SKILLS_EXTERNAL_BASE:-$SKILLS_EXTERNAL_DEFAULT_BASE}"
  [ -f "$manifest" ] || { echo "нет манифеста внешних скиллов: $manifest" >&2; return 1; }

  local -a names=() repos=() shas=() paths=()
  local name repo sha path extra lineno=0
  while read -r name repo sha path extra || [ -n "${name:-}" ]; do
    lineno=$((lineno + 1))
    case "${name:-}" in ''|'#'*) continue ;; esac
    if [ -z "${path:-}" ] || [ -n "${extra:-}" ] \
       || ! [[ "$name" =~ ^[a-z0-9][a-z0-9._-]*$ ]] \
       || ! [[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] \
       || ! [[ "$sha" =~ ^[0-9a-f]{40}$ ]] \
       || [[ "$path" == /* ]] || [[ "$path" == *..* ]]; then
      echo "манифест $manifest, строка $lineno: неверный формат ($name)" >&2
      return 1
    fi
    names+=("$name"); repos+=("$repo"); shas+=("$sha"); paths+=("$path")
  done < "$manifest"

  mkdir -p "$dst"
  work="$(mktemp -d)"
  list_old="$dst/$SKILLS_EXTERNAL_LIST"
  [ -f "$list_old" ] || : > "$list_old"

  local -a new_list=()
  local i failed=0 installed=0 kept=0 key extract root src tmp old
  for i in "${!names[@]}"; do
    name="${names[$i]}"; repo="${repos[$i]}"; sha="${shas[$i]}"; path="${paths[$i]}"

    # Локальный скилл репозитория или скилл оператора с тем же именем главнее:
    # внешний его не перезаписывает.
    if [ -f "$dst/$SKILLS_MANAGED_LIST" ] && grep -qxF "$name" "$dst/$SKILLS_MANAGED_LIST"; then
      echo "  внешний скилл $name пропущен: в репозитории есть одноимённый" >&2
      continue
    fi
    if [ -e "$dst/$name" ] && ! grep -q "^$name " "$list_old"; then
      echo "  внешний скилл $name пропущен: в общей папке уже есть одноимённый" >&2
      continue
    fi

    if [ -d "$dst/$name" ] && grep -qxF "$name $sha" "$list_old"; then
      new_list+=("$name $sha"); kept=$((kept + 1))
      continue
    fi

    # Один тарболл на пару репозиторий+коммит: из anthropics/skills ставится семь скиллов.
    key="${repo//\//_}_$sha"
    extract="$work/$key"
    if [ ! -d "$extract" ]; then
      mkdir -p "$extract"
      if ! curl -fsSL --max-time "$SKILLS_EXTERNAL_TIMEOUT_SEC" \
             "$base/$repo/tar.gz/$sha" -o "$work/$key.tgz" 2>/dev/null \
         || ! tar -xzf "$work/$key.tgz" -C "$extract" --no-same-owner --no-same-permissions 2>/dev/null; then
        rm -rf "$extract"; mkdir -p "$extract"
        : > "$extract/.failed"
      fi
    fi
    if [ -e "$extract/.failed" ]; then
      echo "  не скачан $repo@${sha:0:12}: $name не обновлён" >&2
      failed=$((failed + 1))
      # Ранее поставленная версия остаётся в списке: следующий запуск попробует снова.
      old="$(grep -m1 "^$name " "$list_old" || true)"
      if [ -n "$old" ] && [ -d "$dst/$name" ]; then new_list+=("$old"); fi
      continue
    fi

    root="$(find "$extract" -mindepth 1 -maxdepth 1 -type d | head -1)"
    src="$root/$path"
    if [ ! -f "$src/SKILL.md" ]; then
      echo "  $name: в $repo@${sha:0:12} нет $path/SKILL.md" >&2
      failed=$((failed + 1)); continue
    fi
    # Симлинк внутри чужого скилла может вести за его пределы, а tar -cf его бы перенёс.
    if [ -n "$(find "$src" -type l -print -quit)" ]; then
      echo "  $name: в скилле есть симлинки, пропущен" >&2
      failed=$((failed + 1)); continue
    fi

    tmp="$(mktemp -d "$dst/.$name.new.XXXXXX")"
    (cd "$src" && tar -cf - --exclude='__pycache__' --exclude='*.pyc' .) | tar -xf - -C "$tmp"
    chmod 755 "$tmp"
    if [ -e "$dst/$name" ]; then
      old="$dst/.$name.old.$$"
      mv "$dst/$name" "$old"; mv "$tmp" "$dst/$name"; rm -rf "$old"
    else
      mv "$tmp" "$dst/$name"
    fi
    new_list+=("$name $sha"); installed=$((installed + 1))
  done

  # Снятые из манифеста скиллы убираем, только если их ставили мы.
  local listed
  while read -r listed _; do
    [ -n "$listed" ] || continue
    case "$listed" in */*|.*) continue ;; esac
    printf '%s\n' "${names[@]}" | grep -qxF "$listed" && continue
    rm -rf "${dst:?}/$listed"
    echo "  убран снятый внешний скилл: $listed"
  done < "$list_old"

  if [ "${#new_list[@]}" -gt 0 ]; then
    printf '%s\n' "${new_list[@]}" > "$list_old"
  else
    : > "$list_old"
  fi
  rm -rf "$work"
  echo "  внешние скиллы: поставлено $installed, актуальны $kept, ошибок $failed"
  [ "$failed" -eq 0 ] || return 4
}
