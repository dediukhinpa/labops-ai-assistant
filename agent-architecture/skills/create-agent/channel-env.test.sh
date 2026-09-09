#!/usr/bin/env bash
# channel-env.test.sh — channel.env, порождённый new-agent.sh, обязан сорситься.
#
# Регрессия 09.09.2026: агента назвали «LabOps App», и имя ушло в channel.env
# без кавычек. При сорсинге bash попытался выполнить `App`, start-agent.sh
# свалился до `tmux new-session`, сессия не поднялась, канал не занял порт —
# агент был создан и «активен» по systemd, но нем.
#
# Тест берёт НАСТОЯЩИЙ текст генератора из new-agent.sh (heredoc + подготовку
# кавычек над ним) и исполняет его с подставными значениями: копия генератора
# в тесте проверяла бы копию, а не то, что реально пишется на диск.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
NA="$HERE/new-agent.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { echo "✓ $*"; pass=$((pass+1)); }
bad() { echo "✗ $*"; fail=$((fail+1)); }

# Подставные значения: имя с пробелом — то самое, что ломало сорсинг.
AGENT_NAME='LabOps App'
AGENT_ID='labops-app'
BOT_ID='8912846013'
TELEGRAM_BOT_TOKEN='111:AAtest'
TELEGRAM_ALLOWED_USER_IDS='308749463'
TELEGRAM_WEBHOOK_PORT='6002'
WORKSPACE="$TMP/ws"
STATE_DIR="$TMP/state"
CH_ENV="$TMP/channel.env"

# Вырезаем из скрипта подготовку кавычек и сам heredoc — от строки с
# AGENT_NAME_QUOTED до закрывающего ENV.
generator="$(sed -n '/^ *AGENT_NAME_QUOTED=/,/^ENV$/p' "$NA")"
if [ -z "$generator" ]; then
  bad "в new-agent.sh не нашёлся генератор channel.env — проверьте якоря теста"
  echo "passed=$pass failed=$fail"; exit 1
fi
eval "$generator"

# 1. Главное: файл обязан сорситься без единой ошибки.
err="$(bash -c ". '$CH_ENV'" 2>&1)"
if [ -z "$err" ]; then
  ok "channel.env с пробелом в имени сорсится без ошибок"
else
  bad "channel.env не сорсится: $err"
fi

# 2. Имя должно доехать целиком, а не первым словом.
label="$(bash -c ". '$CH_ENV' 2>/dev/null; printf '%s' \"\$TELEGRAM_MEMORY_AGENT_LABEL\"")"
[ "$label" = "LabOps App" ] \
  && ok "метка агента доехала целиком: «$label»" \
  || bad "метка агента побилась: «$label» вместо «LabOps App»"

# 3. Порт по-прежнему читается регуляркой из new-agent.sh (`=\K[0-9]+`) — она
# ищет ЧИСЛО сразу после «=», и кавычки вокруг значения её сломали бы.
port="$(grep -oP '^TELEGRAM_WEBHOOK_PORT=\K[0-9]+' "$CH_ENV" 2>/dev/null || true)"
[ "$port" = "6002" ] \
  && ok "порт читается прежней регуляркой: $port" \
  || bad "порт перестал читаться (получено «$port») — сломается донастройка агента"

# 4. Поиск свободного порта сравнивает строку целиком (`=<порт>$`). Если сюда
# заедут кавычки, занятый порт перестанет находиться и достанется второму агенту.
grep -qE "^TELEGRAM_WEBHOOK_PORT=6002$" "$CH_ENV" \
  && ok "занятый порт находится проверкой на совпадение строки" \
  || bad "проверка занятости порта больше не срабатывает — агенты столкнутся портами"

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
