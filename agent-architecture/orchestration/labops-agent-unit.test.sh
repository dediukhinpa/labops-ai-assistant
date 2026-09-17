#!/usr/bin/env bash
# Unit tests for orchestration/labops-agent-unit.sh — root-хелпер автостарта.
# Гоняется не от root: пути юнитов, шаблон, systemctl и пользователь подменены
# переменными LABOPS_*, которые хелпер уважает только вне root.
# Главное: юнит собирается из шаблона с пользователем из SUDO_USER, а всё, что
# могло бы дописать в юнит свою директиву или указать на root, отвергается
# до записи файла.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HELPER="$HERE/labops-agent-unit.sh"
TEMPLATE="$HERE/../systemd/claude-agent.service.template"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

[ "$(id -u)" -ne 0 ] || { echo "labops-agent-unit: пропуск — тест не гоняется от root"; exit 0; }
[ -f "$TEMPLATE" ] || fail "нет шаблона $TEMPLATE"

mkdir -p "$TMP/units" "$TMP/orch" "$TMP/lab" "$TMP/bin"
printf '#!/usr/bin/env bash\n' > "$TMP/orch/watchdog.sh"; chmod +x "$TMP/orch/watchdog.sh"
# Подставной systemctl: только записывает вызовы.
cat > "$TMP/bin/systemctl" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$TMP/systemctl.log"
EOF
chmod +x "$TMP/bin/systemctl"

# run <user> <args...> — код возврата в RC, вывод в $TMP/out.
run() {
  local user="$1"; shift
  RC=0
  : > "$TMP/systemctl.log"
  env -u SUDO_USER LABOPS_UNIT_TEMPLATE="$TEMPLATE" LABOPS_UNIT_DIR="$TMP/units" \
      LABOPS_SYSTEMCTL="$TMP/bin/systemctl" LABOPS_UNIT_USER="$user" \
      bash "$HELPER" "$@" >"$TMP/out" 2>&1 </dev/null || RC=$?
}

# 1. Нормальный путь: юнит записан, плейсхолдеров не осталось, systemctl вызван.
run agentuser dev "$TMP/orch" "$TMP/lab"
[ "$RC" -eq 0 ] || fail "нормальный вызов упал: $(cat "$TMP/out")"
U="$TMP/units/claude-agent-dev.service"
[ -f "$U" ] || fail "юнит не записан"
grep -q '__' "$U" && fail "в юните остались плейсхолдеры"
grep -qx 'User=agentuser' "$U" || fail "User не из SUDO_USER"
grep -qF "ExecStart=$TMP/orch/watchdog.sh dev" "$U" || fail "ExecStart не на watchdog агента"
grep -qF "append:$TMP/lab/dev/logs/watchdog.log" "$U" || fail "лог не в каталоге агента"
[ "$(stat -c %a "$U")" = "644" ] || fail "права юнита не 644"
[ -d "$TMP/lab/dev/logs" ] || fail "каталог логов не создан — юнит упадёт с 209/STDOUT"
grep -qx 'daemon-reload' "$TMP/systemctl.log" || fail "нет daemon-reload"
grep -qx 'enable --now claude-agent-dev.service' "$TMP/systemctl.log" || fail "нет enable --now"

# 1b. Логин с заглавной буквы принимается как есть.
run Tania dev "$TMP/orch" "$TMP/lab"
[ "$RC" -eq 0 ] || fail "логин с заглавной отвергнут: $(cat "$TMP/out")"
grep -qx 'User=Tania' "$TMP/units/claude-agent-dev.service" || fail "User с заглавной искажён"

# 2. Отказы — и при каждом ни юнит не пишется, ни systemctl не зовётся.
expect_refused() {   # <описание> <user> <args...>
  local what="$1"; shift
  rm -f "$TMP"/units/*
  run "$@"
  [ "$RC" -ne 0 ] || fail "$what: принято"
  [ -z "$(ls -A "$TMP/units")" ] || fail "$what: юнит всё равно записан"
  [ -s "$TMP/systemctl.log" ] && fail "$what: systemctl всё равно вызван"
  return 0
}
NL=$'\n'
expect_refused "перевод строки в имени" agentuser "dev${NL}User=root" "$TMP/orch" "$TMP/lab"
expect_refused "заглавные в имени" agentuser "Dev" "$TMP/orch" "$TMP/lab"
expect_refused "слеш в имени" agentuser "../x" "$TMP/orch" "$TMP/lab"
expect_refused "пустое имя" agentuser "" "$TMP/orch" "$TMP/lab"
expect_refused "относительный путь" agentuser dev "orch" "$TMP/lab"
expect_refused "'..' в пути" agentuser dev "$TMP/orch/../orch" "$TMP/lab"
expect_refused "пробел в пути" agentuser dev "$TMP/orch" "$TMP/la b"
expect_refused "перевод строки в пути" agentuser dev "$TMP/orch" "$TMP/lab${NL}ExecStartPre=+/bin/sh"
expect_refused "нет watchdog.sh" agentuser dev "$TMP/lab" "$TMP/lab"
expect_refused "пользователь root" root dev "$TMP/orch" "$TMP/lab"
expect_refused "пустой пользователь" "" dev "$TMP/orch" "$TMP/lab"
expect_refused "перевод строки в пользователе" "a${NL}b" dev "$TMP/orch" "$TMP/lab"
expect_refused "пробел в пользователе" "a b" dev "$TMP/orch" "$TMP/lab"
expect_refused "лишний аргумент" agentuser dev "$TMP/orch" "$TMP/lab" extra
expect_refused "мало аргументов" agentuser dev "$TMP/orch"

# 3. Нет root-копии шаблона — внятный отказ, а не пустой юнит.
rm -f "$TMP"/units/*
RC=0
: > "$TMP/systemctl.log"
env -u SUDO_USER LABOPS_UNIT_TEMPLATE="$TMP/nope" LABOPS_UNIT_DIR="$TMP/units" \
    LABOPS_SYSTEMCTL="$TMP/bin/systemctl" LABOPS_UNIT_USER=agentuser \
    bash "$HELPER" dev "$TMP/orch" "$TMP/lab" >"$TMP/out" 2>&1 </dev/null || RC=$?
[ "$RC" -ne 0 ] || fail "без шаблона: принято"
grep -q 'install.sh' "$TMP/out" || fail "без шаблона: не подсказано перезапустить install.sh"

# 4. От root переменные подмены игнорируются — проверяем по тексту: запускать
#    хелпер от root в тесте нельзя.
grep -q 'if \[ "$(id -u)" -ne 0 \]; then' "$HELPER" || fail "подмена путей не ограничена не-root"

echo "labops-agent-unit: ok"
