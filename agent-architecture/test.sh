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

echo "── 7. Heartbeat-хук живости (heartbeat-hook.sh) ──"
if bash agent-template/hooks/heartbeat-hook.test.sh >/dev/null 2>&1; then
  ok "heartbeat-hook.sh: атомарная запись / sdk-guard / advance — юнит-тест зелёный"
else
  bad "heartbeat-hook.sh: юнит-тест провален (agent-template/hooks/heartbeat-hook.test.sh)"
fi

echo "── 7b. start-agent: проброс agent.env с placeholder-guard ──"
# Регрессия сессии 2026-07-19: agent.env существовал, но start-agent.sh не
# пробрасывал его в tmux-сессию → хуки не видели MCP_HOST/AGENT_BEARER даже при
# развёрнутом бэкенде. Проверяем, что source + guard от CHANGE_ME на месте.
if grep -q 'agent\.env' orchestration/start-agent.sh \
   && grep -q 'CHANGE_ME' orchestration/start-agent.sh; then
  ok "start-agent.sh source'ит agent.env и содержит placeholder-guard (CHANGE_ME)"
else
  bad "start-agent.sh не пробрасывает agent.env / нет guard'а CHANGE_ME — recall не заработает даже с развёрнутым second_brain"
fi

echo "── 8. Страховочный flush в общий мозг (brain-flush.sh) ──"
if bash agent-template/scripts/brain-flush.test.sh >/dev/null 2>&1; then
  ok "brain-flush.sh: guard/dedup/fail-open — юнит-тест зелёный"
else
  bad "brain-flush.sh: юнит-тест провален (agent-template/scripts/brain-flush.test.sh)"
fi

echo "── 9. Изоляция плагина по агентам (lib/plugin.sh) ──"
if bash orchestration/lib/plugin.test.sh >/dev/null 2>&1; then
  ok "plugin.sh: приватная копия / миграция симлинка / разный cwd — юнит-тест зелёный"
else
  bad "plugin.sh: юнит-тест провален (orchestration/lib/plugin.test.sh)"
fi

# Регрессия: симлинк плагина в воркспейс — это и есть баг общего canonical cwd.
if grep -rn 'ln -s .*TG_PLUGIN_DIR.*labops-tg-plugin' --include=*.sh \
     --exclude=test.sh . >/dev/null 2>&1; then
  bad "плагин снова линкуется симлинком — используйте provision_plugin (lib/plugin.sh)"
else
  ok "плагин нигде не линкуется симлинком в воркспейс"
fi

echo "── 9b. Классификатор панели: overlay ≠ зависание (lib/pane.sh) ──"
if bash orchestration/lib/pane.test.sh >/dev/null 2>&1; then
  ok "pane.sh: слеш-команда не принимается за смерть TUI — юнит-тест зелёный"
else
  bad "pane.sh: юнит-тест провален (orchestration/lib/pane.test.sh)"
fi

echo "── 9c. Контракт канала: ответ через reply (CLAUDE.md.template) ──"
# Регрессия 2026-07-20: агент ответил оператору текстом в сессии, не вызвав
# `reply`. Оператор увидел молчание и решил, что агент завис. Инструкции о том,
# что отвечать надо инструментом, в шаблоне не было вообще — контракт держался
# на догадке модели. Проверяем, что он записан явно.
CT="agent-template/templates/CLAUDE.md.template"
if grep -qiE '`reply`' "$CT" && grep -qiE 'invisible to the operator|not.*visible.*operator' "$CT"; then
  ok "CLAUDE.md.template задаёт контракт: ответ оператору только через reply"
else
  bad "CLAUDE.md.template не объясняет, что отвечать надо через reply — ответы агента будут теряться"
fi

echo "── 10. Изоляция per-agent окружения (создание агента из сессии агента) ──"
# new-agent.sh почти всегда запускается ИЗ сессии другого агента, а tmux
# new-session строит env сессии из ГЛОБАЛЬНОГО env tmux-сервера (загрязнённого
# первым стартовавшим агентом) плюс -e — НЕ из env процесса start-agent.
# Отсюда класс тихих отказов: переменную добавили в channel.env, но забыли в
# списке -e → у нового агента чужой bot_id ("bot_id mismatch -> poller exited")
# и мёртвый webhook-порт, без единой ошибки в логах. Гейт статический.
NA="skills/create-agent/new-agent.sh"
SA="orchestration/start-agent.sh"

ch_vars="$(awk '/cat > "\$CH_ENV" <<ENV/,/^ENV$/' "$NA" | grep -oE '^[A-Z_]+=' | tr -d '=' | sort -u)"
e_vars="$(awk '/^tmux new-session/,/^ *"\$CLAUDE_BIN"/' "$SA" | grep -oE '^[[:space:]]*-e [A-Z_]+' | awk '{print $2}' | sort -u)"
unset_vars="$(sed -n '/^unset /,/^$/p' "$NA" | grep -oE '\b[A-Z][A-Z_]+\b' | grep -v '^unset$' | sort -u)"

# Пустая выборка = гейт проходит вхолостую и ничего не охраняет. Валим явно.
if [ -z "$ch_vars" ] || [ -z "$e_vars" ] || [ -z "$unset_vars" ]; then
  bad "env-isolation: не удалось извлечь списки переменных (изменилась структура $NA/$SA?) — гейт не работает"
else
  # A. всё, что пишется в channel.env, обязано пробрасываться через -e
  missing_e="$(comm -23 <(echo "$ch_vars") <(echo "$e_vars") | tr '\n' ' ')"
  if [ -n "${missing_e// /}" ]; then
    bad "start-agent.sh: нет в списке tmux -e → утечёт значение агента-родителя: $missing_e"
  else
    ok "все переменные channel.env пробрасываются через tmux -e ($(echo "$ch_vars" | wc -l) шт.)"
  fi

  # B. идентичность агента обязана сбрасываться в new-agent.sh.
  # Исключения: ввод оператора (не наследование, а намеренная передача) и
  # константы, одинаковые у всех агентов.
  exempt="TELEGRAM_BOT_TOKEN TELEGRAM_ALLOWED_USER_IDS TELEGRAM_ALLOWED_CHAT_IDS
TELEGRAM_WEBHOOK_HOST TELEGRAM_MEMORY_ENABLED TELEGRAM_MEMORY_SOURCE_TAG"
  identity="$(comm -23 <(echo "$ch_vars") <(echo "$exempt" | tr ' ' '\n' | sed '/^$/d' | sort -u))"
  missing_unset="$(comm -23 <(echo "$identity") <(echo "$unset_vars") | tr '\n' ' ')"
  if [ -n "${missing_unset// /}" ]; then
    bad "new-agent.sh: идентичность агента не сбрасывается (unset) → унаследуется от родителя: $missing_unset"
  else
    ok "идентичность агента сбрасывается перед созданием нового ($(echo "$identity" | wc -l) шт.)"
  fi
fi

echo "── 11. Near-real-time межагентная доставка задач (task-poller.sh) ──"
if bash agent-template/scripts/task-poller.test.sh >/dev/null 2>&1; then
  ok "task-poller.sh: адресный фильтр / idle-гейт / идемпотентность — юнит-тест зелёный"
else
  bad "task-poller.sh: юнит-тест провален (agent-template/scripts/task-poller.test.sh)"
fi
# Регрессия: start-agent.sh обязан запускать поллер, иначе доставка задач мертва.
if grep -q 'task-poller.sh' orchestration/start-agent.sh; then
  ok "start-agent.sh запускает task-poller"
else
  bad "start-agent.sh не запускает task-poller — задачи не будут доставляться в сессию"
fi
# Регрессия: agent-template/install.sh обязан КОПИРОВАТЬ поллер в воркспейс нового
# агента (список скриптов явный) — иначе новый агент не подключится к общению.
if grep -qE 'for script in .*task-poller\.sh' agent-template/install.sh; then
  ok "install.sh копирует task-poller.sh новому агенту (подключение к общению)"
else
  bad "install.sh не копирует task-poller.sh — новый агент не будет получать межагентные задачи"
fi
# Поллер должен оставаться на подписке: никакого claude -p/--print внутри него.
if grep -vE '^[[:space:]]*#' agent-template/scripts/task-poller.sh \
     | grep -qE 'claude +-p|claude +--print'; then
  bad "task-poller.sh использует headless claude — это SDK-кредиты, запрещено (см. AGENT_ROUTER.md)"
else
  ok "task-poller.sh не тащит headless claude (остаётся на подписке)"
fi

echo
if [ "$fail" -eq 0 ]; then
  printf "${G}✅ self-test пройден (%d проверок).${N}\n" "$pass"; exit 0
else
  printf "${R}❌ self-test провален: %d ошибок.${N}\n" "$fail"; exit 1
fi
