#!/usr/bin/env bash
# Юнит-тест guard'а skill-creator: вставка, срабатывание без `claude`, пропуск при наличии,
# идемпотентность. Сети не трогает — фейковый скилл в mktemp.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$HERE/skill-creator-guard.py"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$TMP/skill/scripts"
for s in run_eval improve_description; do
  cat > "$TMP/skill/scripts/$s.py" <<'PY'
#!/usr/bin/env python3
"""module docstring that must not break anything"""
import sys


def main():
    sys.stderr.write("RAN\n")


if __name__ == "__main__":
    main()
PY
done

# Изолированный PATH: только python3, без claude.
BIN="$TMP/bin"; mkdir -p "$BIN"
ln -s "$(command -v python3)" "$BIN/python3"

python3 "$GUARD" "$TMP/skill" >/dev/null

# 1. Маркер вставлен в оба скрипта.
for s in run_eval improve_description; do
  grep -q 'labops-guard:' "$TMP/skill/scripts/$s.py" || fail "guard не вставлен в $s.py"
  python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$TMP/skill/scripts/$s.py" \
    || fail "$s.py не парсится после вставки"
done

# 2. Без claude на PATH — чистый выход 0, сообщение о пропуске, main НЕ выполнился.
set +e
out="$(PATH="$BIN" python3 "$TMP/skill/scripts/run_eval.py" 2>&1)"; rc=$?
set -e
[ "$rc" -eq 0 ] || fail "без claude ожидался выход 0, получен $rc"
echo "$out" | grep -q 'skipped' || fail "нет сообщения о пропуске: $out"
echo "$out" | grep -q 'RAN' && fail "main выполнился, хотя claude нет: $out"

# 3. С claude на PATH — guard пропускает, main выполняется.
printf '#!/bin/sh\necho stub\n' > "$BIN/claude"; chmod +x "$BIN/claude"
set +e
out2="$(PATH="$BIN" python3 "$TMP/skill/scripts/run_eval.py" 2>&1)"; rc2=$?
set -e
[ "$rc2" -eq 0 ] || fail "с claude ожидался выход 0, получен $rc2"
echo "$out2" | grep -q 'RAN' || fail "main не выполнился при наличии claude: $out2"

# 4. Идемпотентность: повтор = skip, маркер один.
out3="$(python3 "$GUARD" "$TMP/skill")"
echo "$out3" | grep -q 'skip' || fail "повторный запуск не сообщил skip: $out3"
n="$(grep -c 'labops-guard:' "$TMP/skill/scripts/run_eval.py")"
[ "$n" -eq 1 ] || fail "маркер задвоился ($n)"

echo "skill-creator-guard: ok"
