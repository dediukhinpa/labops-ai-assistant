#!/usr/bin/env bash
# Unit tests for lib/sudo-compat.sh — sudoers без звёздочек и передача окружения
# файлом вместо sudo -E.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck source=sudo-compat.sh
source "$HERE/sudo-compat.sh"

fail() { echo "FAIL: $1"; exit 1; }

# 1. Правила: одна команда без аргументов, ни одной звёздочки (sudo-rs отвергает
#    wildcard в аргументах), пользователь и хелпер подставлены.
rules="$(sudoers_agent_rules agentuser)"
echo "$rules" | grep -v '^#' | grep -q '\*' && fail "в правилах есть звёздочка: $rules"
[ "$(echo "$rules" | grep -vc '^#')" -eq 1 ] || fail "ожидалось одно правило: $rules"
echo "$rules" | grep -qx "agentuser ALL=(root) NOPASSWD: $LABOPS_UNIT_HELPER" \
  || fail "правило не на хелпер: $rules"

# 2. Если на хосте есть visudo — файл проходит проверку синтаксиса.
#    VISUDO можно указать явно (например, visudo из sudo-rs).
VISUDO="${VISUDO:-$(command -v visudo || true)}"
if [ -n "$VISUDO" ]; then
  printf '%s\n' "$rules" > "$TMP/sudoers"
  "$VISUDO" -cf "$TMP/sudoers" >/dev/null 2>&1 || fail "visudo не принял правила: $("$VISUDO" -cf "$TMP/sudoers" 2>&1)"
fi

# 3. Окружение переживает передачу: пробелы, кавычки, $, обратные кавычки,
#    перевод строки, пустое значение. Загрузка — в чистом окружении, как после sudo.
NASTY=$'a b "c" \'d\' $HOME `id` \\e\nline2'
env_file="$TMP/env"
NASTY="$NASTY" EMPTY_VAR="" PREFLIGHT_DONE=1 TG_PLUGIN_DIR="/home/u/x y/tg-plugin" \
  HOME=/root USER=root PATH="/root/bin:$PATH" SUDO_USER=someone \
  bash -c 'source "$1"; env_handoff_write "$2"' _ "$HERE/sudo-compat.sh" "$env_file"
[ "$(stat -c %a "$env_file")" = "600" ] || fail "права файла окружения не 600"

loaded="$(env -i HOME=/home/agent PATH=/usr/bin:/bin bash -c '
  . "$1"
  printf "%s\0" "$NASTY" "${EMPTY_VAR-unset}" "$PREFLIGHT_DONE" "$TG_PLUGIN_DIR" "$HOME" "$PATH" "${USER-unset}" "${SUDO_USER-unset}"
' _ "$env_file" | tr '\0' '\036')"
IFS=$'\036' read -r -d '' v_nasty v_empty v_pre v_tg v_home v_path v_user v_sudo < <(printf '%s' "$loaded")
[ "$v_nasty" = "$NASTY" ] || fail "значение со спецсимволами искажено: [$v_nasty]"
[ "$v_empty" = "" ] || fail "пустая переменная не перенесена"
[ "$v_pre" = "1" ] || fail "PREFLIGHT_DONE не перенесён"
[ "$v_tg" = "/home/u/x y/tg-plugin" ] || fail "TG_PLUGIN_DIR с пробелом искажён"
[ "$v_home" = "/home/agent" ] || fail "HOME root перетёр HOME пользователя"
[ "$v_path" = "/usr/bin:/bin" ] || fail "PATH root перетёр PATH пользователя"
[ "$v_user" = "unset" ] || fail "USER root перенесён"
[ "$v_sudo" = "unset" ] || fail "SUDO_* перенесён"

# 4. Загрузчик: подхватывает файл, удаляет его и передаёт аргументы скрипту как есть.
cat > "$TMP/target.sh" <<'EOF'
printf '%s|' "$PREFLIGHT_DONE" "$#" "$@"
EOF
cp "$env_file" "$TMP/env2"
out="$(env -i PATH=/usr/bin:/bin bash -c "$ENV_HANDOFF_LOADER" labops-install \
  "$TMP/env2" "$TMP/target.sh" --no-agent "два слова")"
[ "$out" = "1|2|--no-agent|два слова|" ] || fail "загрузчик исказил аргументы: $out"
[ -e "$TMP/env2" ] && fail "загрузчик не удалил файл окружения"

echo "sudo-compat: ok"
