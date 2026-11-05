#!/usr/bin/env bash
# Unit tests for lib/proxy-install.sh — установка Squid для Donut Browser.
# apt-get, systemctl, squid, htpasswd, openssl, curl и ufw подменены: проверяются пути, права,
# идемпотентность, бэкап чужого конфига и то, что пароль не попадает ни в argv, ни в вывод.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

ME="$(id -un)"
MYGROUP="$(id -gn)"
PASSWORD="0123456789abcdef0123456789abcdef"

BIN="$TMP/bin"; mkdir -p "$BIN"
# PATH теста — только нужные утилиты: реальные squid и htpasswd с хоста не подмешиваются,
# а «установленными» они становятся лишь после вызова заглушки apt-get.
for t in bash env cat sed grep cmp cp install mktemp rm date awk getent id test rev tr touch; do
  p="$(type -P "$t")" && ln -sf "$p" "$BIN/$t"
done
LOG="$TMP/calls.log"; : > "$LOG"
# Что отвечает «прокси»: без пароля 407, с паролем — CONNECT 200 и код целевого сервера.
FINAL_CODE_FILE="$TMP/final-code"; echo 404 > "$FINAL_CODE_FILE"
UNAUTH_CODE_FILE="$TMP/unauth-code"; echo 407 > "$UNAUTH_CODE_FILE"
ACTIVE_FILE="$TMP/active"; rm -f "$ACTIVE_FILE"
UFW_FILE="$TMP/ufw-active"; echo active > "$UFW_FILE"

stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "${3:-$BIN}/$1"; chmod +x "${3:-$BIN}/$1"; }

# squid и htpasswd лежат в PRE и копируются в PATH заглушкой apt-get при install.
PRE="$TMP/pre"; mkdir -p "$PRE"
stub_squid() { stub squid "echo \"squid \$*\" >> \"$LOG\"" "${1:-$PRE}"; }
# htpasswd читает пароль со stdin и пишет «хэш» из него: так видно, что хэш не равен паролю.
stub htpasswd 'pw="$(cat)"; user="${@: -1}"; out="${@: -2:1}"
echo "htpasswd $*" >> '"$LOG"'
printf "%s:\$2y\$stub\$%s\n" "$user" "$(printf "%s" "$pw" | rev)" > "$out"' "$PRE"
stub_squid
stub apt-get "echo \"apt-get \$*\" >> \"$LOG\"
case \"\$*\" in *install*) cp \"$PRE\"/* \"$BIN\"/ ;; esac"
# is-active смотрит на файл-флаг: restart «включает» сервис.
stub systemctl "echo \"systemctl \$*\" >> \"$LOG\"
case \"\$1\" in
  restart|start) touch \"$ACTIVE_FILE\" ;;
  is-active) [ -f \"$ACTIVE_FILE\" ] ;;
esac"
stub openssl "echo $PASSWORD"
stub sleep 'exit 0'
# Тест идёт не от root: «sudo» просто исполняет команду.
stub fakesudo 'exec "$@"'
stub ufw "echo \"ufw \$*\" >> \"$LOG\"
[ \"\$1\" = status ] && { [ -f \"$UFW_FILE\" ] && echo 'Status: active' || echo 'Status: inactive'; }
exit 0"
# curl: адрес сервера, проба без пароля и проба с паролем (конфиг приходит в stdin).
stub curl "echo \"curl \$*\" >> \"$LOG\"
case \"\$*\" in
  *ipify*) echo 203.0.113.7 ;;
  *-K\\ -*) cat > /dev/null; printf '200 %s' \"\$(cat \"$FINAL_CODE_FILE\")\" ;;
  *) printf '%s 000' \"\$(cat \"$UNAUTH_CODE_FILE\")\" ;;
esac"

HOME_A="$TMP/home-agent"; mkdir -p "$HOME_A"
CONF="$TMP/squid/squid.conf"; PASSWD="$TMP/squid/labops-passwd"
mkdir -p "$TMP/squid"

run_install() {
  env PATH="$BIN" SUDO="$BIN/fakesudo" \
    LABOPS_PROXY_CONF="$CONF" LABOPS_PROXY_PASSWD="$PASSWD" \
    LABOPS_PROXY_OWNER="$ME" LABOPS_PROXY_GROUP="$MYGROUP" \
    LABOPS_PROXY_ALLOW_FROM="${ALLOW_FROM:-}" \
    bash -c '
      ok() { echo "OK $*"; }; warn() { echo "WARN $*"; }; note() { echo "NOTE $*"; }
      . "'"$HERE"'/proxy-install.sh"
      proxy_install "'"$ME"'" "'"$HOME_A"'"'
}

CREDS="$HOME_A/proxy-credentials.txt"

# 1. Полная установка.
OUT="$(run_install 2>&1)" || fail "установка не прошла: $OUT"
[ -f "$CONF" ] || fail "нет squid.conf"
grep -qx "# managed-by: labops proxy-install" "$CONF" || fail "в конфиге нет метки labops"
grep -qx "http_port 3128" "$CONF" || fail "в конфиге не тот порт"
grep -q "auth_param basic program .*basic_ncsa_auth $PASSWD" "$CONF" || fail "не тот файл паролей"
grep -qx "http_access allow auth_users" "$CONF" || fail "нет правила для вошедших"
grep -qx "http_access deny all" "$CONF" || fail "нет финального deny all"
grep -q "localnet" "$CONF" && fail "в конфиге есть доступ без пароля (localnet)"
[ -f "$CREDS" ] || fail "нет файла реквизитов"
[ "$(stat -c %a "$CREDS")" = "600" ] || fail "права файла реквизитов не 600: $(stat -c %a "$CREDS")"
grep -qx "Логин:  labops" "$CREDS" || fail "в реквизитах нет логина"
grep -qx "Пароль: $PASSWORD" "$CREDS" || fail "в реквизитах нет пароля"
grep -qx "Адрес:  203.0.113.7" "$CREDS" || fail "в реквизитах не тот адрес"
[ -f "$PASSWD" ] || fail "нет файла паролей squid"
[ "$(stat -c %a "$PASSWD")" = "640" ] || fail "права файла паролей не 640: $(stat -c %a "$PASSWD")"
grep -q '^labops:\$2y\$' "$PASSWD" || fail "в файле паролей нет bcrypt-записи"
grep -qF "$PASSWORD" "$PASSWD" && fail "в файле паролей лежит открытый пароль"
grep -qF "$PASSWORD" "$LOG" && fail "пароль попал в командную строку"
echo "$OUT" | grep -qF "$PASSWORD" && fail "пароль попал в вывод установщика"
grep -q "^apt-get install .*squid apache2-utils" "$LOG" || fail "squid не ставился"
grep -qx "systemctl enable squid" "$LOG" || fail "автозапуск не включён"
grep -qx "systemctl restart squid" "$LOG" || fail "squid не перезапущен после смены конфига"
grep -qx "ufw allow 3128/tcp" "$LOG" || fail "порт в ufw не открыт"
echo "$OUT" | grep -q "прокси работает: 203.0.113.7:3128" || fail "нет итоговой строки: $OUT"

# 2. Повторный запуск: пароль и сервис не трогаются.
BEFORE_PW="$(cat "$CREDS")"; BEFORE_HASH="$(cat "$PASSWD")"; : > "$LOG"
OUT="$(run_install 2>&1)" || fail "повторная установка не прошла: $OUT"
[ "$(cat "$CREDS")" = "$BEFORE_PW" ] || fail "реквизиты сменились при повторе"
[ "$(cat "$PASSWD")" = "$BEFORE_HASH" ] || fail "файл паролей сменился при повторе"
grep -q "restart squid" "$LOG" && fail "squid перезапущен без смены конфига"
grep -q "^htpasswd" "$LOG" && fail "пароль пересоздан при повторе"
grep -q "^apt-get" "$LOG" && fail "пакеты ставились заново"

# 3. Чужой конфиг сохраняется до замены, а не теряется.
echo "http_port 9999" > "$CONF"; : > "$LOG"
OUT="$(run_install 2>&1)" || fail "установка поверх чужого конфига не прошла: $OUT"
ls "$CONF".labops-bak-* >/dev/null 2>&1 || fail "чужой конфиг не сохранён"
grep -qx "http_port 9999" "$CONF".labops-bak-* || fail "в бэкапе не тот конфиг"
grep -qx "http_port 3128" "$CONF" || fail "конфиг не заменён нашим"
grep -qx "systemctl restart squid" "$LOG" || fail "squid не перезапущен после замены"

# 4. Свой же конфиг (метка есть) бэкапом не обрастает.
N_BEFORE="$(ls "$CONF".labops-bak-* | wc -l)"
{ echo "# managed-by: labops proxy-install"; echo "http_port 1"; } > "$CONF"
run_install >/dev/null 2>&1 || fail "повторная замена своего конфига не прошла"
[ "$(ls "$CONF".labops-bak-* | wc -l)" = "$N_BEFORE" ] || fail "свой конфиг попал в бэкап"

# 5. LABOPS_PROXY_ALLOW_FROM открывает порт только для одного адреса.
: > "$LOG"; ALLOW_FROM="198.51.100.4" run_install >/dev/null 2>&1 || fail "установка с ALLOW_FROM упала"
grep -qx "ufw allow from 198.51.100.4 to any port 3128 proto tcp" "$LOG" \
  || fail "нет правила ufw для адреса"
grep -qx "ufw allow 3128/tcp" "$LOG" && fail "порт открыт всем при заданном ALLOW_FROM"

# 6. Мусор в ALLOW_FROM не превращается в правило ufw.
: > "$LOG"; OUT="$(ALLOW_FROM='1.2.3.4; rm -rf /' run_install 2>&1)" || fail "упала на мусорном ALLOW_FROM"
grep -q "^ufw allow" "$LOG" && fail "мусорный ALLOW_FROM дошёл до ufw"
echo "$OUT" | grep -q "не похож на адрес" || fail "нет предупреждения про ALLOW_FROM"

# 7. ufw выключен — правило не добавляется, студент получает подсказку про панель хостинга.
rm -f "$UFW_FILE"; : > "$LOG"
OUT="$(run_install 2>&1)" || fail "упала при выключенном ufw"
grep -q "^ufw allow" "$LOG" && fail "правило ufw добавлено при выключенном ufw"
echo "$OUT" | grep -q "ufw не включён" || fail "нет подсказки про панель хостинга"
echo active > "$UFW_FILE"

# 8. Регион закрыт (403 от целевого сервера) — прокси работает, но об этом честное предупреждение.
echo 403 > "$FINAL_CODE_FILE"
OUT="$(run_install 2>&1)" || fail "403 от Anthropic не должен ронять установку: $OUT"
echo "$OUT" | grep -q "закрытом регионе" || fail "нет предупреждения про закрытый регион"
echo 404 > "$FINAL_CODE_FILE"

# 9. Прокси пускает без пароля (нет 407) — это провал: открытый прокси недопустим.
echo 200 > "$UNAUTH_CODE_FILE"
run_install >/dev/null 2>&1 && fail "установка прошла, хотя прокси пускает без пароля"
echo 407 > "$UNAUTH_CODE_FILE"

# 10. squid не принял конфиг — старый конфиг остаётся на месте.
stub squid 'exit 1'
echo "http_port 7777" > "$CONF"
run_install >/dev/null 2>&1 && fail "установка прошла при отвергнутом конфиге"
grep -qx "http_port 7777" "$CONF" || fail "конфиг заменён, хотя squid его отверг"
stub_squid "$BIN"

# 11. Без apt-get (macOS и т.п.) прокси не ставится и говорит об этом.
NOAPT="$TMP/noapt"; mkdir -p "$NOAPT"
for t in bash env cat sed grep rev date mkdir install rm mktemp cmp cp awk id getent \
         stat printf tr head; do
  p="$(type -P "$t")" && ln -sf "$p" "$NOAPT/$t"
done
OUT="$(env PATH="$NOAPT" SUDO="" bash -c '
  ok() { :; }; warn() { echo "WARN $*"; }; note() { :; }
  . "'"$HERE"'/proxy-install.sh"; proxy_install x /tmp' 2>&1)" \
  && fail "без apt-get установка не должна проходить"
echo "$OUT" | grep -q "только на Linux с apt и systemd" || fail "нет объяснения про apt: $OUT"

echo "OK: proxy-install.sh — все проверки пройдены"
