#!/usr/bin/env bash
# tmux-test-isolation.test.sh — тесты с настоящим tmux не трогают чужой сервер.
#
# Воспроизводит условия, в которых test.sh запускает агент: $TMUX указывает на
# сервер его собственной сессии, то есть на сервер роя. Роль сервера роя играет
# приманка на своём сокете (-L). Все тесты с живым tmux прогоняются при $TMUX,
# указывающей на приманку, и после прогона в ней обязана остаться ровно та
# сессия, что была. До фикса pane-recover.test.sh гасил бы приманку своим
# `kill-server`, а pane.test.sh заводил бы в ней свои сессии.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
pass=0; fail=0
ok()  { echo "✓ $*"; pass=$((pass+1)); }
bad() { echo "✗ $*"; fail=$((fail+1)); }

if ! command -v tmux >/dev/null 2>&1; then
  echo "tmux недоступен — тест пропущен"; exit 0
fi

# ── Статика: каждый тест, заводящий сессии, обязан изолироваться ─────────────
# Строки-комментарии не в счёт: там new-session упоминается как текст.
unguarded=""
while IFS= read -r f; do
  grep -vE '^[[:space:]]*#' "$f" | grep -q 'new-session' || continue
  grep -q 'tmux_test_isolate' "$f" || unguarded="$unguarded ${f#"$ROOT"/}"
done < <(find "$ROOT" -name '*.test.sh' -not -path '*/node_modules/*')
if [ -z "$unguarded" ]; then
  ok "все тесты с живым tmux заводят свой сервер (tmux_test_isolate)"
else
  bad "тесты с живым tmux без своего сервера:$unguarded"
fi

# ── Приманка вместо сервера роя ──────────────────────────────────────────────
DECOY="labops-decoy-$$"
BAIT="bait-$$"
cleanup() { command tmux -L "$DECOY" kill-server 2>/dev/null || true; }
trap cleanup EXIT
if ! command tmux -L "$DECOY" -f /dev/null new-session -d -s "$BAIT" "sleep 600" 2>/dev/null; then
  echo "приманку поднять не удалось — живая часть пропущена"
  echo "passed=$pass failed=$fail"; [ "$fail" -eq 0 ]; exit
fi
DECOY_SOCK="$(command tmux -L "$DECOY" display -p -t "=$BAIT" '#{socket_path}')"
DECOY_PID="$(command tmux -L "$DECOY" display -p -t "=$BAIT" '#{pid}')"
# Формат $TMUX: <сокет>,<pid сервера>,<индекс сессии> — ровно так её видит агент.
export TMUX="$DECOY_SOCK,$DECOY_PID,0"
export TMUX_PANE="%0"

decoy_sessions() { command tmux -L "$DECOY" list-sessions -F '#{session_name}' 2>/dev/null; }

# Без обвязки tmux действительно идёт в приманку — иначе тест ничего не доказывает.
if [ "$(tmux display -p '#{socket_path}' 2>/dev/null)" = "$DECOY_SOCK" ]; then
  ok "при заданной \$TMUX голый tmux попадает в сервер из неё (приманка работает)"
else
  bad "приманка не перехватывает голый tmux — проверка изоляции холостая"
fi

# Сама обвязка: после неё tmux смотрит в свой сервер, а приманку не видит.
probe_rc=0
(
  # shellcheck source=lib/tmux-test-isolation.sh
  . "$HERE/tmux-test-isolation.sh"
  d="$(mktemp -d)"
  tmux_test_isolate "$d"
  tmux new-session -d -s "probe-$$" "sleep 30" || exit 1
  tmux has-session -t "=probe-$$" || exit 1
  tmux_test_kill_server
  rm -rf "$d"
) || probe_rc=$?
[ "$probe_rc" -eq 0 ] && ok "обвязка заводит сессии в своём сервере" \
                      || bad "обвязка не смогла завести сессию в своём сервере"

# Все тесты с живым tmux — при $TMUX, указывающей на приманку. Их собственный
# результат проверяет test.sh отдельно; здесь важно только, цела ли приманка.
while IFS= read -r t; do
  [ "$t" = "$HERE/tmux-test-isolation.test.sh" ] && continue
  bash "$t" >/dev/null 2>&1 || true
  if [ "$(decoy_sessions)" = "$BAIT" ]; then
    ok "${t#"$ROOT"/}: сервер из \$TMUX не тронут"
  else
    bad "${t#"$ROOT"/}: тронул сервер из \$TMUX (сессии: $(decoy_sessions | tr '\n' ' '))"
  fi
done < <(grep -rl --include='*.test.sh' 'tmux_test_isolate' "$ROOT" | sort)

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
