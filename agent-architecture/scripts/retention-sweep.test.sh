#!/usr/bin/env bash
set -euo pipefail

# Тест retention-sweep.sh на фикстурах во временном каталоге (живые данные не трогаются).
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWEEP="$HERE/retention-sweep.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

OLD_DAYS=45
FRESH_DAYS=2
fail() { echo "FAIL: $*" >&2; exit 1; }
old()   { touch -d "$OLD_DAYS days ago" "$@"; }
fresh() { touch -d "$FRESH_DAYS days ago" "$@"; }

WS="$TMP/ws"; ST="$TMP/st"; LD="$TMP/listener/dev"; BK="$TMP/bk"
mkdir -p "$WS/logs" "$WS/outbox" "$WS/tmp" "$WS/raw" "$ST/logs" "$ST/inbox" "$LD" "$BK/old"
echo x > "$WS/logs/verbose-2020-01-01.jsonl"; old "$WS/logs/verbose-2020-01-01.jsonl"
echo x > "$WS/logs/verbose-2099-01-01.jsonl"; fresh "$WS/logs/verbose-2099-01-01.jsonl"
echo "line" > "$WS/logs/hooks.log"
echo x > "$WS/outbox/a.bin"; old "$WS/outbox/a.bin"
echo x > "$WS/outbox/b.bin"; fresh "$WS/outbox/b.bin"
echo x > "$WS/tmp/c.tmp"; touch -d "10 days ago" "$WS/tmp/c.tmp"
echo x > "$WS/raw/r.md"; old "$WS/raw/r.md"
echo x > "$ST/inbox/photo.jpg"; old "$ST/inbox/photo.jpg"
echo x > "$LD/1_old.log"; old "$LD/1_old.log"
echo x > "$LD/2_new.log"; fresh "$LD/2_new.log"
echo 1 > "$BK/old/EXPIRES"

# dry-run ничего не меняет
snap_before="$(find "$TMP" -type f | sort | xargs md5sum)"
bash "$SWEEP" --dry-run --workspace "$WS" --state-dir "$ST" --listener-log-dir "$LD" \
  --backup-dir "$BK" >/dev/null
snap_after="$(find "$TMP" -type f | sort | xargs md5sum)"
[ "$snap_before" = "$snap_after" ] || fail "dry-run изменил файлы"

bash "$SWEEP" --workspace "$WS" --state-dir "$ST" --listener-log-dir "$LD" \
  --backup-dir "$BK" >/dev/null

[ ! -e "$WS/logs/verbose-2020-01-01.jsonl" ] || fail "старый verbose не удалён"
[ -e "$WS/logs/verbose-2099-01-01.jsonl" ] || fail "свежий verbose удалён"
[ ! -s "$WS/logs/hooks.log" ] || fail "живой журнал не обнулён"
ls "$WS"/logs/hooks.log.* >/dev/null 2>&1 || fail "нет ротированной копии"
[ ! -e "$WS/outbox/a.bin" ] || fail "старый outbox не удалён"
[ -e "$WS/outbox/b.bin" ] || fail "свежий outbox удалён"
[ ! -e "$WS/tmp/c.tmp" ] || fail "старый tmp (по сроку 7 дн.) не удалён"
[ -e "$WS/raw/r.md" ] || fail "raw удалён при выключенном сроке"
[ ! -e "$ST/inbox/photo.jpg" ] || fail "старое вложение не удалено"
[ ! -e "$LD/1_old.log" ] || fail "старый журнал listener не удалён"
[ -e "$LD/2_new.log" ] || fail "свежий журнал listener удалён"
[ ! -e "$BK/old" ] || fail "просроченный бэкап не удалён"

# защищённые пути (память и контекст) целы при нулевых сроках и любом возрасте
PROT="$TMP/prot"; mkdir -p "$PROT/core/hot" "$PROT/knowledge" "$PROT/agents" "$PROT/scenarios" \
  "$PROT/raw" "$PROT/state/multichat/chats/42/inbox"
for f in core/hot/recent.md core/recall-events.jsonl core/active/episodic.md knowledge/k.md \
  agents/a.md scenarios/s.md raw/r.md CLAUDE.md state/multichat/sessions.json \
  state/multichat/chats/42/persona.md state/multichat/chats/42/context.md; do
  mkdir -p "$(dirname "$PROT/$f")"; echo x > "$PROT/$f"; old "$PROT/$f"
done
ATT="$PROT/state/multichat/chats/42/inbox/att.jpg"; echo x > "$ATT"; old "$ATT"
mkdir -p "$PROT/chats/42"; echo x > "$PROT/chats/42/persona.md"; old "$PROT/chats/42/persona.md"
RETENTION_RAW_DAYS=0 RETENTION_LOG_DAYS=1 RETENTION_OUTBOX_DAYS=1 RETENTION_TMP_DAYS=1 \
  RETENTION_INBOX_DAYS=1 bash "$SWEEP" --workspace "$PROT" >/dev/null
for f in core/hot/recent.md core/recall-events.jsonl core/active/episodic.md knowledge/k.md \
  agents/a.md scenarios/s.md raw/r.md CLAUDE.md state/multichat/sessions.json \
  state/multichat/chats/42/persona.md state/multichat/chats/42/context.md chats/42/persona.md; do
  [ -e "$PROT/$f" ] || fail "защищённый путь удалён: $f"
done
[ ! -e "$ATT" ] || fail "старое вложение чата не удалено"

# срок raw включается переменной
RETENTION_RAW_DAYS=30 bash "$SWEEP" --workspace "$WS" >/dev/null
[ ! -e "$WS/raw/r.md" ] || fail "RETENTION_RAW_DAYS не сработал"

echo "retention-sweep: все проверки пройдены"
