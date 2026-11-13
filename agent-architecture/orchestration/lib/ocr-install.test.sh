#!/usr/bin/env bash
# Unit tests for lib/ocr-install.sh — установка Tesseract (rus+eng) для media-masker.
# apt-get и tesseract подменены: проверяется, что apt не трогается при готовом Tesseract,
# ставит все пакеты при его отсутствии, сбой apt не валит установку, а без apt — тихий отказ.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

BIN="$TMP/bin"; mkdir -p "$BIN"
# PATH теста — только нужные утилиты: настоящий tesseract с хоста не подмешивается.
for t in bash env cat sed grep tail mktemp rm cp printf; do
  p="$(type -P "$t")" && ln -sf "$p" "$BIN/$t"
done
LOG="$TMP/calls.log"
LANGS_FILE="$TMP/langs"
APT_FAIL_FILE="$TMP/apt-fail"

stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "${3:-$BIN}/$1"; chmod +x "${3:-$BIN}/$1"; }

# tesseract лежит в PRE и появляется в PATH только после «установки» заглушкой apt-get.
PRE="$TMP/pre"; mkdir -p "$PRE"
stub tesseract "[ \"\$1\" = --list-langs ] || exit 2
echo 'List of available languages in \"/usr/share/tesseract-ocr/5/tessdata/\" (3):'
cat \"$LANGS_FILE\"" "$PRE"
stub apt-get "echo \"apt-get \$*\" >> \"$LOG\"
[ -f \"$APT_FAIL_FILE\" ] && { echo 'E: Unable to locate package tesseract-ocr-rus'; exit 100; }
case \"\$*\" in *install*) cp \"$PRE\"/tesseract \"$BIN\"/ ;; esac"
# Тест идёт не от root: «sudo» просто исполняет команду.
stub fakesudo 'exec "$@"'

reset() {
  : > "$LOG"; rm -f "$BIN/tesseract" "$APT_FAIL_FILE"
  printf 'eng\nosd\nrus\n' > "$LANGS_FILE"
}

run_install() {
  env PATH="$BIN" SUDO="$BIN/fakesudo" bash -c '
    ok() { echo "OK $*"; }; warn() { echo "WARN $*"; }; note() { echo "NOTE $*"; }
    step() { echo "STEP $*"; }
    . "'"$HERE"'/ocr-install.sh"
    ocr_install'
}

# 1. Tesseract нет — ставятся все четыре пакета, шаг успешен.
reset
out="$(run_install)"; rc=$?
[ "$rc" -eq 0 ] || fail "1: установка вернула $rc: $out"
grep -q 'apt-get update -y' "$LOG" || fail "1: не было apt-get update"
grep -q 'apt-get install -y tesseract-ocr tesseract-ocr-rus tesseract-ocr-eng tesseract-ocr-osd' "$LOG" \
  || fail "1: не тот набор пакетов: $(cat "$LOG")"
echo "$out" | grep -q '^OK Tesseract (rus+eng) установлен' || fail "1: нет итога ok: $out"

# 2. Повтор — Tesseract уже готов, apt не трогается.
: > "$LOG"
out="$(run_install)"; rc=$?
[ "$rc" -eq 0 ] || fail "2: повтор вернул $rc"
[ ! -s "$LOG" ] || fail "2: при готовом Tesseract вызван apt: $(cat "$LOG")"
echo "$out" | grep -q 'уже установлен' || fail "2: нет сообщения об уже готовом: $out"

# 3. Tesseract есть, но без rus — доустанавливается.
reset
cp "$PRE/tesseract" "$BIN/"
printf 'eng\nosd\n' > "$LANGS_FILE"
out="$(run_install)"; rc=$?
grep -q 'apt-get install' "$LOG" || fail "3: без rus apt не вызван"
[ "$rc" -eq 1 ] || fail "3: языка rus по-прежнему нет, ожидался код 1, получен $rc"
echo "$out" | grep -q 'языков rus eng не видно' || fail "3: нет предупреждения о языках: $out"

# 4. apt падает — код 1 и хвост вывода apt в сообщении, без обрыва вызывающего.
reset
touch "$APT_FAIL_FILE"
out="$(run_install)"; rc=$?
[ "$rc" -eq 1 ] || fail "4: при сбое apt ожидался код 1, получен $rc"
echo "$out" | grep -q 'Unable to locate package' || fail "4: причина сбоя apt не показана: $out"

# 5. Нет apt-get (не Debian/Ubuntu) — тихий отказ без вызова пакетного менеджера.
reset
rm -f "$BIN/apt-get"
out="$(run_install)"; rc=$?
[ "$rc" -eq 1 ] || fail "5: без apt-get ожидался код 1, получен $rc"
echo "$out" | grep -q '^NOTE Tesseract не поставить: нет apt-get' || fail "5: нет пояснения: $out"

echo "ocr-install: все проверки пройдены"
