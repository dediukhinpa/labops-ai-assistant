#!/usr/bin/env bash
# Предупреждение при выборе Haiku главной моделью агента.
#
# Агент отвечает оператору только вызовом инструмента reply канала: текст,
# написанный в сессии, остаётся в tmux и в Telegram не уходит. Haiku это
# правило не выполняет — сообщения до агента доходят, а ответов нет. У клиента
# так и было (12.09.2026): при установке на вопрос о модели ввели haiku, все
# проверки установки прошли зелёными, а бот молчал, пока модель не сменили на
# sonnet.
#
# Выбор модели остаётся за оператором: haiku не запрещаем, а спрашиваем
# подтверждение, объяснив последствия. Без живого ввода (NONINTERACTIVE или
# закрытый stdin) переспросить некого — оставляем выбор как есть, но
# предупреждение печатаем всё равно, чтобы оно осталось в логе установки.

# shellcheck shell=bash

MODEL_CHOICE_DEFAULT="${MODEL_CHOICE_DEFAULT:-opus}"

# is_haiku_model <модель> — алиас haiku или полное имя из семейства Haiku.
is_haiku_model() {
  case "${1,,}" in
    *haiku*) return 0 ;;
  esac
  return 1
}

# confirm_primary_model — проверяет PRIMARY_MODEL; при Haiku предупреждает и
# спрашивает, оставить ли. Отказ — вопрос о модели заново (Enter = opus).
confirm_primary_model() {
  local answer=""
  while is_haiku_model "${PRIMARY_MODEL:-}"; do
    printf '\033[1;33m⚠ %s\033[0m\n' \
      "Модель ${PRIMARY_MODEL}: с Telegram-каналом агент на Haiku может не отвечать —" \
      "  сообщения доходят, но ответ остаётся в терминале. Для главного агента" \
      "  выбирайте sonnet или opus."
    if [ "${NONINTERACTIVE:-0}" = "1" ]; then
      return 0
    fi
    printf '\033[0;36m[?]\033[0m Оставить %s? [y/N]: ' "$PRIMARY_MODEL"
    read -r answer || { echo; return 0; }
    case "${answer,,}" in
      y|yes|д|да) return 0 ;;
    esac
    printf '\033[0;36m[?]\033[0m Модель (fable / opus / sonnet) [%s]: ' "$MODEL_CHOICE_DEFAULT"
    read -r answer || answer=""
    PRIMARY_MODEL="${answer:-$MODEL_CHOICE_DEFAULT}"
  done
  return 0
}
