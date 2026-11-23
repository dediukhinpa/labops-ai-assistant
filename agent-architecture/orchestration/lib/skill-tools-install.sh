#!/usr/bin/env bash
# lib/skill-tools-install.sh — программы и библиотеки, без которых не работают скиллы агентов.
#
# Скиллы документов (docx/pptx/xlsx/pdf), браузера, расшифровок и т.п. рассчитаны на то, что
# LibreOffice, pandoc, Poppler, Node-пакеты (docx, pptxgenjs, sharp) и Python-библиотеки
# (openpyxl, pdfplumber, markitdown, ...) уже стоят. Сам агент их не доставит: sudo у него нет
# (deny Bash(sudo *)), а pip в системный Python на Ubuntu 24.04+ запрещён (PEP 668). Раньше
# установщик ничего из этого не ставил, и скиллы падали у клиента на «command not found».
#
# Поэтому, пока у install.sh есть root:
#   1) apt: системные программы и Python-библиотеки, которые есть в дистрибутиве;
#   2) от пользователя агентов: venv скиллов (--system-site-packages) с тем, чего нет в apt,
#      подключённый к обычному python3 через .pth в user site — интерпретатор не подменяется,
#      а `pip install` агента (ссылка pip в ~/.local/bin) кладёт пакеты туда же, без sudo;
#      npm с префиксом ~/.local (агент сам делает `npm i -g`), ~/.node_modules -> глобальные
#      модули: `require('docx')` работает из любого каталога без NODE_PATH;
#   3) agent-browser закреплённой версии (sha256) + Chrome for Testing и его библиотеки
#      (`agent-browser install --with-deps`) + профиль AppArmor, без которого Chrome на
#      Ubuntu 23.10+ падает с «No usable sandbox»; песочница Chrome остаётся включённой.
#
# Повторный запуск идемпотентен. Сбой не останавливает установку: агент работает, не работают
# только отдельные скиллы. Подключается через source; ждёт ok/warn/step/note из ui.sh и $SUDO
# (пусто под root).
#
#   skill_tools_install <пользователь> <его дом>  -> 0 всё стоит, 1 — что-то не поставлено

# shellcheck shell=bash

# Системные пакеты. --no-install-recommends: LibreOffice с рекомендациями тянет гигабайт GUI.
SKILL_TOOLS_APT_PACKAGES=(
  nodejs npm python-is-python3 python3-venv python3-pip
  pandoc poppler-utils qpdf imagemagick ffmpeg gh sqlite3 ripgrep
  libreoffice-core libreoffice-writer libreoffice-calc libreoffice-impress
  fonts-liberation fonts-dejavu fonts-noto-core
  python3-docx python3-openpyxl python3-pypdf python3-pandas python3-reportlab python3-pil
  python3-numpy python3-lxml python3-defusedxml python3-httpx python3-requests
)
# Python-пакеты, которых нет в apt. Версии закреплены (проверены 23.11.2026 на Ubuntu 26.04).
SKILL_TOOLS_PIP_PACKAGES=(
  "pdfplumber==0.11.11" "pdf2image==1.17.0" "pytesseract==0.3.13" "python-pptx==1.0.2"
  "markitdown[pptx,docx,xlsx,pdf]==0.1.9" "yt-dlp==2026.10.26" "mcp==2.3.0" "Telethon==1.46.0"
)
# Node-пакеты, которые скиллы docx/pptx подключают через require() как «предустановленные».
SKILL_TOOLS_NPM_PACKAGES=(
  "docx@9.16.0" "pptxgenjs@4.0.1" "react@19.3.1" "react-dom@19.3.1" "react-icons@5.7.0"
  "sharp@0.35.5"
)
# Ссылки в ~/.local/bin на программы из venv скиллов.
SKILL_TOOLS_VENV_LINKS=(markitdown yt-dlp pip pip3)

# agent-browser: бинарь релиза vercel-labs/agent-browser. Новая версия — только с новыми sha256.
BROWSER_PINNED_VERSION="0.43.0"
# sha256 бинарей релиза v0.43.0 (сняты 23.11.2026 с github.com/vercel-labs/agent-browser/releases).
BROWSER_SHA256_X64="8e69c9fb662514c9cf36e4911e94e913742ba066e55102486350e049dd847612"
BROWSER_SHA256_ARM64="34be55c2b92d8d199fb9d1d62a905ee5b6ac5b1f3e8c24e5b20597f370d905e5"
BROWSER_RELEASE_BASE="${BROWSER_RELEASE_BASE:-https://github.com/vercel-labs/agent-browser/releases/download}"
# Chrome for Testing ~200 МБ, плюс apt его библиотек: на медленном канале это минуты.
BROWSER_INSTALL_MAX_SEC=1800
SKILL_TOOLS_APPARMOR_DIR="${SKILL_TOOLS_APPARMOR_DIR:-/etc/apparmor.d}"
SKILL_TOOLS_APPARMOR_PROFILE="labops-agent-browser"

# skill_tools_as_user <пользователь> <дом> <команда...> — выполнить от пользователя агентов.
# Под тем же пользователем (тесты, установка без отдельного пользователя) — напрямую.
skill_tools_as_user() {
  local user="$1" home="$2"; shift 2
  if [ "$(id -un)" = "$user" ]; then
    HOME="$home" "$@"
  else
    $SUDO runuser -u "$user" -- env HOME="$home" PATH="$home/.local/bin:/usr/local/bin:/usr/bin:/bin" "$@"
  fi
}

# Каких пакетов из списка ещё нет (по dpkg), по одному в строке.
skill_tools_missing_apt() {
  local pkg
  for pkg in "${SKILL_TOOLS_APT_PACKAGES[@]}"; do
    dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed" \
      || printf '%s\n' "$pkg"
  done
}

skill_tools_install_apt() {
  local missing log
  if ! command -v apt-get >/dev/null 2>&1; then
    note "нет apt-get — программы скиллов (LibreOffice, pandoc, Node.js, ...) поставьте вручную"
    return 1
  fi
  missing="$(skill_tools_missing_apt)"
  if [ -z "$missing" ]; then
    ok "программы скиллов уже установлены (apt)"
    return 0
  fi
  step "ставлю программы скиллов: $(printf '%s' "$missing" | wc -l) пакетов apt (LibreOffice, pandoc, Node.js, ...)"
  log="$(mktemp)"
  # shellcheck disable=SC2086
  if $SUDO env DEBIAN_FRONTEND=noninteractive apt-get update -q >"$log" 2>&1 \
     && $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends \
          $missing >>"$log" 2>&1; then
    rm -f "$log"
    ok "программы скиллов установлены"
    return 0
  fi
  warn "apt не поставил программы скиллов — хвост журнала:"
  tail -n 5 "$log" >&2
  rm -f "$log"
  return 1
}

# Пользовательская часть: venv скиллов + .pth + ссылки, npm-префикс и глобальные модули.
skill_tools_install_user() {
  local user="$1" home="$2" venv="$2/.local/share/labops-skills/venv" b
  skill_tools_as_user "$user" "$home" mkdir -p "$home/.local/share/labops-skills" "$home/.local/bin" \
    || return 1
  if [ ! -x "$venv/bin/python" ]; then
    skill_tools_as_user "$user" "$home" python3 -m venv --system-site-packages "$venv" || {
      warn "venv скиллов не создан (python3-venv?)"; return 1; }
  fi
  step "Python-пакеты скиллов (pdfplumber, markitdown, python-pptx, ...)"
  skill_tools_as_user "$user" "$home" "$venv/bin/pip" install -q --disable-pip-version-check \
    "${SKILL_TOOLS_PIP_PACKAGES[@]}" || { warn "pip не поставил пакеты скиллов"; return 1; }
  # .pth в user site: обычный python3 видит пакеты venv, сам интерпретатор остаётся системным.
  skill_tools_as_user "$user" "$home" "$venv/bin/python" - <<'PY' || return 1
import site, sysconfig, pathlib, subprocess
# user site системного python3 (не venv): туда кладём ссылку на site-packages venv
user_site = subprocess.run(["/usr/bin/python3", "-c", "import site;print(site.getusersitepackages())"],
                           capture_output=True, text=True, check=True).stdout.strip()
target = pathlib.Path(user_site)
target.mkdir(parents=True, exist_ok=True)
(target / "labops-skills.pth").write_text(sysconfig.get_paths()["purelib"] + "\n")
PY
  for b in "${SKILL_TOOLS_VENV_LINKS[@]}"; do
    skill_tools_as_user "$user" "$home" ln -sfn "$venv/bin/$b" "$home/.local/bin/$b" || return 1
  done
  if command -v npm >/dev/null 2>&1; then
    step "Node-пакеты скиллов (docx, pptxgenjs, sharp, ...)"
    skill_tools_as_user "$user" "$home" npm config set prefix "$home/.local" >/dev/null || return 1
    skill_tools_as_user "$user" "$home" npm install -g --no-fund --no-audit --loglevel=error \
      "${SKILL_TOOLS_NPM_PACKAGES[@]}" >/dev/null || { warn "npm не поставил пакеты скиллов"; return 1; }
    # Node ищет глобальные модули и в ~/.node_modules: require() работает без NODE_PATH.
    skill_tools_as_user "$user" "$home" ln -sfn "$home/.local/lib/node_modules" "$home/.node_modules" \
      || return 1
  else
    warn "нет npm — Node-пакеты скиллов не поставлены"
    return 1
  fi
  ok "библиотеки скиллов: python3 и node видят их из любого каталога; pip/npm -g агенту доступны без sudo"
}

browser_asset() {
  case "$(uname -s)-$(uname -m)" in
    Linux-x86_64|Linux-amd64) echo "agent-browser-linux-x64 $BROWSER_SHA256_X64" ;;
    Linux-aarch64|Linux-arm64) echo "agent-browser-linux-arm64 $BROWSER_SHA256_ARM64" ;;
    *) return 1 ;;
  esac
}

# Профиль AppArmor для Chrome из ~/.agent-browser (по образцу штатного /etc/apparmor.d/chrome).
skill_tools_apparmor_profile() {
  cat <<'EOF'
# Автосоздано labops-agent-architecture/install.sh (lib/skill-tools-install.sh).
# Chrome for Testing, который agent-browser кладёт в ~/.agent-browser пользователя агентов.
# Ubuntu 23.10+ запрещает непривилегированные user namespaces через AppArmor, и без этого
# профиля Chrome падает с «No usable sandbox». Профиль разрешает userns только этому бинарю,
# песочница Chrome остаётся включённой — --no-sandbox не нужен.

abi <abi/4.0>,
include <tunables/global>

profile labops-agent-browser /home/*/.agent-browser/browsers/chrome-*/chrome flags=(unconfined) {
  userns,

  include if exists <local/labops-agent-browser>
}
EOF
}

skill_tools_install_apparmor() {
  local dest="$SKILL_TOOLS_APPARMOR_DIR/$SKILL_TOOLS_APPARMOR_PROFILE" tmp
  [ -d "$SKILL_TOOLS_APPARMOR_DIR" ] && command -v apparmor_parser >/dev/null 2>&1 || return 0
  tmp="$(mktemp)"
  skill_tools_apparmor_profile > "$tmp"
  if ! cmp -s "$tmp" "$dest" 2>/dev/null; then
    $SUDO install -m 644 "$tmp" "$dest" || { rm -f "$tmp"; return 1; }
  fi
  rm -f "$tmp"
  $SUDO apparmor_parser -r "$dest" >/dev/null 2>&1 || {
    warn "профиль AppArmor для Chrome не загрузился — браузер может не стартовать"; return 1; }
  ok "AppArmor: Chrome агентов запускается с песочницей ($dest)"
}

# agent-browser в ~/.local/share/labops-agent-browser/<версия> + ссылка, Chrome и его библиотеки.
skill_tools_install_browser() {
  local user="$1" home="$2" asset name sum dest link tmp got group
  asset="$(browser_asset)" || { warn "agent-browser: платформа $(uname -m) не поддерживается"; return 1; }
  name="${asset% *}"; sum="${asset#* }"
  dest="$home/.local/share/labops-agent-browser/$BROWSER_PINNED_VERSION"
  link="$home/.local/bin/agent-browser"
  group="$(id -gn "$user")"
  if [ "$(sha256sum "$dest/agent-browser" 2>/dev/null | cut -d' ' -f1)" != "$sum" ]; then
    step "ставлю agent-browser $BROWSER_PINNED_VERSION (релиз vercel-labs, проверка sha256)"
    tmp="$(mktemp -d)"
    if ! curl -fsSL --connect-timeout 10 --max-time 600 \
        "$BROWSER_RELEASE_BASE/v$BROWSER_PINNED_VERSION/$name" -o "$tmp/agent-browser"; then
      rm -rf "$tmp"; warn "agent-browser: не удалось скачать $name"; return 1
    fi
    got="$(sha256sum "$tmp/agent-browser" | cut -d' ' -f1)"
    if [ "$got" != "$sum" ]; then
      rm -rf "$tmp"; warn "agent-browser: sha256 не совпал (ожидалась $sum, получена $got) — не ставлю"
      return 1
    fi
    skill_tools_as_user "$user" "$home" mkdir -p "$dest" "$home/.local/bin" || { rm -rf "$tmp"; return 1; }
    $SUDO install -m 755 -o "$user" -g "$group" "$tmp/agent-browser" "$dest/agent-browser" \
      || { rm -rf "$tmp"; return 1; }
    rm -rf "$tmp"
  fi
  skill_tools_as_user "$user" "$home" ln -sfn "$dest/agent-browser" "$link" || return 1
  skill_tools_install_apparmor || true
  # --with-deps ставит библиотеки Chrome через apt — нужен root; Chrome ляжет в $home/.agent-browser.
  step "Chrome для agent-browser и его библиотеки (~200 МБ, один раз)"
  if [ "$(id -u)" -eq 0 ] || [ -n "$SUDO" ]; then
    (cd / && $SUDO env HOME="$home" timeout "$BROWSER_INSTALL_MAX_SEC" "$dest/agent-browser" install \
       --with-deps >/dev/null 2>&1) || { warn "agent-browser install --with-deps не прошёл"; return 1; }
    $SUDO chown -R "$user:$group" "$home/.agent-browser" || return 1
  else
    skill_tools_as_user "$user" "$home" timeout "$BROWSER_INSTALL_MAX_SEC" "$dest/agent-browser" install \
      >/dev/null 2>&1 || { warn "agent-browser install не прошёл"; return 1; }
  fi
  ok "agent-browser $BROWSER_PINNED_VERSION: $link"
}

skill_tools_install() {
  local user="$1" home="$2" rc=0
  skill_tools_install_apt || rc=1
  skill_tools_install_user "$user" "$home" || rc=1
  skill_tools_install_browser "$user" "$home" || rc=1
  return "$rc"
}
