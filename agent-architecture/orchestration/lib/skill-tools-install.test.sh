#!/usr/bin/env bash
# Unit tests for lib/skill-tools-install.sh — программы и библиотеки скиллов.
# apt-get, dpkg-query, npm и pip подменены; agent-browser берётся из «релиза» file:// с
# подставным бинарём. Проверяются: пропуск apt, когда всё стоит; закреплённые версии pip/npm;
# .pth в user site и ссылки в ~/.local/bin; sha256 agent-browser (чужой бинарь не ставится);
# повтор не скачивает бинарь заново.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "ok: $1"; PASS=$((PASS + 1)); }

ME="$(id -un)"
H="$TMP/home"; mkdir -p "$H"
BIN="$TMP/bin"; mkdir -p "$BIN"
LOG="$TMP/calls.log"; : > "$LOG"
MISSING="$TMP/missing"; : > "$MISSING"   # пакеты, которых «нет» для dpkg-query

cat > "$BIN/dpkg-query" <<EOF
#!/usr/bin/env bash
pkg="\${@: -1}"
grep -qx "\$pkg" "$MISSING" && exit 1
printf 'install ok installed'
EOF
cat > "$BIN/apt-get" <<EOF
#!/usr/bin/env bash
echo "apt-get \$*" >> "$LOG"
EOF
cat > "$BIN/npm" <<EOF
#!/usr/bin/env bash
echo "npm \$*" >> "$LOG"
EOF
# python3 -m venv: создаём «venv» с pip-заглушкой и настоящим python (для записи .pth).
REAL_PY="$(command -v python3)"
cat > "$BIN/python3" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "-m" ] && [ "\$2" = "venv" ]; then
  v="\${@: -1}"; mkdir -p "\$v/bin"
  ln -sfn "$REAL_PY" "\$v/bin/python"
  # pyvenv.cfg — признак venv: без него python по ссылке считает себя системным.
  printf 'home = %s\ninclude-system-site-packages = true\n' "\$(dirname "$REAL_PY")" > "\$v/pyvenv.cfg"
  printf '#!/usr/bin/env bash\necho "pip \$*" >> "%s"\n' "$LOG" > "\$v/bin/pip"
  for b in markitdown yt-dlp pip3; do printf '#!/usr/bin/env bash\n' > "\$v/bin/\$b"; done
  chmod +x "\$v/bin/"*
  echo "venv \$*" >> "$LOG"
  exit 0
fi
exec "$REAL_PY" "\$@"
EOF
cat > "$BIN/curl" <<EOF
#!/usr/bin/env bash
echo "curl \$*" >> "$LOG"
exec "$(command -v curl)" "\$@"
EOF
chmod +x "$BIN"/*

# «Релиз» agent-browser: подставной бинарь пишет вызовы и кладёт «Chrome».
REL="$TMP/release/v0.43.0"; mkdir -p "$REL"
case "$(uname -m)" in aarch64|arm64) ASSET=agent-browser-linux-arm64 ;; *) ASSET=agent-browser-linux-x64 ;; esac
cat > "$REL/$ASSET" <<EOF
#!/usr/bin/env bash
echo "agent-browser \$*" >> "$LOG"
[ "\$1" = install ] && mkdir -p "\$HOME/.agent-browser/browsers/chrome-1/" && : > "\$HOME/.agent-browser/browsers/chrome-1/chrome"
exit 0
EOF
SUM="$(sha256sum "$REL/$ASSET" | cut -d' ' -f1)"

run_install() {   # [sha256 бинаря]
  env PATH="$BIN:$PATH" SUDO="" BROWSER_RELEASE_BASE="file://$TMP/release" \
    SKILL_TOOLS_APPARMOR_DIR="$TMP/no-apparmor" HOME="$H" \
    bash -c '
      ok() { echo "OK $*"; }; warn() { echo "WARN $*"; }; step() { echo "STEP $*"; }
      note() { echo "NOTE $*"; }
      . "'"$HERE"'/skill-tools-install.sh"
      BROWSER_SHA256_X64="'"${1:-$SUM}"'"; BROWSER_SHA256_ARM64="'"${1:-$SUM}"'"
      skill_tools_install "'"$ME"'" "'"$H"'"'
}

# 1. Всё стоит: apt не трогается, библиотеки и браузер ставятся.
out="$(run_install 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || { echo "$out"; fail "первый прогон завершился с кодом $rc"; }
grep -q "^apt-get" "$LOG" && fail "apt-get вызван, хотя все пакеты стоят"
pass "все пакеты apt на месте — apt-get не вызывается"

grep -q "^pip install .*pdfplumber==0.11.11" "$LOG" || fail "pip не получил закреплённых версий"
grep -q "^npm install -g .*docx@9.16.0.*pptxgenjs@4.0.1" "$LOG" || fail "npm не получил закреплённых версий"
grep -q "^npm config set prefix $H/.local" "$LOG" || fail "npm-префикс не ~/.local — агент не сможет npm -g без sudo"
pass "pip и npm ставят закреплённые версии, npm-префикс в ~/.local"

PTH="$(find "$H" -name labops-skills.pth | head -n1)"
[ -n "$PTH" ] && grep -q "$H/.local/share/labops-skills/venv" "$PTH" || fail ".pth не указывает на venv скиллов"
for b in markitdown yt-dlp pip pip3 agent-browser; do
  [ -L "$H/.local/bin/$b" ] || fail "нет ссылки ~/.local/bin/$b"
done
[ "$(readlink "$H/.node_modules")" = "$H/.local/lib/node_modules" ] || fail "нет ~/.node_modules"
pass ".pth в user site, ссылки в ~/.local/bin и ~/.node_modules на месте"

grep -q "^agent-browser install" "$LOG" || fail "Chrome для agent-browser не ставился"
[ -f "$H/.agent-browser/browsers/chrome-1/chrome" ] || fail "Chrome не лёг в дом пользователя"
pass "agent-browser поставлен из релиза и скачал Chrome"

# 2. Повтор: бинарь не скачивается заново.
: > "$LOG"
run_install >/dev/null 2>&1 || fail "повторный прогон упал"
grep -q "^curl" "$LOG" && fail "повтор снова скачивает agent-browser"
pass "повтор не скачивает agent-browser"

# 3. Чужой бинарь (sha256 не совпал) не ставится.
rm -rf "$H/.local/share/labops-agent-browser"
out="$(run_install 0000000000000000000000000000000000000000000000000000000000000000 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail "установка с неверной sha256 вернула 0"
printf '%s' "$out" | grep -q "sha256 не совпал" || fail "нет сообщения о несовпадении sha256"
[ -e "$H/.local/share/labops-agent-browser/0.43.0/agent-browser" ] && fail "бинарь с чужой sha256 установлен"
pass "бинарь с несовпавшей sha256 не ставится"

# 4. Недостающие пакеты apt ставятся одним вызовом, без рекомендаций.
printf 'pandoc\nlibreoffice-writer\n' > "$MISSING"; : > "$LOG"
run_install >/dev/null 2>&1
grep -q "^apt-get install -y -q --no-install-recommends pandoc libreoffice-writer" "$LOG" \
  || { cat "$LOG"; fail "apt-get не поставил недостающие пакеты одним вызовом"; }
pass "недостающие пакеты apt ставятся одним вызовом с --no-install-recommends"

echo "passed: $PASS"
