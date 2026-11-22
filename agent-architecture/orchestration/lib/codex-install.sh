#!/usr/bin/env bash
# lib/codex-install.sh — установка Codex CLI закреплённой версии для роя на харнесе codex.
#
# Откуда: официальный пакет релиза openai/codex (codex-package-<платформа>.tar.gz) — тот же,
# что внутри npm-пакета @openai/codex, но без Node.js: в нём сам codex, rg, bwrap и ресурсы.
# Куда: ~/.local/share/labops-codex/<версия>/ пользователя агентов и ссылка ~/.local/bin/codex.
# НЕ в /usr/local/bin: общий для всех пользователей бинарь однажды уже зациклил рестарты роя
# (watchdog сверяет бинарь с PATH systemd, 13.09.2026).
#
# Версия закреплена: протокол app-server, на который опирается драйвер, меняется между
# версиями. Новая версия — только вместе с прогоном драйвера против неё и новыми sha256.
# Старые версии не удаляются: на них могут работать запущенные агенты.

# shellcheck shell=bash

CODEX_PINNED_VERSION="0.171.0"
# sha256 пакетов релиза rust-v0.171.0 (сняты 22.11.2026 с github.com/openai/codex/releases).
CODEX_SHA256_X86_64="8391d67757496bfd14893eca6cbf0c96994bf2627566ff1f018f70600c9ef6b3"
CODEX_SHA256_AARCH64="d8c43bee6cf11b01eb18b95f4d7961092bc40228180808859e70dabb7784c1c9"
# Адрес релизов; в тестах подменяется на file://.
CODEX_RELEASE_BASE="${CODEX_RELEASE_BASE:-https://github.com/openai/codex/releases/download}"
# Пакет весит ~200 МБ: на медленном канале скачивание идёт минуты.
CODEX_DOWNLOAD_MAX_SEC=900

codex_install_root() {
  printf '%s/.local/share/labops-codex' "$HOME"
}

# Платформа пакета по архитектуре машины (только Linux: рой работает под systemd).
codex_package_target() {
  case "$(uname -s)-$(uname -m)" in
    Linux-x86_64|Linux-amd64) echo "x86_64-unknown-linux-musl" ;;
    Linux-aarch64|Linux-arm64) echo "aarch64-unknown-linux-musl" ;;
    *) return 1 ;;
  esac
}

codex_package_sha256() {   # <target>
  case "$1" in
    x86_64-*) echo "$CODEX_SHA256_X86_64" ;;
    aarch64-*) echo "$CODEX_SHA256_AARCH64" ;;
    *) return 1 ;;
  esac
}

# Версия codex по пути (пусто, если не запускается).
codex_version_of() {   # <bin>
  "$1" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1
}

# codex_pinned_mismatch <bin> — 0 и версию (или «неизвестна») в stdout, если codex по этому пути
# не закреплённой версии; 1 — версия закреплённая. Драйвер опирается на протокол app-server
# именно этой версии, поэтому чужая версия — повод предупредить оператора.
codex_pinned_mismatch() {   # <bin>
  local got
  got="$(codex_version_of "$1")"
  [ "$got" = "$CODEX_PINNED_VERSION" ] && return 1
  printf '%s\n' "${got:-неизвестна}"
}

# codex_install_pinned — поставить закреплённую версию, если её ещё нет. Печатает путь к codex.
# Коды: 0 — готово; 1 — не скачалось/не совпала сумма/платформа не поддерживается (причина в
# stderr).
codex_install_pinned() {
  local target sum root dest tmp got link
  root="$(codex_install_root)"
  dest="$root/$CODEX_PINNED_VERSION"
  link="$HOME/.local/bin/codex"
  if [ "$(codex_version_of "$dest/bin/codex")" = "$CODEX_PINNED_VERSION" ]; then
    mkdir -p "$HOME/.local/bin" && ln -sfn "$dest/bin/codex" "$link"
    printf '%s\n' "$link"
    return 0
  fi
  target="$(codex_package_target)" || {
    echo "codex: платформа $(uname -s)-$(uname -m) не поддерживается (нужен Linux x86_64 или aarch64)" >&2
    return 1
  }
  sum="$(codex_package_sha256 "$target")"
  mkdir -p "$root" || return 1
  tmp="$(mktemp -d "$root/.download.XXXXXX")" || return 1
  if ! curl -fsSL --connect-timeout 10 --max-time "$CODEX_DOWNLOAD_MAX_SEC" \
      "$CODEX_RELEASE_BASE/rust-v$CODEX_PINNED_VERSION/codex-package-$target.tar.gz" \
      -o "$tmp/pkg.tar.gz"; then
    rm -rf "$tmp"
    echo "codex: не удалось скачать пакет $CODEX_PINNED_VERSION ($target) с $CODEX_RELEASE_BASE" >&2
    return 1
  fi
  got="$(sha256sum "$tmp/pkg.tar.gz" | cut -d' ' -f1)"
  if [ "$got" != "$sum" ]; then
    rm -rf "$tmp"
    echo "codex: контрольная сумма пакета не совпала (ожидалась $sum, получена $got) — не ставлю" >&2
    return 1
  fi
  mkdir -p "$tmp/pkg" && tar -xzf "$tmp/pkg.tar.gz" -C "$tmp/pkg" || { rm -rf "$tmp"; return 1; }
  if [ "$(codex_version_of "$tmp/pkg/bin/codex")" != "$CODEX_PINNED_VERSION" ]; then
    rm -rf "$tmp"
    echo "codex: распакованный codex не запускается или не той версии" >&2
    return 1
  fi
  # Каталог версии появляется целиком одним rename: прерванная установка не оставит полупакет.
  rm -rf "$dest"
  mv "$tmp/pkg" "$dest" && rm -rf "$tmp" || return 1
  mkdir -p "$HOME/.local/bin" && ln -sfn "$dest/bin/codex" "$link" || return 1
  printf '%s\n' "$link"
}
