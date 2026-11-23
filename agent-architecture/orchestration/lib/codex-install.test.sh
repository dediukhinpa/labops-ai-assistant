#!/usr/bin/env bash
# Юнит-тесты lib/codex-install.sh: скачивание пакета, проверка sha256, ссылка в ~/.local/bin.
# Сеть не нужна: релиз подменяется каталогом file:// с поддельным пакетом.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME"
# shellcheck source=codex-install.sh
. "$HERE/codex-install.sh"

pass=0; fail=0
eq() { if [ "$1" = "$2" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $3 (got '$1', want '$2')"; fi; }

TARGET="$(codex_package_target)" || { echo "SKIP: платформа не поддерживается"; exit 0; }

# Поддельный пакет: bin/codex печатает версию, как настоящий.
make_pkg() {   # <версия> <выход.tar.gz>
  local d="$TMP/build"
  rm -rf "$d"; mkdir -p "$d/bin"
  printf '#!/usr/bin/env bash\necho "codex-cli %s"\n' "$1" > "$d/bin/codex"
  chmod +x "$d/bin/codex"
  tar -czf "$2" -C "$d" bin
}
REL="$TMP/rel/rust-v$CODEX_PINNED_VERSION"
mkdir -p "$REL"
make_pkg "$CODEX_PINNED_VERSION" "$REL/codex-package-$TARGET.tar.gz"
CODEX_RELEASE_BASE="file://$TMP/rel"
GOOD_SUM="$(sha256sum "$REL/codex-package-$TARGET.tar.gz" | cut -d' ' -f1)"

# 1. Сумма не совпала — ничего не ставится.
CODEX_SHA256_X86_64="0000"; CODEX_SHA256_AARCH64="0000"
codex_install_pinned >/dev/null 2>"$TMP/err"; eq "$?" 1 "чужая сумма — отказ"
grep -q "контрольная сумма" "$TMP/err"; eq "$?" 0 "причина в stderr"
[ ! -e "$HOME/.local/bin/codex" ]; eq "$?" 0 "ссылка не создана"
[ ! -e "$(codex_install_root)/$CODEX_PINNED_VERSION" ]; eq "$?" 0 "каталог версии не создан"

# 2. Верная сумма — пакет в каталоге версии, ссылка в ~/.local/bin.
CODEX_SHA256_X86_64="$GOOD_SUM"; CODEX_SHA256_AARCH64="$GOOD_SUM"
out="$(codex_install_pinned)"; eq "$?" 0 "установка"
eq "$out" "$HOME/.local/bin/codex" "печатает путь к codex"
eq "$(readlink "$HOME/.local/bin/codex")" "$(codex_install_root)/$CODEX_PINNED_VERSION/bin/codex" "ссылка на версию"
eq "$(codex_version_of "$HOME/.local/bin/codex")" "$CODEX_PINNED_VERSION" "версия"
eq "$(ls -A "$(codex_install_root)" | grep -c '^\.download')" 0 "временный каталог убран"

# 3. Повтор не качает: релиза больше нет, а установка проходит.
rm -rf "$TMP/rel"
codex_install_pinned >/dev/null; eq "$?" 0 "повтор без сети"

# 4. Нет релиза и нет установленной версии — понятная ошибка.
rm -rf "$(codex_install_root)"
codex_install_pinned >/dev/null 2>"$TMP/err"; eq "$?" 1 "нет пакета — отказ"
grep -q "не удалось скачать" "$TMP/err"; eq "$?" 0 "причина: не скачалось"

# 5. Закреплённые суммы — 64 hex-символа (опечатка сломала бы установку у всех).
for s in "$(. "$HERE/codex-install.sh"; echo "$CODEX_SHA256_X86_64")" \
         "$(. "$HERE/codex-install.sh"; echo "$CODEX_SHA256_AARCH64")"; do
  [[ "$s" =~ ^[0-9a-f]{64}$ ]]; eq "$?" 0 "формат закреплённой суммы"
done

# 6. Сверка версии с закреплённой (new-agent.sh пишет расхождение в DEGRADED).
mkdir -p "$TMP/vers"
printf '#!/usr/bin/env bash\necho "codex-cli %s"\n' "$CODEX_PINNED_VERSION" > "$TMP/vers/pinned"
printf '#!/usr/bin/env bash\necho "codex-cli 0.1.0"\n' > "$TMP/vers/old"
printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/vers/broken"
chmod +x "$TMP/vers/"*
codex_pinned_mismatch "$TMP/vers/pinned" >/dev/null; eq "$?" 1 "закреплённая версия — не расхождение"
eq "$(codex_pinned_mismatch "$TMP/vers/old")" "0.1.0" "другая версия — печатается"
codex_pinned_mismatch "$TMP/vers/old" >/dev/null; eq "$?" 0 "другая версия — расхождение"
eq "$(codex_pinned_mismatch "$TMP/vers/broken")" "неизвестна" "версию не узнать — расхождение"

echo "codex-install.test.sh: $pass ok, $fail fail"
[ "$fail" -eq 0 ]
