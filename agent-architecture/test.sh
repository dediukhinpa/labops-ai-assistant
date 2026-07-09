#!/usr/bin/env bash
#
# test.sh — self-test репозитория labops-agent-architecture.
# Прогоняется install.sh в конце установки как gate (всё должно быть зелёным).
#
# Проверяет: синтаксис всех bash-скриптов, компиляцию python, ОТСУТСТВИЕ секретов.

set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR"

G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'; N='\033[0m'
pass=0; fail=0
ok()  { printf "${G}✓${N} %s\n" "$*"; pass=$((pass+1)); }
bad() { printf "${R}✗${N} %s\n" "$*"; fail=$((fail+1)); }

echo "── 1. Синтаксис bash-скриптов ──"
while IFS= read -r f; do
  if bash -n "$f" 2>/dev/null; then :; else bad "bash -n: $f"; fi
done < <(find . -name '*.sh' -not -path '*/node_modules/*')
[ "$fail" -eq 0 ] && ok "все bash-скрипты разбираются"

echo "── 2. Компиляция python ──"
if command -v python3 >/dev/null; then
  pyfail=0
  while IFS= read -r f; do
    python3 -m py_compile "$f" 2>/dev/null || { bad "py_compile: $f"; pyfail=1; }
  done < <(find . -name '*.py' -not -path '*/__pycache__/*')
  [ "$pyfail" -eq 0 ] && ok "все python-файлы компилируются"
else
  printf "${Y}⚠${N} python3 не найден — пропуск\n"
fi

echo "── 3. Нет секретов (бот-токены / реальные ID / Tailscale) ──"
if grep -rnE '[0-9]{8,}:AA[A-Za-z0-9_-]{20,}' . --include='*.sh' --include='*.md' --include='*.py' --include='*.template' --exclude=test.sh 2>/dev/null | grep -q .; then
  bad "найдены литералы Telegram бот-токенов!"
else
  ok "бот-токенов нет"
fi
# Личные ID/IP больше не хранятся в этом репо как литералы (вычищены из дерева и
# истории). Бот-токены ловит regex выше; персональные Telegram-id паттерном не
# отличить от обычных чисел без ложных срабатываний, поэтому отдельной проверки нет.

echo "── 4. Модель и авторизация Claude Code учтены ──"
# 4a. settings.json реально задаёт модель (не только описательные доки)
if grep -q '"model"' agent-template/templates/settings.json.template; then
  ok "settings.json.template задаёт \"model\""
else
  bad "settings.json.template не задаёт \"model\" — агент стартует на дефолтной модели CLI"
fi
# 4b. create-agent flow спрашивает и пробрасывает PRIMARY_MODEL
if grep -qE '^ask +PRIMARY_MODEL' skills/create-agent/new-agent.sh \
   && grep -qE 'PRIMARY_MODEL="\$PRIMARY_MODEL"' skills/create-agent/new-agent.sh; then
  ok "new-agent.sh спрашивает и пробрасывает PRIMARY_MODEL"
else
  bad "new-agent.sh не спрашивает/не пробрасывает PRIMARY_MODEL в скаффолдер"
fi
# 4c. учтён шаг подключения модели (subscription login — реальный вход,
# ~/.claude/.credentials.json — НЕ claude setup-token/CLAUDE_CODE_OAUTH_TOKEN:
# та авторизует только headless claude -p, персистентная TUI-сессия агента
# (start-agent.sh) её не читает — см. install.sh для деталей)
if grep -qE '\.claude/\.credentials\.json' install.sh; then
  ok "учтён шаг авторизации Claude Code (интерактивный вход, credentials.json)"
else
  bad "нет шага подключения модели — TUI-сессия агента не достучится до модели"
fi
# 4d. headless claude -p / claude setup-token НЕ используются — весь Claude-трафик
# должен оставаться в подписке (SDK-credit billing rule), см. CLAUDE.md.
# Комментарии, которые объясняют этот запрет (и упоминают запрещённые команды
# как текст), не считаются — исключаем строки, где это первый непробельный
# символ после file:line: это "#".
HEADLESS_HITS="$(grep -rnE 'claude[[:space:]]+setup-token|claude[[:space:]].*[[:space:]]-p([[:space:]]|"|$)|claude[[:space:]]+--print' \
  install.sh skills/create-agent/new-agent.sh orchestration/*.sh 2>/dev/null \
  | grep -vE ':[0-9]+:[[:space:]]*#')"
if [ -n "$HEADLESS_HITS" ]; then
  bad "найден headless claude -p / claude setup-token — бьёт по отдельному SDK-credit биллингу:"
  echo "$HEADLESS_HITS" | sed 's/^/    /'
else
  ok "headless claude -p / claude setup-token нигде не используются"
fi

echo "── 5. Watchdog-алерты оператору (lib/notify.sh) ──"
if bash orchestration/lib/notify.test.sh >/dev/null 2>&1; then
  ok "notify.sh: opt-in / троттлинг / non-fatal — юнит-тест зелёный"
else
  bad "notify.sh: юнит-тест провален (orchestration/lib/notify.test.sh)"
fi

echo "── 6. Мониторинг бэкенда (second_brain-monitor.sh) ──"
if bash orchestration/second_brain-monitor.test.sh >/dev/null 2>&1; then
  ok "second_brain-monitor.sh: переходы down/recovery + проба порта — юнит-тест зелёный"
else
  bad "second_brain-monitor.sh: юнит-тест провален (orchestration/second_brain-monitor.test.sh)"
fi

echo
if [ "$fail" -eq 0 ]; then
  printf "${G}✅ self-test пройден (%d проверок).${N}\n" "$pass"; exit 0
else
  printf "${R}❌ self-test провален: %d ошибок.${N}\n" "$fail"; exit 1
fi
