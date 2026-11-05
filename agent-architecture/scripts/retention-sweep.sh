#!/usr/bin/env bash
set -euo pipefail

# retention-sweep.sh — сроки хранения журналов и временных файлов (152-ФЗ, этап Е1).
#
# Зачем отдельный скрипт, а не правка писателей: журналы пишут плагин (TypeScript),
# webhook-listener (Python, пишет в /var/log) и хуки агента; общего места, где можно
# задать срок, нет. Один суточный проход надёжнее и не трогает код живых процессов.
#
# Что делает (сроки в днях, переопределяются переменными окружения):
#   <ws>/logs, <state>/logs   живые журналы -> копия в <имя>.<YYYY-MM-DD> и обнуление
#                             (copytruncate: писатели держат файл открытым), затем
#                             всё старше RETENTION_LOG_DAYS удаляется
#   <ws>/outbox, <ws>/tmp     файлы старше RETENTION_OUTBOX_DAYS / RETENTION_TMP_DAYS
#   <state>/inbox, dead-letter, <ws>/state/multichat/chats/*/{inbox,inbox-bad,outbox}
#                             вложения и очереди: RETENTION_INBOX_DAYS
#   <ws>/raw                  RETENTION_RAW_DAYS; по умолчанию 0 = не трогать (это слой
#                             памяти агента, срок решает владелец)
#   каталоги журналов listener  *.log старше RETENTION_LISTENER_DAYS (там полный вывод
#                             агента по межагентным задачам)
#   бэкапы pii-forget          просроченные (метка EXPIRES) удаляются
# Транскрипты CLI (~/.claude/projects) чистит сам CLI через cleanupPeriodDays; там стоит
# бессрочное значение (см. settings.json.template).
#
# НИКОГДА не чистится (решение владельца 05.11.26: бессрочно хранить данные, влияющие на
# память о клиенте и контекст работы с агентом). Скрипт не обращается к этим путям вообще,
# а тест retention-sweep.test.sh проверяет, что они целы при нулевых сроках:
#   <ws>/raw, <ws>/core (в т.ч. core/hot, журнал recall-событий), <ws>/knowledge,
#   <ws>/agents, <ws>/CLAUDE.md, <ws>/scenarios,
#   <ws>/chats/*, <ws>/state/multichat/sessions.json и прочие файлы чатов собеседников
#   (персона, контекст) - чистятся только очереди inbox, inbox-bad, outbox.
# logs/verbose-*.jsonl остаются под сроком: память агента - дневник core/active/episodic.md
# (консолидация читает его, не verbose), а verbose - его дубль-журнал для отладки.
#
# Использование:
#   retention-sweep.sh [--dry-run] [--workspace DIR]... [--state-dir DIR]...
#                      [--listener-log-dir DIR]... [--backup-dir DIR]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DEFAULT_LOG_DAYS=30
DEFAULT_OUTBOX_DAYS=30
DEFAULT_TMP_DAYS=7
DEFAULT_INBOX_DAYS=30
DEFAULT_LISTENER_DAYS=30
DEFAULT_RAW_DAYS=0

LOG_DAYS="${RETENTION_LOG_DAYS:-$DEFAULT_LOG_DAYS}"
OUTBOX_DAYS="${RETENTION_OUTBOX_DAYS:-$DEFAULT_OUTBOX_DAYS}"
TMP_DAYS="${RETENTION_TMP_DAYS:-$DEFAULT_TMP_DAYS}"
INBOX_DAYS="${RETENTION_INBOX_DAYS:-$DEFAULT_INBOX_DAYS}"
LISTENER_DAYS="${RETENTION_LISTENER_DAYS:-$DEFAULT_LISTENER_DAYS}"
RAW_DAYS="${RETENTION_RAW_DAYS:-$DEFAULT_RAW_DAYS}"

DRY_RUN=0
WORKSPACES=()
STATE_DIRS=()
LISTENER_DIRS=()
BACKUP_DIR="$HOME/.pii-forget-backups"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --workspace) WORKSPACES+=("${2:?--workspace требует каталог}"); shift ;;
    --state-dir) STATE_DIRS+=("${2:?--state-dir требует каталог}"); shift ;;
    --listener-log-dir) LISTENER_DIRS+=("${2:?--listener-log-dir требует каталог}"); shift ;;
    --backup-dir) BACKUP_DIR="${2:?--backup-dir требует каталог}"; shift ;;
    *) echo "[retention] неизвестный параметр: $1" >&2; exit 2 ;;
  esac
  shift
done

say() { echo "[retention] $*"; }

# prune_old <каталог> <дни> <метка> — удалить файлы старше срока (0 = выключено).
prune_old() {
  local dir="$1" days="$2" label="$3" n
  [ -d "$dir" ] || return 0
  [ "$days" -gt 0 ] || return 0
  n="$(find "$dir" -type f -mtime "+$days" | wc -l)"
  if [ "$n" -gt 0 ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
      say "$label: подлежит удалению $n (старше $days дн.), dry-run"
    else
      find "$dir" -type f -mtime "+$days" -delete
      find "$dir" -mindepth 1 -type d -empty -delete
      say "$label: удалено $n (старше $days дн.)"
    fi
  fi
}

# rotate_logs <каталог> — copytruncate живых журналов в датированные копии.
rotate_logs() {
  local dir="$1" f stamp
  [ -d "$dir" ] || return 0
  stamp="$(date -u +%Y-%m-%d)"
  while IFS= read -r -d '' f; do
    case "$f" in
      */verbose-*|*.[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) continue ;;
    esac
    if [ "$DRY_RUN" -eq 1 ]; then
      say "ротация: $(basename "$f") -> .$stamp, dry-run"
    else
      # >> : повторный запуск в тот же день дописывает, а не затирает копию.
      cat "$f" >> "$f.$stamp"
      : > "$f"
      say "ротация: $(basename "$f") -> .$stamp"
    fi
  done < <(find "$dir" -maxdepth 1 -type f -size +0 -mtime -1 -print0)
  # Журналы, которых не касались больше суток, ротировать нечего: их возраст
  # и так считается по mtime в prune_old.
  prune_old "$dir" "$LOG_DAYS" "журналы $(basename "$(dirname "$dir")")"
}

for ws in "${WORKSPACES[@]}"; do
  [ -d "$ws" ] || { say "нет каталога workspace, пропуск"; continue; }
  rotate_logs "$ws/logs"
  prune_old "$ws/outbox" "$OUTBOX_DAYS" "outbox"
  prune_old "$ws/tmp" "$TMP_DAYS" "tmp"
  # raw/ - слой памяти: по умолчанию срок 0 (выкл.); включается только явным решением владельца.
  prune_old "$ws/raw" "$RAW_DAYS" "raw"
  for q in "$ws"/state/multichat/chats/*/inbox "$ws"/state/multichat/chats/*/inbox-bad \
           "$ws"/state/multichat/chats/*/outbox; do
    [ -d "$q" ] && prune_old "$q" "$INBOX_DAYS" "очередь чата"
  done
done

for st in "${STATE_DIRS[@]}"; do
  [ -d "$st" ] || { say "нет state-каталога, пропуск"; continue; }
  rotate_logs "$st/logs"
  prune_old "$st/inbox" "$INBOX_DAYS" "inbox плагина"
  prune_old "$st/dead-letter" "$INBOX_DAYS" "dead-letter"
done

for ld in "${LISTENER_DIRS[@]}"; do
  prune_old "$ld" "$LISTENER_DAYS" "журналы listener"
done

if [ -d "$BACKUP_DIR" ] && [ "$DRY_RUN" -eq 0 ]; then
  python3 "$SCRIPT_DIR/pii_forget.py" --user-id 0 --backup-dir "$BACKUP_DIR" \
    --purge-expired-backups
fi
say "готово"
