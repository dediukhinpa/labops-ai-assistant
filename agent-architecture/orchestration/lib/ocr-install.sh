#!/usr/bin/env bash
# Установка Tesseract (rus+eng) для media-masker — OCR-маскирования вложений.
#
# Раньше Tesseract ставили только руками: шаг 5b (pii-setup.sh host) идёт уже от
# пользователя агентов, у которого sudo есть лишь на два хелпера, и apt-get там
# недоступен. Без Tesseract media-masker не ставится, и фото/PDF вырезаются из
# запросов к модели (PII_PROXY_IMAGE_POLICY=strip). Поэтому пакеты ставим здесь,
# пока у install.sh ещё есть root, — шаг 5b находит Tesseract и ставит media-masker сам.
#
# Повторный запуск идемпотентен: если tesseract с rus и eng уже есть, apt не трогается.
# Подключается через source; ждёт ok/warn/step/note из ui.sh и $SUDO (пусто под root).
#
#   ocr_install  -> 0 Tesseract с rus+eng готов, 1 — не поставлен (установка идёт дальше)

# shellcheck shell=bash

# Пакеты Debian/Ubuntu: движок, языки rus/eng и osd (определение ориентации скана).
OCR_APT_PACKAGES=(tesseract-ocr tesseract-ocr-rus tesseract-ocr-eng tesseract-ocr-osd)
# Языки, без которых media-masker не стартует (см. tesseract_ready в pii-setup.sh).
OCR_REQUIRED_LANGS=(rus eng)

# ocr_ready — есть ли tesseract со всеми языками из OCR_REQUIRED_LANGS.
ocr_ready() {
  local langs lang
  command -v tesseract >/dev/null 2>&1 || return 1
  langs="$(tesseract --list-langs 2>/dev/null)" || return 1
  for lang in "${OCR_REQUIRED_LANGS[@]}"; do
    printf '%s\n' "$langs" | grep -qx "$lang" || return 1
  done
}

ocr_install() {
  local log
  if ocr_ready; then
    ok "Tesseract (rus+eng) уже установлен"
    return 0
  fi
  if ! command -v apt-get >/dev/null 2>&1; then
    note "Tesseract не поставить: нет apt-get — фото и PDF не будут маскироваться (strip)"
    return 1
  fi
  step "ставлю Tesseract: ${OCR_APT_PACKAGES[*]} (apt-get)"
  # Вывод apt прячем, но при сбое показываем хвост — иначе причина теряется.
  log="$(mktemp)"
  if ! { $SUDO apt-get update -y \
         && $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y "${OCR_APT_PACKAGES[@]}"; \
       } >"$log" 2>&1; then
    warn "apt-get не поставил Tesseract. Последние строки:"
    tail -n 10 "$log" | sed 's/^/      /'
    rm -f "$log"
    return 1
  fi
  rm -f "$log"
  if ! ocr_ready; then
    warn "Tesseract поставлен, но языков ${OCR_REQUIRED_LANGS[*]} не видно (tesseract --list-langs)"
    return 1
  fi
  ok "Tesseract (rus+eng) установлен — шаг 5b поставит media-masker"
}
