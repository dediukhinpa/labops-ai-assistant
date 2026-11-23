#!/usr/bin/env bash
# pii-replay.sh — повтор последнего входящего после перевода claude на прямую работу.
# SOURCE this file. Ничего не запускает при сорсинге. Нужны lib/pane.sh и lib/pii.sh.
#
# Решение владельца 23.11.2026: если pii-proxy упал посреди хода, ход не ждёт встроенных
# повторов CLI — watchdog прерывает его, перезапускает claude напрямую (с --continue) и сам
# повторяет последнее входящее сообщение. Пользователя переслать его не просят.
#
# Задвоить нельзя, поэтому повторяется только сообщение, на которое ход ещё не ответил:
#   * источник текста — метка доставки плагина (lib/pane.sh: inbound_marker_file), а не
#     экран: нарисованное ≠ отправленное (цикл самоуказаний 2026-09-01);
#   * «ответил» = после доставки был конец хода. Конец хода пишет stop-hook.sh рабочей папки
#     (строка в logs/verbose-<дата>.jsonl на каждый Stop), берём время изменения файла.
#     Stop не приходит ни на прерывание, ни на ошибку API — значит, неответ;
#   * одно сообщение повторяется не больше одного раза (метка state/pii-replayed-inbound);
#   * слишком старое сообщение не повторяется: оно уже не про текущий ход.

# Сколько секунд после доставки сообщение ещё можно повторить.
PII_REPLAY_MAX_AGE_SEC="${PII_REPLAY_MAX_AGE_SEC:-1800}"
# Сколько ждать чистого промпта после перезапуска, прежде чем печатать, секунд.
PII_REPLAY_PROMPT_WAIT_SEC="${PII_REPLAY_PROMPT_WAIT_SEC:-90}"
# Пауза между опросами экрана при ожидании промпта, секунд.
PII_REPLAY_POLL_SEC="${PII_REPLAY_POLL_SEC:-2}"
# Пауза между литеральным вводом и Enter (как RECOVER_SUBMIT_DELAY в pane-recover.sh).
PII_REPLAY_SUBMIT_DELAY="${PII_REPLAY_SUBMIT_DELAY:-2}"
# Сколько ждать после Escape, чтобы claude записал прерывание, секунд.
PII_INTERRUPT_SETTLE_SEC="${PII_INTERRUPT_SETTLE_SEC:-2}"

# pii_last_turn_end <agent> — unix-время последнего конца хода (0 — ни одного не видно).
pii_last_turn_end() {
  python3 - "$(pii_lab)/$1/.claude/logs" <<'PY' 2>/dev/null || echo 0
import glob, os, sys
files = glob.glob(os.path.join(sys.argv[1], "verbose-*.jsonl"))
print(int(max((os.path.getmtime(f) for f in files), default=0)))
PY
}

# pii_replayed_file <agent> — метка «это входящее уже повторяли» (время его доставки).
pii_replayed_file() { printf '%s/%s/.claude/state/pii-replayed-inbound' "$(pii_lab)" "$1"; }

# pii_replay_pending <agent> — есть ли входящее, на которое ход не ответил. Печатает время
# его доставки (ключ для pii_replay_mark). 1 — повторять нечего.
pii_replay_pending() {
  local agent="$1" file ts now done_ts seen
  file="$(inbound_marker_file "$agent")"
  [ -f "$file" ] || return 1
  ts="$(head -1 "$file" 2>/dev/null || echo '')"
  case "$ts" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$(inbound_delivered_text "$agent")" ] || return 1
  now="$(date +%s)"
  [ $(( now - ts )) -le "$PII_REPLAY_MAX_AGE_SEC" ] || return 1
  done_ts="$(pii_last_turn_end "$agent")"
  case "$done_ts" in ''|*[!0-9]*) done_ts=0 ;; esac
  # Ход закончился в ту же секунду или позже доставки — ответ был.
  [ "$done_ts" -lt "$ts" ] || return 1
  seen="$(cat "$(pii_replayed_file "$agent")" 2>/dev/null || true)"
  [ "$seen" != "$ts" ] || return 1
  printf '%s\n' "$ts"
}

# pii_replay_mark <agent> <ts> — запомнить, что входящее с этим временем доставки повторено.
pii_replay_mark() {
  local f
  f="$(pii_replayed_file "$1")"
  mkdir -p "$(dirname "$f")" 2>/dev/null || true
  printf '%s\n' "$2" > "$f" 2>/dev/null || true
  return 0
}

# pii_replay_text <agent> — текст для повтора одной строкой: литеральный перевод строки в поле
# ввода — это отправка, многострочное ушло бы кусками (как _reflow_inbound в pane-recover.sh).
pii_replay_text() {
  inbound_delivered_text "$1" | tr '\n\t' '  ' | tr -s ' ' | sed -e 's/^ //' -e 's/ $//'
}

# pii_replay_type <session> <text> — дождаться чистого промпта и отправить текст.
# 0 — отправлено, 1 — промпт не дождались (ничего не набрано).
pii_replay_type() {
  local session="$1" text="$2" deadline pane
  deadline=$(( $(date +%s) + PII_REPLAY_PROMPT_WAIT_SEC ))
  while :; do
    pane="$(tmux capture-pane -pt "=$session:^.{top-left}" -S -8 2>/dev/null || true)"
    if has_prompt "$pane" && ! has_active_turn "$pane" && [ -z "$(pane_input "$pane")" ] \
       && ! looks_like_dev_channels_prompt "$pane"; then
      break
    fi
    [ "$(date +%s)" -lt "$deadline" ] || return 1
    sleep "$PII_REPLAY_POLL_SEC"
  done
  tmux send-keys -t "=$session:^.{top-left}" -l "$text" 2>/dev/null || return 1
  sleep "$PII_REPLAY_SUBMIT_DELAY"
  tmux send-keys -t "=$session:^.{top-left}" Enter 2>/dev/null || return 1
  return 0
}

# pii_switch_claude <причина> [interrupt] — перезапустить claude в нужном режиме pii-proxy.
# Зовёт watchdog.sh; от него берёт AGENT, SESSION, PII_WANT, log и restart_session.
# Возврат через прокси — только из простоя (вызов без interrupt). Переход напрямую (решение
# владельца 23.11.2026) может прервать идущий ход: прокси мёртв, ход всё равно упадёт. Тогда
# Escape, перезапуск с --continue (разговор сохраняется) и повтор последнего входящего, если ход
# на него не ответил (lib/pii-replay.sh), — пользователь не пересылает его сам.
pii_switch_claude() {
  local want="$PII_WANT" from replay_ts="" text=""
  from="$(pii_mode_get "$AGENT")"
  if [ "$want" = "$PII_MODE_DIRECT" ]; then
    replay_ts="$(pii_replay_pending "$AGENT" || true)"
  fi
  if [ "${2:-}" = "interrupt" ]; then
    log "pii-proxy не отвечает посреди хода — прерываю ход"
    tmux send-keys -t "=$SESSION:^.{top-left}" Escape 2>/dev/null || true
    sleep "$PII_INTERRUPT_SETTLE_SEC"
    # Ход успел закончиться сам, пока решали, — ответ был, повтор задвоил бы его.
    if [ -n "$replay_ts" ] && [ "$(pii_replay_pending "$AGENT" || true)" != "$replay_ts" ]; then
      replay_ts=""
    fi
  fi
  if [ -n "$replay_ts" ]; then
    text="$(pii_replay_text "$AGENT")"
    # Метку ставим до набора: рестарт демона посреди повтора не должен повторить ещё раз.
    pii_replay_mark "$AGENT" "$replay_ts"
  fi
  mkdir -p "$(dirname "$(pii_switch_continue_file "$AGENT")")" 2>/dev/null || true
  : > "$(pii_switch_continue_file "$AGENT")" 2>/dev/null || true
  # Третий аргумент — режим для start-agent (PII_START_MODE): direct он не переигрывает по
  # /health (иначе юнит прокси, поднятый на старте, тут же возвращал агента на прокси, и одна
  # следующая неудача снова уводила напрямую — рестарт каждые 30–40 с).
  restart_session "pii-proxy: режим $from → $want ($1)" noflap "$want"
  if [ -n "$text" ]; then
    if pii_replay_type "$SESSION" "$text"; then
      log "pii-proxy: последнее входящее повторено напрямую"
    else
      log "pii-proxy: промпт не дождался — последнее входящее не повторено"
    fi
    PREV_TAIL=""
  fi
  return 0
}
