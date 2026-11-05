#!/usr/bin/env bash
# Тесты pii-setup.sh без root и без сети: HOME и CLAUDE_LAB во временном каталоге, systemctl -
# заглушка, зависимости не ставятся (PII_SKIP_BUILD=1). Живые юниты и ~/.config не затрагиваются.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

export HOME="$TMP/home"
export CLAUDE_LAB="$TMP/lab"
export PII_RUNTIME_DIR="$TMP/runtime" PII_CONFIG_DIR="$TMP/cfg" PII_UNIT_DIR="$TMP/units"
export PII_SKIP_BUILD=1 PII_SYSTEMCTL="$TMP/systemctl"
mkdir -p "$HOME" "$CLAUDE_LAB"
printf '#!/usr/bin/env bash\necho "$*" >> "%s/systemctl.log"\n' "$TMP" > "$TMP/systemctl"
chmod +x "$TMP/systemctl"

mkagent() {   # <id> - воркспейс с настоящим шаблоном settings.json
  mkdir -p "$CLAUDE_LAB/$1/.claude"
  sed -e 's|{{PRIMARY_MODEL}}|sonnet|' -e 's|{{AGENT_ID}}|'"$1"'|g' -e 's|{{PII_PROXY_URL}}||' \
    "$HERE/../agent-template/templates/settings.json.template" > "$CLAUDE_LAB/$1/.claude/settings.json"
}
mkagent alpha; mkagent beta

# 1. Отключение: ничего не создаётся, предупреждение громкое
out="$(SKIP_PII_PROXY=1 bash "$HERE/pii-setup.sh" agent alpha 2>&1)"
echo "$out" | grep -q 'ОТКЛЮЧЕНО' || fail "нет громкого предупреждения при SKIP_PII_PROXY=1"
[ ! -e "$TMP/cfg" ] || fail "при отключении что-то создано"

# 2. host: токен 600, env сервиса, юнит
bash "$HERE/pii-setup.sh" host >/dev/null 2>&1 || fail "host упал"
[ "$(stat -c %a "$TMP/cfg/pseudonymizer.token")" = "600" ] || fail "права токена"
grep -q '^PSEUDONYMIZER_API_TOKEN=.' "$TMP/cfg/pseudonymizer.env" || fail "нет токена в env"
[ -f "$TMP/units/labops-pseudonymizer.service" ] || fail "нет юнита сервиса"
grep -q '__' "$TMP/units/labops-pseudonymizer.service" && fail "плейсхолдеры в юните"
tok1="$(cat "$TMP/cfg/pseudonymizer.token")"
bash "$HERE/pii-setup.sh" host >/dev/null 2>&1
[ "$(cat "$TMP/cfg/pseudonymizer.token")" = "$tok1" ] || fail "повторный host перевыпустил токен"

# 3. agent: порт, env 600, settings, юнит-экземпляр
bash "$HERE/pii-setup.sh" agent alpha >/dev/null 2>&1 || fail "agent alpha упал"
bash "$HERE/pii-setup.sh" agent beta >/dev/null 2>&1 || fail "agent beta упал"
pa="$(sed -n 's/^PII_PROXY_PORT=//p' "$CLAUDE_LAB/alpha/.claude/secrets/pii-proxy.env")"
pb="$(sed -n 's/^PII_PROXY_PORT=//p' "$CLAUDE_LAB/beta/.claude/secrets/pii-proxy.env")"
[ -n "$pa" ] && [ -n "$pb" ] && [ "$pa" != "$pb" ] || fail "порты не уникальны: $pa $pb"
[ "$pa" -ge 6300 ] && [ "$pa" -lt 6400 ] || fail "порт вне диапазона 6300-6399: $pa"
[ "$(stat -c %a "$CLAUDE_LAB/alpha/.claude/secrets/pii-proxy.env")" = "600" ] || fail "права env"
grep -q '^PII_PROXY_AGENT_ID=alpha$' "$CLAUDE_LAB/alpha/.claude/secrets/pii-proxy.env" || fail "id"
grep -q 'enable --now labops-pii-proxy@alpha.service' "$TMP/systemctl.log" || fail "юнит не включён"
python3 - "$CLAUDE_LAB/alpha/.claude/settings.json" "$pa" <<'PY' || fail "settings.json не пропатчен"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["env"]["ANTHROPIC_BASE_URL"] == f"http://127.0.0.1:{sys.argv[2]}"
assert d["env"]["DISABLE_TELEMETRY"] == "1"
cmds = [h["command"] for g in d["hooks"]["SessionEnd"] for h in g["hooks"]]
assert len(cmds) == 2 and "brain-flush" in cmds[0] and "pii-proxy/hooks/session-end.sh" in cmds[1]
assert d["model"] == "sonnet"
PY

# 4. идемпотентность: повтор не плодит хуки и не меняет порт
bash "$HERE/pii-setup.sh" agent alpha >/dev/null 2>&1
n="$(grep -c 'session-end.sh' "$CLAUDE_LAB/alpha/.claude/settings.json")"
[ "$n" = "1" ] || fail "хук продублирован ($n)"
[ "$(sed -n 's/^PII_PROXY_PORT=//p' "$CLAUDE_LAB/alpha/.claude/secrets/pii-proxy.env")" = "$pa" ] \
  || fail "порт изменился при повторе"

echo "OK: pii-setup.test.sh"
