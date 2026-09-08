#!/usr/bin/env bash
# Unit tests for lib/preflight.sh — классификация доступности хоста.
#
# Сеть не трогаем: curl подменяется заглушкой на PATH, которая отдаёт заданный
# код. Проверяется именно разбор ответа, а не наличие интернета у машины, где
# гоняются тесты.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

mkdir -p "$TMP/bin"
# Заглушка повторяет контракт настоящего curl: код пишется в stdout из-за
# -w '%{http_code}', а при полном отказе соединения curl печатает 000 и выходит
# с ненулевым кодом (проверено на живом хосте: rc=6 для несуществующего домена).
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
case "${STUB_CURL_CODE:-200}" in
  000) printf '000'; exit 6 ;;
  *)   printf '%s' "$STUB_CURL_CODE"; exit 0 ;;
esac
EOF
chmod +x "$TMP/bin/curl"
export PATH="$TMP/bin:$PATH"

# shellcheck disable=SC1091
source "$HERE/preflight.sh"

# 1. Обычный успех.
STUB_CURL_CODE=200 preflight_host https://example.test \
  || fail "200 должен считаться доступным"

# 2. Редирект — тоже живой хост. Именно так отвечает claude.ai/install.sh.
STUB_CURL_CODE=302 preflight_host https://example.test \
  || fail "302 должен считаться доступным"

# 3. 405 «метод не разрешён» — признак живого хоста, а не отказа. Так отвечает
#    api.anthropic.com на HEAD, и принять это за сбой значит завалить установку
#    на полностью рабочей машине.
STUB_CURL_CODE=405 preflight_host https://example.test \
  || fail "405 должен считаться доступным"

# 4. 403 — отдельный класс: адрес режется, а не сеть лежит.
STUB_CURL_CODE=403 preflight_host https://example.test
[ "$?" = "2" ] || fail "403 должен давать код 2 (режется), а не общий отказ"

# 5. Нет соединения вовсе.
STUB_CURL_CODE=000 preflight_host https://example.test
[ "$?" = "1" ] || fail "отсутствие связи должно давать код 1"

# 6. Код возвращается как есть — на нём строится текст ошибки установщика.
[ "$(STUB_CURL_CODE=418 http_status https://example.test)" = "418" ] \
  || fail "http_status искажает код ответа"

# 7. Пустой ответ curl не должен превращаться в пустую строку: вызывающий
#    сравнивает результат с кодами, и пустое значение сломало бы разбор.
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
exit 7
EOF
chmod +x "$TMP/bin/curl"
[ "$(http_status https://example.test)" = "000" ] \
  || fail "молчащий curl должен давать 000, а не пустую строку"

echo "OK: preflight.sh — 7 проверок пройдено"
