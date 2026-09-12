#!/usr/bin/env bash
# Согласие на режим без проверок (--dangerously-skip-permissions).
#
# CLI 2.1.x показывает экран «Bypass Permissions mode» с выбором «No, exit /
# Yes, I accept» при КАЖДОМ старте такой сессии, пока согласие не записано на
# этой машине. Сам флаг вопрос не снимает — это отдельный гейт, как доверие к
# папке и мастер первого запуска. Пока экран висит, claude не доходит до
# промпта: MCP-серверы не стартуют, канал не поднимает порт, агент нем в
# Telegram, а watchdog видит «не отвечает». У клиента это крутилось больше часа
# (12.09.2026).
#
# Решение принимает ОПЕРАТОР и только явно: установщик спрашивает его один раз
# (см. new-agent.sh) и лишь тогда зовёт эту функцию. Молча за человека согласие
# не проставляется нигде — режим без проверок слишком дорого стоит, чтобы
# включаться побочным эффектом установки.
#
# Ключ лежит в ПОЛЬЗОВАТЕЛЬСКИХ настройках: CLI хранит это решение одно на
# машину, и settings.json воркспейса его не заменяет.

# shellcheck shell=bash

DANGEROUS_MODE_SETTINGS="${DANGEROUS_MODE_SETTINGS:-$HOME/.claude/settings.json}"
DANGEROUS_MODE_KEY="skipDangerousModePermissionPrompt"

# dangerous_mode_accepted [файл] — согласие уже записано?
dangerous_mode_accepted() {
  local cfg="${1:-$DANGEROUS_MODE_SETTINGS}"
  [ -f "$cfg" ] || return 1
  CFG="$cfg" KEY="$DANGEROUS_MODE_KEY" python3 - <<'PY' 2>/dev/null
import json, os, sys
try:
    with open(os.environ["CFG"], encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    sys.exit(1)
sys.exit(0 if isinstance(data, dict) and data.get(os.environ["KEY"]) is True else 1)
PY
}

# dangerous_mode_record_consent [файл] — записать согласие оператора, сохранив
# остальные настройки. Идемпотентна. 0 — согласие в файле есть, 1 — записать не
# удалось (старт агента из-за этого не останавливаем: вопрос тогда останется на
# экране, и его распознают watchdog и doctor — см. lib/pane.sh).
dangerous_mode_record_consent() {
  local cfg="${1:-$DANGEROUS_MODE_SETTINGS}"
  [ -n "$cfg" ] || return 1
  mkdir -p "$(dirname "$cfg")" 2>/dev/null || return 1
  CFG="$cfg" KEY="$DANGEROUS_MODE_KEY" python3 - <<'PY' 2>/dev/null || return 1
import json, os

cfg = os.environ["CFG"]
key = os.environ["KEY"]
try:
    with open(cfg, encoding="utf-8") as f:
        data = json.load(f)
except FileNotFoundError:
    data = {}
except Exception:
    # Битый или чужой формат не переписываем: чужие настройки дороже нашего
    # удобства, а невыставленный ключ означает лишь вопрос на экране.
    raise SystemExit(1)
if not isinstance(data, dict):
    raise SystemExit(1)
if data.get(key) is not True:
    data[key] = True
    tmp = cfg + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    os.replace(tmp, cfg)
PY
  return 0
}
