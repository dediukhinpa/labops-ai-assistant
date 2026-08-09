#!/usr/bin/env bash
# doctor-request.sh — очередь запросов «/doctor» между плагином и watchdog.
#
# ПОЧЕМУ ЧЕРЕЗ ФАЙЛ, А НЕ НАПРЯМУЮ ИЗ ПЛАГИНА:
# tg-плагин живёт ВНУТРИ сессии агента (bun — потомок claude). Если doctor решит
# перезапустить зависшую сессию, плагин умрёт вместе с ней — и ответ оператору
# «починил» отправить будет уже некому. Watchdog же — внешний супервизор, он
# переживает любой рестарт сессии. Поэтому плагин только КЛАДЁТ запрос, а
# исполняет его и отчитывается watchdog.
#
# ВТОРОЙ ВХОД — аварийный. Когда агент недоступен, плагин не работает, и /doctor
# из Telegram никем не читается: команда нужна ровно тогда, когда доставить её
# нечем. На этот случай watchdog сам заглядывает в Telegram — но ТОЛЬКО пока
# висит тревога о недоступности (см. doctor_poll_telegram): getUpdates от второго
# читателя обрывает long-poll плагина, и при живом плагине это навредило бы.
#
# Библиотека: при сорсинге ничего не делает и не логирует.

# Каталог состояния запросов доктора.
_doctor_state_dir() {   # <agent>
  printf '%s' "${CLAUDE_LAB:-$HOME/.claude-lab}/shared/state/${1}"
}

doctor_request_path() {   # <agent>
  printf '%s/doctor.request' "$(_doctor_state_dir "$1")"
}

# doctor_request_pending <agent> — есть непрочитанный запрос?
doctor_request_pending() {
  [ -f "$(doctor_request_path "$1")" ]
}

# doctor_request_put <agent> [chat_id] — положить запрос (идемпотентно).
doctor_request_put() {
  local agent="$1" chat="${2:-}" f
  f="$(doctor_request_path "$agent")"
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 1
  printf '%s' "$chat" > "$f" 2>/dev/null || return 1
  return 0
}

# doctor_request_take <agent> — ЗАБРАТЬ запрос: печатает chat_id (может быть
# пустым) и возвращает 0, если запрос был. Забирает через mv, чтобы два читателя
# не выполнили один и тот же запрос дважды.
doctor_request_take() {
  local agent="$1" f taken
  f="$(doctor_request_path "$agent")"
  [ -f "$f" ] || return 1
  taken="$f.taken.$$"
  mv "$f" "$taken" 2>/dev/null || return 1
  cat "$taken" 2>/dev/null || true
  rm -f "$taken" 2>/dev/null || true
  return 0
}

# ── Аварийный приём команды прямо из Telegram ────────────────────────────────
# Вызывать ТОЛЬКО когда плагин заведомо не читает апдейты (висит тревога о
# недоступности). offset=-1 возвращает последний апдейт и НЕ подтверждает его,
# поэтому плагин, вернувшись к жизни, получит всё, что накопилось.
DOCTOR_TG_MAX_AGE="${DOCTOR_TG_MAX_AGE:-600}"   # старые команды не исполняем

# doctor_poll_telegram <agent> <bot-token> — если оператор прислал /doctor,
# кладёт запрос и возвращает 0. Иначе 1. Никогда не фатальна.
doctor_poll_telegram() {
  local agent="$1" token="$2" api resp seen_file seen out
  [ -n "$token" ] || return 1
  api="${DOCTOR_TG_API:-https://api.telegram.org}"

  resp="$(curl -s -m 10 "${api}/bot${token}/getUpdates?offset=-1&limit=1&timeout=0" 2>/dev/null || true)"
  [ -n "$resp" ] || return 1

  seen_file="$(_doctor_state_dir "$agent")/doctor.last_update_id"
  seen="$(cat "$seen_file" 2>/dev/null || echo 0)"
  case "$seen" in ''|*[!0-9]*) seen=0 ;; esac

  # Разбор строго: команда /doctor, свежая, и update_id больше уже обработанного.
  # Без проверки update_id offset=-1 отдавал бы одну и ту же команду вечно.
  out="$(printf '%s' "$resp" | python3 -c '
import json, sys, time

raw = sys.stdin.read()
try:
    data = json.loads(raw)
except Exception:
    raise SystemExit(0)
if not data.get("ok"):
    raise SystemExit(0)

seen = int(sys.argv[1])
max_age = int(sys.argv[2])
now = time.time()

for upd in data.get("result") or []:
    uid = upd.get("update_id") or 0
    if uid <= seen:
        continue
    msg = upd.get("message") or upd.get("channel_post") or {}
    text = (msg.get("text") or "").strip().lower()
    # /doctor или /doctor@botname, с аргументами или без
    head = text.split()[0] if text else ""
    head = head.split("@", 1)[0]
    if head != "/doctor":
        continue
    if now - (msg.get("date") or 0) > max_age:
        continue
    chat = (msg.get("chat") or {}).get("id")
    print("%s %s" % (uid, "" if chat is None else chat))
    break
' "$seen" "$DOCTOR_TG_MAX_AGE" 2>/dev/null || true)"

  [ -n "$out" ] || return 1

  local uid chat
  uid="${out%% *}"
  chat="${out#* }"
  mkdir -p "$(dirname "$seen_file")" 2>/dev/null || true
  printf '%s' "$uid" > "$seen_file" 2>/dev/null || true
  doctor_request_put "$agent" "$chat" || return 1
  return 0
}
