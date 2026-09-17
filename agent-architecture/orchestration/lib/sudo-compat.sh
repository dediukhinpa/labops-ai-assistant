#!/usr/bin/env bash
# Совместимость установки с обеими реализациями sudo: классическим sudo
# (Ubuntu 22.04/24.04) и sudo-rs (штатный в Ubuntu 26.04).
#
# У sudo-rs два отличия, о которые спотыкалась установка:
#   1. в sudoers нельзя ставить звёздочку в аргументах команды — файл целиком
#      не проходит visudo, и агент-пользователь остаётся без прав на юнит;
#   2. флаг -E не поддерживается («'-E' is ignored»), поэтому переменные
#      установщика (PREFLIGHT_DONE, TG_PLUGIN_DIR, INSTALL_TG_LOCAL, ...) не
#      доходили до перезапуска под агент-пользователем.

# shellcheck shell=bash

LABOPS_UNIT_HELPER="/usr/local/sbin/labops-agent-unit"
LABOPS_UNIT_TEMPLATE_ROOT="/usr/local/lib/labops/claude-agent.service.template"
# Копия роя вне домашних каталогов: оркестрация, шаблон агента, скиллы и
# плагин канала с зависимостями. Её же ставит install-client-runtime.sh из
# labops-web-app для агентов клиентов — структура и источник совпадают.
LABOPS_RUNTIME_DIR="/opt/labops/ai-assistant"
LABOPS_RUNTIME_HELPER="/usr/local/sbin/labops-runtime-deploy"
LABOPS_RUNTIME_CONF="/etc/labops/runtime.conf"

# sudoers_agent_rules <пользователь> [unit-helper] [runtime-helper] — правила
# sudoers для агент-пользователя. Команды указаны без аргументов: так sudo
# разрешает любые аргументы, а проверяют их сами хелперы. Звёздочек нет —
# sudo-rs принимает.
sudoers_agent_rules() {
  local user="$1" helper="${2:-$LABOPS_UNIT_HELPER}"
  local runtime="${3:-$LABOPS_RUNTIME_HELPER}"
  printf '# Автосоздано labops-agent-architecture/install.sh. Разрешает %s\n' "$user"
  printf '# без пароля ставить и включать только юниты claude-agent-<id>.service\n'
  printf '# и обновлять копию роя в %s из checkout, записанного root.\n' "$LABOPS_RUNTIME_DIR"
  printf '%s ALL=(root) NOPASSWD: %s\n' "$user" "$helper"
  printf '%s ALL=(root) NOPASSWD: %s\n' "$user" "$runtime"
}

# Переменные, которые sudo выставляет целевому пользователю сам: переносить их
# из окружения root нельзя — агент получил бы HOME и PATH root. SHELLOPTS и
# BASHOPTS в bash только для чтения: их export в файле дал бы ошибку при загрузке.
ENV_HANDOFF_SKIP_RE='^(HOME|USER|LOGNAME|SHELL|MAIL|PATH|PWD|OLDPWD|SHLVL|_|SHELLOPTS|BASHOPTS|BASH_[A-Z_]+|SUDO_[A-Z_]+|XDG_[A-Z_]+|DBUS_[A-Z_]+)$'

# env_handoff_write <файл> — сохранить экспортированные переменные текущего
# окружения в файл, пригодный для `source`. Замена `sudo -E`: одинаково работает
# с sudo и sudo-rs и не зависит от env_keep/SETENV в sudoers. Значения идут через
# файл 600, а не аргументами `env NAME=...`, чтобы токены (GITHUB_TOKEN,
# TELEGRAM_BOT_TOKEN) не светились в списке процессов.
env_handoff_write() {
  local file="$1" name
  ( umask 077; : > "$file" )
  while IFS= read -r name; do
    [[ "$name" =~ $ENV_HANDOFF_SKIP_RE ]] && continue
    # Имена с точками и прочим, что bash не примет в export, пропускаем.
    [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    printf 'export %s=%q\n' "$name" "${!name}" >> "$file"
  done < <(compgen -e)
}

# Команда, которой перезапущенный под агент-пользователем bash подхватывает файл
# и сразу его удаляет: $1 — файл, дальше — скрипт и его аргументы.
# shellcheck disable=SC2016
ENV_HANDOFF_LOADER='f="$1"; shift; . "$f"; rm -f "$f"; exec bash "$@"'
