#!/usr/bin/env bash
# Проверка главной модели агента: имя без мусора и предупреждение про Haiku.
#
# Имя модели. Установщик записывал ответ в settings.json как есть. У клиента
# (13.09.2026) при вопросе о модели начали печатать в русской раскладке и стёрли
# букву Backspace: терминал без iutf8 стирает один байт из двух, и в settings.json
# ушло "ы\xd1sonnet". Все проверки установки прошли, а агент на каждое сообщение
# получал «There's an issue with the selected model» и молчал в Telegram.
# Теперь имя проверяется: только латиница, цифры и . _ - [ ] (как в
# claude-opus-5[1m]); иначе вопрос заново, а без живого ввода — остановка.
#
# Haiku.
# Агент отвечает оператору только вызовом инструмента reply канала: текст,
# написанный в сессии, остаётся в tmux и в Telegram не уходит. Haiku это
# правило не выполняет — сообщения до агента доходят, а ответов нет. У клиента
# так и было (12.09.2026): при установке на вопрос о модели ввели haiku, все
# проверки установки прошли зелёными, а бот молчал, пока модель не сменили на
# sonnet.
#
# Сначала haiku разрешался после подтверждения, но агент на нём всё равно
# молчит, поэтому владелец убрал его из выбора (17.09.2026): haiku отвергается
# и модель спрашивается заново. Без живого ввода (NONINTERACTIVE или закрытый
# stdin) переспросить некого — установка останавливается, а не ставит
# заведомо немого агента.

# shellcheck shell=bash

# shellcheck source=ui.sh
. "$(dirname "${BASH_SOURCE[0]}")/ui.sh"

# sonnet по умолчанию: владелец выбрал его для новых агентов (13.09.2026).
MODEL_CHOICE_DEFAULT="${MODEL_CHOICE_DEFAULT:-sonnet}"

# is_haiku_model <модель> — алиас haiku или полное имя из семейства Haiku.
is_haiku_model() {
  case "${1,,}" in
    *haiku*) return 0 ;;
  esac
  return 1
}

# is_valid_model_name <модель> — алиас или полное имя без посторонних символов.
# Проверка через tr в локали C: [a-z] в регулярке bash под UTF-8-локалью
# зависит от libc, а tr удаляет ровно ASCII-байты, и любой остаток — мусор.
is_valid_model_name() {
  case "$1" in
    [A-Za-z0-9]*) ;;
    *) return 1 ;;
  esac
  [ -z "$(printf '%s' "$1" | LC_ALL=C tr -d 'A-Za-z0-9._[]-')" ]
}

# ask_model_again — повторный вопрос о модели (Enter = значение по умолчанию).
# Пробелы по краям срезаются: их не видно, а имя модели с ними не находится.
ask_model_again() {
  local answer=""
  printf "${UI_INFO}[?]${UI_RESET} Модель (fable / opus / sonnet) [%s]: " "$MODEL_CHOICE_DEFAULT"
  if ! read -r answer; then echo; return 1; fi
  answer="${answer#"${answer%%[![:space:]]*}"}"
  answer="${answer%"${answer##*[![:space:]]}"}"
  PRIMARY_MODEL="${answer:-$MODEL_CHOICE_DEFAULT}"
}

# confirm_primary_model — проверяет PRIMARY_MODEL: недопустимое имя и Haiku
# спрашивают модель заново (Enter = sonnet), без живого ввода — die.
confirm_primary_model() {
  while :; do
    PRIMARY_MODEL="${PRIMARY_MODEL#"${PRIMARY_MODEL%%[![:space:]]*}"}"
    PRIMARY_MODEL="${PRIMARY_MODEL%"${PRIMARY_MODEL##*[![:space:]]}"}"
    if ! is_valid_model_name "${PRIMARY_MODEL:-}"; then
      # %q показывает непечатаемые байты ($'\321...'), а не «ы�» — видно, что не так.
      err "Недопустимое имя модели: $(printf '%q' "${PRIMARY_MODEL:-}")"
      echo "  Допустимы латиница, цифры и . _ - [ ]: fable, opus, sonnet, claude-opus-5[1m]."
      echo "  Возможно, ввод начат в русской раскладке."
      if [ "${NONINTERACTIVE:-0}" = "1" ]; then
        die "задайте PRIMARY_MODEL латиницей и запустите установку снова"
      fi
      ask_model_again || die "ввода нет — задайте PRIMARY_MODEL латиницей и запустите установку снова"
      continue
    fi
    is_haiku_model "$PRIMARY_MODEL" || return 0
    err "Модель ${PRIMARY_MODEL} не поддерживается: агент на Haiku не отвечает в Telegram —"
    echo "  сообщения доходят, но ответ остаётся в терминале. Выберите fable, opus или sonnet."
    if [ "${NONINTERACTIVE:-0}" = "1" ]; then
      die "задайте PRIMARY_MODEL=sonnet (или fable / opus) и запустите установку снова"
    fi
    ask_model_again || die "ввода нет — задайте PRIMARY_MODEL=sonnet (или fable / opus) и запустите установку снова"
  done
  return 0
}
