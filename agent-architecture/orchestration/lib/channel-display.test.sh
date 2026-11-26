#!/usr/bin/env bash
# Unit tests for lib/channel-display.sh — что видно в чате, второй агент берёт у первого.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1091
source "$HERE/channel-display.sh"

fail() { echo "FAIL: $1"; exit 1; }
jget() { python3 -I -c 'import json,sys
d = json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."):
    d = d.get(k, "<нет>") if isinstance(d, dict) else "<нет>"
print(json.dumps(d))' "$1" "$2"; }

LAB="$TMP/lab"
FIRST="$LAB/shared/state/developer/telegram"
NEW="$LAB/shared/state/igor/telegram"
mkdir -p "$LAB/developer/.claude" "$LAB/igor/.claude" "$FIRST" "$NEW"
printf 'developer\nigor\n' > "$LAB/agents.conf"
printf '{"webhook": {"enabled": true}, "status": {"suppress_typing_bubble": false, "show_activity": false}, "progress": {"enabled": false}, "task_mirror": {"enabled": false}}\n' \
  > "$FIRST/config.json"
fresh() {
  printf '{"webhook": {"enabled": true}, "status": {"suppress_typing_bubble": false}}\n' > "$NEW/config.json"
  chmod 600 "$NEW/config.json"
}

# 1. Источник — config.json первого агента роя; сам создаваемый не в счёт.
[ "$(channel_display_source "$LAB" igor)" = "$FIRST/config.json" ] || fail "не нашёл config.json первого агента"
[ -z "$(channel_display_source "$LAB" developer)" ] || fail "взял config.json у самого создаваемого агента"

# 2. Выключенная у первого агента плашка выключена и у нового; прочие ключи целы.
fresh
out="$(channel_display_inherit "$FIRST/config.json" "$NEW/config.json")" || fail "inherit вернул ошибку"
[ "$(jget "$NEW/config.json" status.show_activity)" = false ] || fail "show_activity не перенесён"
[ "$(jget "$NEW/config.json" progress.enabled)" = false ] || fail "progress.enabled не перенесён"
[ "$(jget "$NEW/config.json" task_mirror.enabled)" = false ] || fail "task_mirror.enabled не перенесён"
[ "$(jget "$NEW/config.json" status.suppress_typing_bubble)" = false ] || fail "suppress_typing_bubble потерян"
[ "$(jget "$NEW/config.json" webhook.enabled)" = true ] || fail "webhook.enabled потерян"
echo "$out" | grep -q 'status.show_activity=false' || fail "не сказал, что перенёс: $out"
[ "$(stat -c %a "$NEW/config.json")" = 600 ] || fail "права config.json изменились"

# 3. Явный выбор в config.json нового агента не перетирается.
printf '{"status": {"show_activity": true}}\n' > "$NEW/config.json"
channel_display_inherit "$FIRST/config.json" "$NEW/config.json" >/dev/null
[ "$(jget "$NEW/config.json" status.show_activity)" = true ] || fail "перетёр явный show_activity=true"
[ "$(jget "$NEW/config.json" progress.enabled)" = false ] || fail "незаданный progress не перенесён"

# 4. У первого агента ключей нет — умолчания плагина, config.json нового не меняется.
printf '{"webhook": {"enabled": true}}\n' > "$FIRST/config.json"
fresh; before="$(cat "$NEW/config.json")"
out="$(channel_display_inherit "$FIRST/config.json" "$NEW/config.json")"
[ -z "$out" ] && [ "$(cat "$NEW/config.json")" = "$before" ] || fail "без ключей у источника config.json изменён"

# 5. Нет источника, битый источник, не булево значение — без ошибок и без изменений.
fresh; before="$(cat "$NEW/config.json")"
channel_display_inherit "" "$NEW/config.json" || fail "пустой источник — ошибка"
channel_display_inherit "$TMP/nope.json" "$NEW/config.json" || fail "несуществующий источник — ошибка"
printf '{broken' > "$FIRST/config.json"
channel_display_inherit "$FIRST/config.json" "$NEW/config.json" || fail "битый источник — ошибка"
printf '{"status": {"show_activity": "no"}}\n' > "$FIRST/config.json"
channel_display_inherit "$FIRST/config.json" "$NEW/config.json" || fail "строковое значение — ошибка"
[ "$(cat "$NEW/config.json")" = "$before" ] || fail "config.json изменён без годного источника"

# 6. new-agent.sh переносит настройки показа после записи config.json канала.
NA="$HERE/../../skills/create-agent/new-agent.sh"
grep -q 'lib/channel-display.sh' "$NA" || fail "new-agent.sh не подключает channel-display.sh"
write_line="$(grep -n 'suppress_typing_bubble": false}}' "$NA" | head -1 | cut -d: -f1)"
inherit_line="$(grep -n 'channel_display_inherit ' "$NA" | head -1 | cut -d: -f1)"
[ -n "$write_line" ] && [ -n "$inherit_line" ] || fail "нет записи config.json или переноса в new-agent.sh"
[ "$inherit_line" -gt "$write_line" ] || fail "перенос стоит до записи config.json"

echo "channel-display: ok"
