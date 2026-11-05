#!/usr/bin/env bash
# Установка HTTP-прокси (Squid) для антидетект-браузера Donut Browser.
#
# Зачем: курс «Своя ИИ-команда» просит регистрировать и держать аккаунт Claude под адресом
# из поддерживаемой страны. Свой сервер уже есть, поэтому прокси на нём заменяет VPN-
# приложение: Donut Browser на компьютере студента ходит в сеть через этот сервер.
#
# Что ставится (всё вне домашних каталогов, правит только root):
#   squid + apache2-utils                      пакеты (htpasswd для файла паролей)
#   /etc/squid/squid.conf                      наш конфиг; чужой сохраняется как *.labops-bak-*
#   /etc/squid/labops-passwd                   bcrypt-хэш, root:proxy 640
#   /etc/squid/labops-credentials              общий экземпляр реквизитов, root, 600
#   <дом пользователя>/proxy-credentials.txt   копия: адрес, логин и пароль, 600
#
# Пароль случайный, в вывод установщика НЕ попадает: его читают из файла. Повторный запуск
# идемпотентен: пароль и конфиг остаются, сервис перезапускается только при смене конфига.
# Подключается через source; ждёт ok/warn/note из ui.sh и $SUDO (пусто под root).
#
#   proxy_install <пользователь> <его домашний каталог>  -> 0 прокси работает

# shellcheck shell=bash

# Пути и имена переопределяются окружением — так их подменяет юнит-тест.
: "${LABOPS_PROXY_PORT:=3128}"
: "${LABOPS_PROXY_USER:=labops}"
: "${LABOPS_PROXY_CONF:=/etc/squid/squid.conf}"
: "${LABOPS_PROXY_PASSWD:=/etc/squid/labops-passwd}"
: "${LABOPS_PROXY_AUTH_HELPER:=/usr/lib/squid/basic_ncsa_auth}"
# Общий экземпляр реквизитов: из него файл копируется в дом любого пользователя. Без него
# установка от другого пользователя (--proxy-only от root, потом полная под пользователем
# агентов) создала бы новый пароль, и Donut Browser студента перестал бы пускать.
: "${LABOPS_PROXY_CREDS_STORE:=/etc/squid/labops-credentials}"
: "${LABOPS_PROXY_SERVICE:=squid}"
# Squid в Debian/Ubuntu работает от пользователя proxy и должен читать файл паролей.
: "${LABOPS_PROXY_OWNER:=root}"
: "${LABOPS_PROXY_GROUP:=proxy}"
# Необязательно: пускать порт только с этого адреса/подсети (правило ufw).
: "${LABOPS_PROXY_ALLOW_FROM:=}"
# Куда ходит проверка: заодно видно, не режет ли регион сторона Anthropic.
: "${LABOPS_PROXY_PROBE_URL:=https://api.anthropic.com}"
: "${LABOPS_PROXY_IP_URL:=https://api.ipify.org}"

PROXY_MARKER="# managed-by: labops proxy-install"
# 16 байт = 128 бит случайности; hex безопасен для URL и конфига curl.
PROXY_PASSWORD_BYTES=16
PROXY_HTTP_AUTH_REQUIRED=407
PROXY_HTTP_CONNECT_OK=200
PROXY_HTTP_FORBIDDEN=403
PROXY_PROBE_TIMEOUT_SEC=15
PROXY_READY_TRIES=10
PROXY_READY_POLL_SEC=1
PROXY_IP_TIMEOUT_SEC=5
# Файл с реквизитами лежит в домашнем каталоге — студенту проще его найти.
PROXY_CREDENTIALS_NAME="proxy-credentials.txt"

# proxy_can_install — 0, если на машине есть apt, systemd и права root/sudo.
proxy_can_install() {
  if ! command -v apt-get >/dev/null 2>&1 || ! command -v systemctl >/dev/null 2>&1; then
    warn "прокси ставится только на Linux с apt и systemd — здесь его не поставить"
    return 1
  fi
  if [ "$(id -u)" -ne 0 ] && [ -z "${SUDO:-}" ]; then
    warn "нет sudo — прокси не поставить (нужен root)"
    return 1
  fi
}

# proxy_install_packages — squid и htpasswd; уже стоящие не переустанавливает.
proxy_install_packages() {
  if command -v squid >/dev/null 2>&1 && command -v htpasswd >/dev/null 2>&1; then
    ok "squid и htpasswd уже установлены"
    return 0
  fi
  echo "  ставлю squid и apache2-utils (apt-get)"
  $SUDO apt-get update -y >/dev/null || return 1
  $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y squid apache2-utils >/dev/null \
    || return 1
  ok "squid установлен"
}

# proxy_render_conf — наш squid.conf в stdout.
# Нужен только вход по паролю: сетей «без пароля» (localnet) на облачном сервере нет.
# CONNECT разрешён лишь на 443, обычные запросы — на 80 и 443. forwarded_for выключен,
# чтобы прокси не передавал сайтам домашний адрес клиента в X-Forwarded-For.
proxy_render_conf() {
  cat <<EOF
$PROXY_MARKER
http_port $LABOPS_PROXY_PORT

auth_param basic program $LABOPS_PROXY_AUTH_HELPER $LABOPS_PROXY_PASSWD
auth_param basic children 5
auth_param basic realm labops-proxy
auth_param basic credentialsttl 2 hours
auth_param basic casesensitive on

acl SSL_ports port 443
acl Safe_ports port 80 443
acl CONNECT method CONNECT
acl auth_users proxy_auth REQUIRED

http_access deny !Safe_ports
http_access deny CONNECT !SSL_ports
http_access allow auth_users
http_access deny all

forwarded_for delete
coredump_dir /var/spool/squid
EOF
}

# proxy_write_conf — кладёт конфиг. Возвращает 0 и пишет "changed" в $PROXY_CONF_STATE,
# если файл поменялся; "same", если там уже наш такой же конфиг. Чужой конфиг
# сначала сохраняется рядом с меткой времени, и только потом заменяется.
proxy_write_conf() {
  local tmp ts bak
  tmp="$(mktemp)"
  proxy_render_conf > "$tmp"
  if ! $SUDO squid -k parse -f "$tmp" >/dev/null 2>&1; then
    warn "squid не принял сгенерированный конфиг (squid -k parse) — конфиг не заменён"
    rm -f "$tmp"
    return 1
  fi
  if $SUDO test -f "$LABOPS_PROXY_CONF" && $SUDO cmp -s "$tmp" "$LABOPS_PROXY_CONF"; then
    PROXY_CONF_STATE="same"
    rm -f "$tmp"
    return 0
  fi
  if $SUDO test -f "$LABOPS_PROXY_CONF" \
     && ! $SUDO grep -qF "$PROXY_MARKER" "$LABOPS_PROXY_CONF"; then
    ts="$(date +%Y%m%d%H%M%S)"
    bak="$LABOPS_PROXY_CONF.labops-bak-$ts"
    $SUDO cp -p "$LABOPS_PROXY_CONF" "$bak" || { rm -f "$tmp"; return 1; }
    note "прежний конфиг сохранён: $bak"
  fi
  $SUDO install -m 644 -o "$LABOPS_PROXY_OWNER" "$tmp" "$LABOPS_PROXY_CONF" \
    || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  PROXY_CONF_STATE="changed"
}

# proxy_public_ip — внешний адрес сервера; если спросить не у кого, то адрес исходящего маршрута.
proxy_public_ip() {
  local ip=""
  ip="$(curl -4 -fsS -m "$PROXY_IP_TIMEOUT_SEC" "$LABOPS_PROXY_IP_URL" 2>/dev/null || true)"
  if [ -z "$ip" ] && command -v ip >/dev/null 2>&1; then
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null \
      | awk '{for(i=1;i<NF;i++) if($i=="src"){print $(i+1); exit}}')"
  fi
  printf '%s' "${ip:-<адрес сервера>}"
}

# proxy_ensure_credentials <пользователь> <дом> — пароль и файл реквизитов.
# Если общий экземпляр и файл паролей уже есть, пароль не меняется — только копируется
# в дом пользователя: Donut Browser студента остаётся рабочим при любом повторе.
proxy_ensure_credentials() {
  local user="$1" home="$2" creds="$2/$PROXY_CREDENTIALS_NAME" pw tmp_creds tmp_pw ip group_arg=()
  if $SUDO test -f "$LABOPS_PROXY_CREDS_STORE" && $SUDO test -f "$LABOPS_PROXY_PASSWD"; then
    if ! $SUDO cmp -s "$LABOPS_PROXY_CREDS_STORE" "$creds" 2>/dev/null; then
      $SUDO install -m 600 -o "$user" "$LABOPS_PROXY_CREDS_STORE" "$creds" || return 1
    fi
    ok "пароль прокси прежний (файл $creds)"
    return 0
  fi
  pw="$(openssl rand -hex "$PROXY_PASSWORD_BYTES")" || return 1
  ip="$(proxy_public_ip)"

  # Сначала реквизиты студенту, потом хэш серверу: если оборвётся посередине,
  # пароль не будет принят сервером и потерян, а повтор запуска всё соберёт заново.
  tmp_creds="$(mktemp)"
  printf 'Адрес:  %s\nПорт:   %s\nЛогин:  %s\nПароль: %s\n' \
    "$ip" "$LABOPS_PROXY_PORT" "$LABOPS_PROXY_USER" "$pw" > "$tmp_creds"
  $SUDO install -m 600 -o "$LABOPS_PROXY_OWNER" "$tmp_creds" "$LABOPS_PROXY_CREDS_STORE" \
    || { rm -f "$tmp_creds"; return 1; }
  $SUDO install -m 600 -o "$user" "$tmp_creds" "$creds" || { rm -f "$tmp_creds"; return 1; }
  rm -f "$tmp_creds"

  # Пароль идёт через stdin (htpasswd -i), чтобы он не попал в argv и в `ps`.
  tmp_pw="$(mktemp)"
  if ! printf '%s\n' "$pw" | htpasswd -i -c -B "$tmp_pw" "$LABOPS_PROXY_USER" >/dev/null 2>&1; then
    warn "htpasswd не создал файл паролей"
    rm -f "$tmp_pw"
    return 1
  fi
  if getent group "$LABOPS_PROXY_GROUP" >/dev/null 2>&1; then
    group_arg=(-g "$LABOPS_PROXY_GROUP")
  fi
  # Без группы squid не прочитает файл — тогда делаем его читаемым всем (хэш bcrypt).
  if [ ${#group_arg[@]} -gt 0 ]; then
    $SUDO install -m 640 -o "$LABOPS_PROXY_OWNER" "${group_arg[@]}" "$tmp_pw" "$LABOPS_PROXY_PASSWD"
  else
    $SUDO install -m 644 -o "$LABOPS_PROXY_OWNER" "$tmp_pw" "$LABOPS_PROXY_PASSWD"
  fi || { rm -f "$tmp_pw"; return 1; }
  rm -f "$tmp_pw"
  ok "создан логин $LABOPS_PROXY_USER, пароль записан в $creds"
}

# proxy_open_firewall — открывает порт в ufw, только если он включён.
# Облачные файрволы хостинга (панель провайдера) отсюда не видны — о них говорим словами.
proxy_open_firewall() {
  if ! command -v ufw >/dev/null 2>&1 \
     || ! $SUDO ufw status 2>/dev/null | grep -q '^Status: active'; then
    note "ufw не включён — если порт $LABOPS_PROXY_PORT закрыт в панели хостинга, откройте его"
    return 0
  fi
  if [ -n "$LABOPS_PROXY_ALLOW_FROM" ]; then
    if ! printf '%s' "$LABOPS_PROXY_ALLOW_FROM" | grep -Eq '^[0-9a-fA-F:.]+(/[0-9]+)?$'; then
      warn "LABOPS_PROXY_ALLOW_FROM=$LABOPS_PROXY_ALLOW_FROM не похож на адрес — порт не открыт"
      return 1
    fi
    $SUDO ufw allow from "$LABOPS_PROXY_ALLOW_FROM" to any port "$LABOPS_PROXY_PORT" proto tcp \
      >/dev/null || return 1
    ok "ufw: порт $LABOPS_PROXY_PORT открыт только для $LABOPS_PROXY_ALLOW_FROM"
  else
    $SUDO ufw allow "$LABOPS_PROXY_PORT/tcp" >/dev/null || return 1
    ok "ufw: порт $LABOPS_PROXY_PORT открыт для всех (защита — только пароль)"
  fi
}

# proxy_apply_service <changed|same> — включает автозапуск и перезапускает при новом конфиге.
# `enable --now` не трогает уже работающий юнит, поэтому после смены конфига — restart.
proxy_apply_service() {
  $SUDO systemctl enable "$LABOPS_PROXY_SERVICE" >/dev/null 2>&1 || true
  if [ "$1" = "changed" ] || ! $SUDO systemctl is-active --quiet "$LABOPS_PROXY_SERVICE"; then
    $SUDO systemctl restart "$LABOPS_PROXY_SERVICE" || { warn "squid не перезапустился"; return 1; }
  fi
}

# proxy_probe_code <user|""> <pw|""> — "<код CONNECT> <код ответа>" через наш прокси.
proxy_probe_code() {
  local out
  if [ -n "$1" ]; then
    # Логин и пароль идут конфигом через stdin, а не аргументами curl.
    out="$(printf 'proxy-user = "%s:%s"\n' "$1" "$2" | curl -K - -sS -m "$PROXY_PROBE_TIMEOUT_SEC" \
      -o /dev/null -w '%{http_connect} %{http_code}' \
      -x "http://127.0.0.1:$LABOPS_PROXY_PORT" "$LABOPS_PROXY_PROBE_URL" 2>/dev/null || true)"
  else
    out="$(curl -sS -m "$PROXY_PROBE_TIMEOUT_SEC" -o /dev/null -w '%{http_connect} %{http_code}' \
      -x "http://127.0.0.1:$LABOPS_PROXY_PORT" "$LABOPS_PROXY_PROBE_URL" 2>/dev/null || true)"
  fi
  printf '%s' "${out:-000 000}"
}

# proxy_verify <дом> — без пароля прокси обязан ответить 407, с паролем — пропустить.
proxy_verify() {
  local creds="$1/$PROXY_CREDENTIALS_NAME" pw code connect final i
  pw="$(sed -n 's/^Пароль: //p' "$creds")"
  for ((i = 0; i < PROXY_READY_TRIES; i++)); do
    code="$(proxy_probe_code "" "")"
    [ "${code%% *}" = "$PROXY_HTTP_AUTH_REQUIRED" ] && break
    sleep "$PROXY_READY_POLL_SEC"
  done
  if [ "${code%% *}" != "$PROXY_HTTP_AUTH_REQUIRED" ]; then
    warn "прокси без пароля ответил '$code', ожидали $PROXY_HTTP_AUTH_REQUIRED — проверьте squid"
    return 1
  fi
  code="$(proxy_probe_code "$LABOPS_PROXY_USER" "$pw")"
  connect="${code%% *}"; final="${code##* }"
  if [ "$connect" != "$PROXY_HTTP_CONNECT_OK" ]; then
    warn "с паролем прокси ответил '$connect' (ожидали $PROXY_HTTP_CONNECT_OK) — пароль не принят"
    return 1
  fi
  if [ "$final" = "$PROXY_HTTP_FORBIDDEN" ]; then
    warn "прокси работает, но $LABOPS_PROXY_PROBE_URL отвечает 403: сервер в закрытом регионе"
    warn "Anthropic — выберите сервер в стране из https://www.anthropic.com/supported-countries"
  fi
  ok "прокси проверен: без пароля — $PROXY_HTTP_AUTH_REQUIRED, с паролем — пропускает"
}

# proxy_install <пользователь> <дом> — вся установка по шагам; на первом сбое возвращает 1.
proxy_install() {
  local user="$1" home="$2" ip
  PROXY_CONF_STATE="same"
  proxy_can_install || return 1
  proxy_install_packages || { warn "не удалось установить squid"; return 1; }
  proxy_write_conf || return 1
  proxy_ensure_credentials "$user" "$home" || { warn "пароль прокси не создан"; return 1; }
  proxy_open_firewall || warn "порт в ufw не открыт — клиент может не достучаться"
  proxy_apply_service "$PROXY_CONF_STATE" || return 1
  proxy_verify "$home" || return 1
  ip="$(sed -n 's/^Адрес:  //p' "$home/$PROXY_CREDENTIALS_NAME")"
  ok "прокси работает: $ip:$LABOPS_PROXY_PORT"
  note "логин и пароль: cat $home/$PROXY_CREDENTIALS_NAME (пароль в этот вывод не печатается)"
  note "порт принимает логин и пароль по HTTP без шифрования; чтобы пускать только с вашего"
  note "домашнего IP: LABOPS_PROXY_ALLOW_FROM=<ваш IP> и повторить установку прокси"
}
