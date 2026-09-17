#!/usr/bin/env bash
# Обновление копии роя в /opt/labops/ai-assistant от root по узкому правилу sudo.
#
# Агенты работают не из checkout оператора, а из этой копии: оттуда systemd
# запускает watchdog, оттуда берутся шаблон агента, скиллы и плагин канала с
# node_modules. Удалённый, перенесённый или переключённый на другую ветку клон
# больше не роняет живых агентов, а копию агент изменить не может — она
# принадлежит root.
#
# install.sh кладёт этот файл в /usr/local/sbin/labops-runtime-deploy и выдаёт
# агент-пользователю NOPASSWD ровно на него. Откуда брать код, решает не
# вызывающий, а root: checkout и его владелец записаны в /etc/labops/runtime.conf
# при установке. Аргументов, влияющих на результат, нет — только --dry-run.
#
# В копию попадают только файлы под git (HEAD checkout) из agent-architecture и
# tg-plugin, плюс node_modules плагина: секретов, состояния и незакоммиченных
# правок в ней нет. Та же схема, что у install-client-runtime.sh из
# labops-web-app, — копия у роя и клиентов web app общая.
#
# Копия встаёт на место переименованием, прежняя удаляется после. Агенты не
# перезапускаются: уже работающий watchdog дочитывает свой файл, а новые
# вызовы берут новый код. Юниты, которые ещё смотрят в checkout, перечисляются
# с командой перевода — это решение оператора.
#
# Использование (от агент-пользователя или root):
#   sudo -n /usr/local/sbin/labops-runtime-deploy [--dry-run]
set -euo pipefail

CONF="/etc/labops/runtime.conf"
TARGET="/opt/labops/ai-assistant"
UNIT_DIR="/etc/systemd/system"
UNIT_HELPER="/usr/local/sbin/labops-agent-unit"
# Подмена путей — только для тестов без root. От root переменные окружения
# игнорируются: иначе вызывающий подсунул бы свой источник кода.
if [ "$(id -u)" -ne 0 ]; then
  CONF="${LABOPS_RUNTIME_CONF:-$CONF}"
  TARGET="${LABOPS_RUNTIME_DIR:-$TARGET}"
  UNIT_DIR="${LABOPS_UNIT_DIR:-$UNIT_DIR}"
fi

PARTS=("agent-architecture" "tg-plugin")
PLUGIN_MODULES="tg-plugin/plugin/node_modules"
DIR_MODE=0755
NAME_RE='^[A-Za-z_][A-Za-z0-9_-]*$'
PATH_RE='^/[A-Za-z0-9._/-]+$'

log() { printf '[runtime] %s\n' "$*"; }
die() { printf '[runtime ОШИБКА] %s\n' "$*" >&2; exit 1; }

DRY_RUN=0
case "${1:-}" in
  "") ;;
  --dry-run) DRY_RUN=1 ;;
  *) die "использование: labops-runtime-deploy [--dry-run]" ;;
esac
[ "$#" -le 1 ] || die "использование: labops-runtime-deploy [--dry-run]"

# --- настройки, записанные root -------------------------------------------
[ -f "$CONF" ] || die "нет $CONF — перезапустите install.sh (он записывает источник копии)"
if [ "$(id -u)" -eq 0 ]; then
  [ "$(stat -c %u "$CONF")" = 0 ] || die "$CONF принадлежит не root"
  case "$(stat -c %A "$CONF")" in
    ?????w????|????????w?) die "$CONF доступен на запись не только root" ;;
  esac
fi
conf_val() {  # $1=ключ — значение без кавычек; файл не исполняется
  { grep -E "^$1=" "$CONF" || true; } | tail -n 1 | sed -E "s/^$1=//; s/^\"//; s/\"$//"
}
SOURCE="$(conf_val SOURCE)"
OWNER="$(conf_val OWNER)"
LAB="$(conf_val LAB)"
[[ "$SOURCE" =~ $PATH_RE ]] || die "недопустимый SOURCE в $CONF: $SOURCE"
[[ "$OWNER" =~ $NAME_RE ]] || die "недопустимый OWNER в $CONF: $OWNER"
[ "$OWNER" != "root" ] || die "OWNER в $CONF не может быть root"
[ -z "$LAB" ] || [[ "$LAB" =~ $PATH_RE ]] || die "недопустимый LAB в $CONF: $LAB"
for p in "$SOURCE" "$TARGET" ${LAB:+"$LAB"}; do
  case "/$p/" in */../*) die "путь с '..' не принимается: $p" ;; esac
done
case "$TARGET" in
  /*/?*) ;;
  *) die "недопустимый каталог копии: $TARGET" ;;
esac
[ -L "$TARGET" ] && die "$TARGET — символическая ссылка"
OWNER_HOME="$(getent passwd "$OWNER" | cut -d: -f6 || true)"
[ -n "$OWNER_HOME" ] || die "нет пользователя $OWNER"
LAB="${LAB:-$OWNER_HOME/.claude-lab}"

# git от root в чужом checkout откажет («dubious ownership»): читает владелец.
as_owner() {
  if [ "$(id -un)" = "$OWNER" ]; then
    "$@"
  else
    runuser -u "$OWNER" -- "$@"
  fi
}

[ -d "$SOURCE/.git" ] || [ -f "$SOURCE/.git" ] || die "$SOURCE — не checkout git"
for part in "${PARTS[@]}"; do
  [ -d "$SOURCE/$part" ] || die "нет $SOURCE/$part — это не монорепо роя"
done
[ -d "$SOURCE/$PLUGIN_MODULES" ] \
  || die "нет $SOURCE/$PLUGIN_MODULES: сначала bun install в tg-plugin/plugin"
COMMIT="$(as_owner git -C "$SOURCE" rev-parse --verify 'HEAD^{commit}')" \
  || die "не прочитать HEAD в $SOURCE"
log "источник: $SOURCE @ $COMMIT → $TARGET"
if [ -n "$(as_owner git -C "$SOURCE" status --porcelain -- "${PARTS[@]}")" ]; then
  log "ВНИМАНИЕ: в checkout есть незакоммиченные правки — в копию они не попадут"
fi
if [ "$DRY_RUN" = "1" ]; then
  log "(вхолостую) копия ${PARTS[*]} и $PLUGIN_MODULES не менялась"
  exit 0
fi

# --- копия -----------------------------------------------------------------
PARENT="$(dirname "$TARGET")"
BASE="$(basename "$TARGET")"
install -d -m "$DIR_MODE" "$PARENT"
# Один деплой за раз: второй ждёт, а не перемешивает копии.
exec 9>"$PARENT/.$BASE.lock"
flock 9

STAGE="$(mktemp -d "$PARENT/.$BASE.new-XXXXXX")"
OLD="$PARENT/.$BASE.old-$$"
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

as_owner git -C "$SOURCE" archive --format=tar "$COMMIT" -- "${PARTS[@]}" \
  | tar -x -C "$STAGE" --no-same-owner
# Копирует root, но читает чужой дом — tar от имени владельца.
as_owner tar -C "$SOURCE" -cf - "$PLUGIN_MODULES" | tar -x -C "$STAGE" --no-same-owner
printf '%s\n' "$COMMIT" > "$STAGE/COMMIT"
if [ "$(id -u)" -eq 0 ]; then
  chown -R root:root "$STAGE"
fi
# Писать — только владельцу копии (root); права на запуск сохраняются.
chmod -R u+rwX,go+rX,go-w "$STAGE"
chmod "$DIR_MODE" "$STAGE"

[ -x "$STAGE/agent-architecture/orchestration/watchdog.sh" ] \
  || die "в копии нет исполняемого watchdog.sh — ревизия $COMMIT не та"
[ -f "$STAGE/agent-architecture/skills/create-agent/new-agent.sh" ] \
  || die "в копии нет установщика агента — ревизия $COMMIT не та"
[ -f "$STAGE/agent-architecture/systemd/claude-agent.service.template" ] \
  || die "в копии нет шаблона юнита — ревизия $COMMIT не та"

if [ -e "$TARGET" ]; then
  mv "$TARGET" "$OLD"
fi
if ! mv "$STAGE" "$TARGET"; then
  [ -e "$OLD" ] && mv "$OLD" "$TARGET"
  die "копия не встала на место — прежняя возвращена"
fi
rm -rf "$OLD"
log "копия роя: $TARGET ($COMMIT)"

# --- скиллы агентов ----------------------------------------------------------
# Общая копия скиллов в лаборатории обновляется из новой копии роя.
if [ -d "$LAB" ]; then
  as_owner env HOME="$OWNER_HOME" CLAUDE_LAB="$LAB" \
    bash "$TARGET/agent-architecture/orchestration/sync-skills.sh" \
    || log "ВНИМАНИЕ: скиллы агентов не обновились — bash $TARGET/agent-architecture/orchestration/sync-skills.sh"
fi

# --- юниты, которые ещё смотрят в checkout -----------------------------------
ORCH="$TARGET/agent-architecture/orchestration"
stale=0
for unit in "$UNIT_DIR"/claude-agent-*.service; do
  [ -f "$unit" ] || continue
  exec_line="$(grep -m1 '^ExecStart=' "$unit" || true)"
  case "$exec_line" in
    "ExecStart=$ORCH/"*) continue ;;
  esac
  agent="$(basename "$unit" .service)"; agent="${agent#claude-agent-}"
  user="$(sed -n 's/^User=//p' "$unit" | head -n 1)"
  if [ "$stale" = 0 ]; then
    log "юниты ещё запускаются не из копии — перевести (решение оператора):"
    stale=1
  fi
  log "  $agent: ${exec_line#ExecStart=}"
  log "    sudo -u ${user:-<пользователь>} sudo -n $UNIT_HELPER $agent $ORCH $LAB"
  log "    sudo systemctl restart claude-agent-$agent.service"
done
log "готово"
