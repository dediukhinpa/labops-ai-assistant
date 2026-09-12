#!/usr/bin/env bash
# Установка и включение systemd-юнита агента от root по узкому правилу sudo.
#
# install.sh кладёт этот файл в /usr/local/sbin/labops-agent-unit (root:root 0755)
# и выдаёт агент-пользователю NOPASSWD ровно на него. Раньше правило перечисляло
# три команды со звёздочкой в аргументах (cp /tmp/claude-agent-*.service ...,
# systemctl enable --now claude-agent-*.service). sudo-rs — штатный sudo в
# Ubuntu 26.04 — такие правила отвергает («wildcards are not allowed in command
# arguments»), файл не проходил visudo, юнит не ставился, и агент после
# «успешной» установки ни разу не запускался (12.09.2026, чистая 26.04).
# Правило на один скрипт без аргументов принимают и sudo (22.04/24.04), и sudo-rs.
#
# Юнит собирается здесь, из root-копии шаблона, а не копируется готовым из /tmp:
# файл в /tmp пишет сам пользователь, и прежнее правило позволяло ему поставить
# юнит с любым содержимым (User=root, ExecStartPre=+...) — то есть получить root.
# Пользователь юнита берётся из SUDO_USER, а не из аргументов.
#
# Использование (от агент-пользователя):
#   sudo -n /usr/local/sbin/labops-agent-unit <agent-id> <orchestration-dir> <lab-dir>
set -euo pipefail

UNIT_TEMPLATE="/usr/local/lib/labops/claude-agent.service.template"
UNIT_DIR="/etc/systemd/system"
SYSTEMCTL="systemctl"
RUN_USER="${SUDO_USER:-}"
# Подмена путей — только для тестов без root. От root переменные окружения
# игнорируются: иначе вызывающий подсунул бы свой шаблон юнита.
if [ "$(id -u)" -ne 0 ]; then
  UNIT_TEMPLATE="${LABOPS_UNIT_TEMPLATE:-$UNIT_TEMPLATE}"
  UNIT_DIR="${LABOPS_UNIT_DIR:-$UNIT_DIR}"
  SYSTEMCTL="${LABOPS_SYSTEMCTL:-$SYSTEMCTL}"
  RUN_USER="${LABOPS_UNIT_USER:-$RUN_USER}"
fi

die() { echo "labops-agent-unit: $*" >&2; exit 1; }

[ "$#" -eq 3 ] || die "использование: labops-agent-unit <agent-id> <orchestration-dir> <lab-dir>"
AGENT_ID="$1" ORCH="$2" LAB="$3"

# Значения попадают в текст юнита: перевод строки или «;» дописали бы свою
# директиву. Поэтому допускаем только безопасный набор символов.
[[ "$AGENT_ID" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || die "недопустимое имя агента: $AGENT_ID"
PATH_RE='^/[A-Za-z0-9._/-]+$'
for p in "$ORCH" "$LAB"; do
  [[ "$p" =~ $PATH_RE ]] || die "недопустимый путь: $p"
  case "/$p/" in */../*) die "путь с '..' не принимается: $p" ;; esac
done
[ -n "$RUN_USER" ] || die "не задан SUDO_USER — запускайте через sudo от агент-пользователя"
[ "$RUN_USER" != "root" ] || die "агент не запускается от root"
[[ "$RUN_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "недопустимое имя пользователя: $RUN_USER"
[ -f "$UNIT_TEMPLATE" ] || die "нет шаблона юнита $UNIT_TEMPLATE — перезапустите install.sh от root"
[ -x "$ORCH/watchdog.sh" ] || die "не найден $ORCH/watchdog.sh"

UNIT_NAME="claude-agent-$AGENT_ID.service"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
sed -e "s|__AGENT__|$AGENT_ID|g" -e "s|__USER__|$RUN_USER|g" \
    -e "s|__ORCH__|$ORCH|g" -e "s|__LAB__|$LAB|g" "$UNIT_TEMPLATE" > "$TMP"
install -m 644 "$TMP" "$UNIT_DIR/$UNIT_NAME"
echo "labops-agent-unit: записан $UNIT_DIR/$UNIT_NAME"
"$SYSTEMCTL" daemon-reload
"$SYSTEMCTL" enable --now "$UNIT_NAME"
echo "labops-agent-unit: $UNIT_NAME включён"
