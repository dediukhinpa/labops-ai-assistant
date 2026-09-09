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

echo "── 7a. sdk-guard во всех хуках (защита от рекурсии) ──"
if bash agent-template/hooks/sdk-guard.test.sh >/dev/null 2>&1; then
  ok "sdk-guard: stop/session-start/precompact выходят без побочных эффектов — юнит-тест зелёный"
else
  bad "sdk-guard: юнит-тест провален (agent-template/hooks/sdk-guard.test.sh)"
fi

echo "── 7b. start-agent: проброс agent.env с placeholder-guard ──"
# Регрессия сессии 2026-07-19: agent.env существовал, но start-agent.sh не
# пробрасывал его в tmux-сессию → хуки не видели MCP_HOST/AGENT_BEARER даже при
# развёрнутом бэкенде. Проверяем, что source + guard от CHANGE_ME на месте.
# С 08.09.2026 окружение собирает lib/agent-env.sh (см. секцию 17), проверяем там.
if grep -q 'agent\.env' orchestration/lib/agent-env.sh \
   && grep -q 'CHANGE_ME' orchestration/lib/agent-env.sh; then
  ok "agent-env.sh source'ит agent.env и содержит placeholder-guard (CHANGE_ME)"
else
  bad "agent-env.sh не пробрасывает agent.env / нет guard'а CHANGE_ME — recall не заработает даже с развёрнутым second_brain"
fi

echo "── 8. Страховочный flush в общий мозг (brain-flush.sh) ──"
if bash agent-template/scripts/brain-flush.test.sh >/dev/null 2>&1; then
  ok "brain-flush.sh: guard/dedup/fail-open — юнит-тест зелёный"
else
  bad "brain-flush.sh: юнит-тест провален (agent-template/scripts/brain-flush.test.sh)"
fi
# Обращения к second_brain идут через рукопожатие MCP: одиночный tools/call
# FastMCP отвергает, и записи в общий мозг молча не доходили (2026-09-01).
if bash agent-template/scripts/mcp-call.test.sh >/dev/null 2>&1; then
  ok "mcp-call.sh: рукопожатие MCP (initialize + session-id) — юнит-тест зелёный"
else
  bad "mcp-call.sh: юнит-тест провален (agent-template/scripts/mcp-call.test.sh)"
fi
for hook_script in brain-flush.sh reflect-nudge.sh; do
  if grep -q 'mcp_tools_call' "agent-template/scripts/$hook_script"; then
    ok "$hook_script ходит в second_brain через рукопожатие"
  else
    bad "$hook_script шлёт одиночный POST — запись в общий мозг не дойдёт"
  fi
done

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

echo "── 9b2. Перепечатка застрявшего ввода: полный текст, а не обрезок ──"
# Регрессия 2026-09-01: из панели читается только первая визуальная строка,
# и длинное сообщение оператора доходило до агента обрезанным на полуслове.
if bash orchestration/lib/pane-recover.test.sh >/dev/null 2>&1; then
  ok "pane-recover.sh: перепечатывается полный текст из метки доставки"
else
  bad "pane-recover.sh: юнит-тест провален (orchestration/lib/pane-recover.test.sh)"
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
# первым стартовавшим агентом) — НЕ из env процесса start-agent. Отсюда класс
# тихих отказов: у нового агента чужой bot_id ("bot_id mismatch -> poller
# exited") и мёртвый webhook-порт, без единой ошибки в логах. Гейт статический.
NA="skills/create-agent/new-agent.sh"

ch_vars="$(awk '/cat > "\$CH_ENV" <<ENV/,/^ENV$/' "$NA" | grep -oE '^[A-Z_]+=' | tr -d '=' | sort -u)"
unset_vars="$(sed -n '/^unset /,/^$/p' "$NA" | grep -oE '\b[A-Z][A-Z_]+\b' | grep -v '^unset$' | sort -u)"

# Пустая выборка = гейт проходит вхолостую и ничего не охраняет. Валим явно.
if [ -z "$ch_vars" ] || [ -z "$unset_vars" ]; then
  bad "env-isolation: не удалось извлечь списки переменных (изменилась структура $NA?) — гейт не работает"
else
  # A. Раньше здесь сверялся список tmux -e: переменную добавили в channel.env,
  # забыли в -e — и значение молча протекало от соседа по общему tmux-серверу.
  # Списка больше нет (секция 17): channel.env сорсится целиком под `set -a`
  # уже внутри панели, поэтому полнота обеспечена структурно, а не сверкой.
  # Проверяем именно `set -a` — без него экспорта не будет вовсе.
  if grep -qE 'set -a; \. "\$ch_env"; set \+a' orchestration/lib/agent-env.sh; then
    ok "channel.env целиком экспортируется в сессию (set -a, без списка -e)"
  else
    bad "agent-env.sh сорсит channel.env без set -a — переменные не доедут до сессии"
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
  ok "task-poller.sh: обёртка видима надзору, без headless claude — юнит-тест зелёный"
else
  bad "task-poller.sh: юнит-тест провален (agent-template/scripts/task-poller.test.sh)"
fi
# Логика опроса живёт в python-демоне: адресный фильтр, idle-гейт, идемпотентность,
# кэш токена, одна живая MCP-сессия.
if python3 agent-template/scripts/task_poller.test.py >/dev/null 2>&1; then
  ok "task_poller.py: фильтр / idle-гейт / идемпотентность / MCP-сессия — юнит-тест зелёный"
else
  bad "task_poller.py: юнит-тест провален (agent-template/scripts/task_poller.test.py)"
fi
# Регрессия: доска задач должна попасть новому агенту. Забыли сервер в шаблоне
# или URL в install/new-agent -- у агента не будет инструментов task_*, и он
# молча вернётся к заметкам, ёмкость которых конечна (см. AGENT_ROUTER.md).
if grep -q 'second_brain-tasks' agent-template/templates/mcp.json.template \
     && grep -q 'SECOND_BRAIN_TASKS_URL' agent-template/install.sh \
     && grep -q 'SECOND_BRAIN_TASKS_URL' skills/create-agent/new-agent.sh \
     && grep -q 'SECOND_BRAIN_TASKS_URL' orchestration/lib/agent-env.sh; then
  ok "доска задач подключается новому агенту (шаблон + install + new-agent + start-agent)"
else
  bad "доска задач не доедет до нового агента — проверь SECOND_BRAIN_TASKS_URL"
fi
# Регрессия: task_done разрешён только из review. Инструкция, ведущая из
# progress прямо в done, вешает задачу на invalid transition.
if grep -q 'task_review' agent-template/scripts/task_poller.py; then
  ok "инструкция закрытия задачи ведёт через review (машина состояний доски)"
else
  bad "поллер велит закрывать задачу мимо review — упрётся в invalid transition"
fi
# Регрессия: забыть демона в списке копирования = у нового агента поллер молча
# не стартует, а обёртка при этом выглядит установленной.
if grep -q 'task_poller\.py' agent-template/install.sh; then
  ok "install.sh копирует task_poller.py в воркспейс агента"
else
  bad "install.sh не копирует task_poller.py — у нового агента поллер не запустится"
fi
# Юнит-тест единого запуска/надзора (ensure_task_poller): noscript/running/launched
# + точный подсчёт по /proc без self-match.
if bash orchestration/lib/task-poller-launch.test.sh >/dev/null 2>&1; then
  ok "task-poller-launch.sh: ensure_task_poller / _poller_count — юнит-тест зелёный"
else
  bad "task-poller-launch.sh: юнит-тест провален (orchestration/lib/task-poller-launch.test.sh)"
fi
# Регрессия: start-agent.sh обязан запускать поллер, иначе доставка задач мертва.
if grep -q 'ensure_task_poller' orchestration/start-agent.sh; then
  ok "start-agent.sh запускает task-poller (ensure_task_poller)"
else
  bad "start-agent.sh не запускает task-poller — задачи не будут доставляться в сессию"
fi
# Регрессия: watchdog обязан НАДЗИРАТЬ за поллером (поднимать при живой сессии),
# иначе тихо умерший поллер лежит мёртвым до полного рестарта сессии.
if grep -q 'lib/task-poller-launch.sh' orchestration/watchdog.sh \
     && grep -q 'ensure_task_poller "\$AGENT" "\$AGENT_WS"' orchestration/watchdog.sh; then
  ok "watchdog.sh надзирает за task-poller (ensure_task_poller при живой сессии)"
else
  bad "watchdog.sh не надзирает за поллером — тихо умерший поллер не поднимется до рестарта"
fi
# Регрессия: транзиентный сбой не должен ронять поллер молча. Обёртка обязана
# жить без set -e (иначе ненулевой выход демона убьёт её же) и поднимать демона
# заново; демон обязан терпеть флап сессии tmux (GONE_LIMIT), а не выходить с
# первого промаха — при рестарте юнита сессия исчезает на секунду.
if ! grep -qE '^set -[a-z]*e' agent-template/scripts/task-poller.sh \
     && grep -q 'RESTART_DELAY' agent-template/scripts/task-poller.sh \
     && grep -q 'GONE_LIMIT' agent-template/scripts/task_poller.py; then
  ok "поллер захарден (обёртка переживает падение демона + допуск флапа сессии)"
else
  bad "поллер не захарден — транзиентный сбой уронит его без подъёма"
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

echo "── 12. Демоны под set -e не убивают себя захватом кода возврата ──"
# Регрессия 2026-08-09: в watchdog.sh стояло `recover_stuck_input "$SESSION"; rc=$?`.
# Под `set -e` такая конструкция завершает скрипт на ЛЮБОМ ненулевом коде — а
# функция штатно возвращает 1 и 2. Watchdog умирал ровно на этой строке, systemd
# поднимал его заново, лестница эскалации обнулялась, и оператор часами получал
# «пробую дослать (Enter)» вместо восстановления. Правильная форма — `|| rc=$?`.
RC_HITS=""
while IFS= read -r f; do
  grep -q 'set -euo\? pipefail\|set -e' "$f" 2>/dev/null || continue
  # grep -n по ОДНОМУ файлу печатает "NNN:строка" (без имени), поэтому отбрасываем
  # строки-комментарии по шаблону ^NNN:<пробелы>#, а не :NNN:<пробелы>#.
  hits="$(grep -nE ';[[:space:]]*[A-Za-z_]+=\$\?' "$f" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
  [ -n "$hits" ] && RC_HITS="$RC_HITS
$f:
$hits"
done < <(find orchestration agent-template skills -name '*.sh' -not -name '*.test.sh' 2>/dev/null)
if [ -n "${RC_HITS// /}" ]; then
  bad "захват \$? через \`cmd; rc=\$?\` в скрипте с set -e — демон умрёт на первом ненулевом коде:"
  echo "$RC_HITS" | sed 's/^/    /'
else
  ok "нигде нет \`cmd; rc=\$?\` под set -e (только безопасное \`|| rc=\$?\`)"
fi
# Регрессия: троттл алертов обязан переживать рестарт демона (файловые метки),
# иначе флапающий супервизор спамит оператора одним и тем же сообщением.
if grep -q 'NOTIFY_STATE_DIR' orchestration/lib/notify.sh; then
  ok "notify.sh: троттл персистентный (переживает рестарт демона)"
else
  bad "notify.sh: троттл только в памяти процесса — рестарт демона обнулит cooldown и оператор получит спам"
fi
# Регрессия: мёртвая авторизация (сессия жива, ходы падают) обязана детектиться —
# для остальных веток она неотличима от здорового простоя.
if grep -q 'has_auth_error' orchestration/lib/pane.sh \
     && grep -q 'has_auth_error "\$TAIL"' orchestration/watchdog.sh; then
  ok "watchdog.sh ловит мёртвую авторизацию (сессия жива, но ходы не выполняются)"
else
  bad "watchdog.sh не ловит ошибку авторизации — агент будет молчать сутками, выглядя здоровым"
fi
# Регрессия: «залипло ли» нельзя решать по отрисовке — сорванный auto-submit
# рисует текст, не кладя его в буфер. Единственный различитель — курсор.
if grep -q 'buffer_is_empty' orchestration/lib/pane.sh \
     && grep -q 'buffer_is_empty' orchestration/lib/pane-recover.sh \
     && grep -q 'buffer_is_empty' orchestration/watchdog.sh; then
  ok "восстановление ввода различает призрак отрисовки и реальный буфер (по курсору)"
else
  bad "восстановление судит о буфере по capture-pane — на призраке сдастся с «box won't clear»"
fi

# Регрессия: призрак в поле НЕ должен прятать ветку простоя. Пока учёт простоя
# жил только в ветке чистого промпта, нарисованная подсказка навсегда уводила
# управление в обработчик залипшего ввода, и консолидация памяти не запускалась
# ни разу (carmella: 67 неисполненных заявок с 19.07, watermark пустой).
if grep -q '^note_idle_cycle()' orchestration/watchdog.sh \
     && [ "$(grep -c '^[[:space:]]*note_idle_cycle$' orchestration/watchdog.sh)" -ge 2 ]; then
  ok "простой считается и на чистом промпте, и на призраке с пустым буфером"
else
  bad "учёт простоя есть только в одной ветке — призрак снова заблокирует консолидацию"
fi

# Подтверждённое доставкой сообщение при пустом буфере обязано чиниться в ТОМ ЖЕ
# проходе. Если ветка снова начнёт ставить NUDGE_STAGE=1, восстановление уедет
# на следующий ~30с цикл, и потерянное сообщение оператора будет ждать впустую.
if grep -q '^attempt_stuck_input_recovery()' orchestration/watchdog.sh \
     && [ "$(grep -c '^[[:space:]]*attempt_stuck_input_recovery\( ;;\)\?$' orchestration/watchdog.sh)" -ge 2 ]; then
  ok "залипший ввод чинится одной функцией со ступени 1 и сразу с пустого буфера"
else
  bad "восстановление ввода снова разъехалось по ступеням — подтверждённое сообщение будет ждать лишний цикл"
fi

echo "── 12b. Новый агент получает всё, что ему уже велено делать ──"
# Дыра, найденная 02.09.2026: доска задач стала основным каналом межагентной
# работы, а scope на неё не выдавался при создании агента ни в одном пути
# установки — доливали вручную. То же с error-patterns: CLAUDE.md.template прямо
# велит агенту писать «decisions/error-patterns to memory», а права не было.
if grep -q 'AGENT_SCOPES:=.*task-board' skills/create-agent/new-agent.sh \
     && grep -q 'AGENT_SCOPES:=.*error-patterns' skills/create-agent/new-agent.sh; then
  ok "новому агенту выдаются scope task-board и error-patterns"
else
  bad "в AGENT_SCOPES нет task-board/error-patterns — агент не сможет работать с доской и писать разбор ошибок"
fi

# Поллер в тексте доставки ссылается на AGENT_ROUTER.md, правила записи —
# красная зона. Оба документа жили только в репозитории и до агента не доезжали.
if grep -q 'AGENT_ROUTER.md' agent-template/install.sh \
     && grep -q 'SECONDBRAIN_WRITE_RULES.md' agent-template/install.sh \
     && grep -q '^@AGENT_ROUTER.md' agent-template/templates/CLAUDE.md.template \
     && grep -q '^@SECONDBRAIN_WRITE_RULES.md' agent-template/templates/CLAUDE.md.template; then
  ok "управляющие документы копируются в воркспейс и подключены к CLAUDE.md"
else
  bad "AGENT_ROUTER.md / SECONDBRAIN_WRITE_RULES.md не доезжают до агента — поллер ссылается на несуществующий файл"
fi

# FastMCP отвечает 400 "Missing session ID" на одиночный POST, а tools/list
# отдаётся вообще без проверки токена. Обе smoke-пробы обязаны идти через
# рукопожатие (mcp-call.sh) и быть настоящими вызовами инструментов.
if grep -q 'mcp-call.sh' skills/create-agent/new-agent.sh \
     && ! grep -qE "curl [^|]*-X POST \"\$SECOND_BRAIN_(MEMORY_ROUTER|TASKS)_URL\"" skills/create-agent/new-agent.sh; then
  ok "smoke ходит в мозг через рукопожатие MCP, а не голым POST"
else
  bad "smoke бьёт в MCP голым POST — получит 400 и объявит здоровую установку сломанной"
fi

echo "── 13. Оператору сообщают только то, по чему он может действовать ──"
# Обратная связь оператора 2026-08-09: «всё, что мне нужно знать — просрочена ли
# подписка и недоступен ли агент; технические детали и копания в сессии
# неактуальны». Рестарт сессии, подобранные процессы и ступени досылки — работа
# автоматики: их место в логе, а не в Telegram.
if awk '/^restart_session\(\)/,/^}/' orchestration/watchdog.sh | grep -q 'notify_op'; then
  bad "watchdog.sh шлёт алерт на каждый рестарт сессии — оператор получит поток отчётов, по которым нечего делать"
else
  ok "штатный рестарт сессии оператора не беспокоит (только лог)"
fi
if grep -q 'report_down' orchestration/watchdog.sh && grep -q 'report_up' orchestration/watchdog.sh; then
  ok "тревога о недоступности парная: поднимается и закрывается"
else
  bad "watchdog.sh не умеет закрывать тревогу — оператор останется с висящим «агент недоступен»"
fi
# Флаг тревоги обязан быть файловым: в памяти он не переживёт рестарт демона,
# и «снова на связи» не придёт никогда.
if grep -q 'DOWN_FLAG=' orchestration/watchdog.sh; then
  ok "флаг тревоги переживает рестарт демона (файл, не переменная)"
else
  bad "флаг тревоги живёт в памяти процесса — после рестарта watchdog тревога не закроется"
fi
if bash orchestration/doctor.test.sh >/dev/null 2>&1; then
  ok "doctor.sh: диагноз и починка на подменённом окружении — юнит-тест зелёный"
else
  bad "doctor.sh: юнит-тест провален (bash orchestration/doctor.test.sh)"
fi
if bash orchestration/lib/doctor-request.test.sh >/dev/null 2>&1; then
  ok "очередь /doctor: запрос исполняется один раз, команда не зацикливается — юнит-тест зелёный"
else
  bad "очередь /doctor: юнит-тест провален (bash orchestration/lib/doctor-request.test.sh)"
fi
# Отвечать на /doctor обязан watchdog, а не плагин: доктор вправе перезапустить
# сессию, и плагин (он живёт ВНУТРИ неё) умрёт, не успев отправить вердикт.
if grep -q 'serve_doctor_request' orchestration/watchdog.sh; then
  ok "на /doctor отвечает watchdog — вердикт переживёт перезапуск сессии"
else
  bad "watchdog не обслуживает /doctor — ответ пропадёт, если доктор перезапустит сессию"
fi
# Путь заявки описан дважды — в bash и в TypeScript плагина. Расхождение сделало
# бы /doctor тихо неработающим: заявка легла бы туда, куда никто не смотрит.
OOB_TS="../tg-plugin/plugin/src/commands/oob.ts"
if [ -f "$OOB_TS" ]; then
  if grep -q 'shared/state/\${id.toLowerCase()}/doctor.request' "$OOB_TS" \
       && grep -q 'shared/state/' orchestration/lib/doctor-request.sh \
       && grep -q "doctor.request" orchestration/lib/doctor-request.sh; then
    ok "путь заявки /doctor одинаков в watchdog и в плагине"
  else
    bad "путь заявки /doctor разошёлся между bash и плагином — команда молча перестанет работать"
  fi
fi

echo "── 14. Жизненный цикл юнита и установка агента ──"
# Все проверки ниже -- регрессии, найденные живым прогоном create-agent 03.09.2026.

# 14a. Юнит обязан снимать СВОЕГО агента сам. Сессия claude лежит в общем
# tmux-сервере, попадающем в cgroup первого стартовавшего агента, поэтому без
# ExecStop рестарт не-владельца не пересоздавал сессию, а стоп владельца ронял
# сессии всего роя.
UNIT_TMPL="systemd/claude-agent.service.template"
if grep -q '^ExecStop=.*stop-agent\.sh' "$UNIT_TMPL" && grep -q '^KillMode=process' "$UNIT_TMPL"; then
  ok "юнит снимает своего агента через ExecStop и не бьёт по чужой cgroup"
else
  bad "в юните нет ExecStop=stop-agent.sh или KillMode=process — рестарт не перезапустит сессию"
fi

# 14b. Остановка адресная: kill-session, а не kill-server (сервер общий на рой).
if [ -x orchestration/stop-agent.sh ]; then
  # Комментарии отбрасываем: в них kill-server упомянут как раз с объяснением,
  # почему он здесь запрещён.
  STOP_CODE="$(grep -v '^[[:space:]]*#' orchestration/stop-agent.sh)"
  if printf '%s' "$STOP_CODE" | grep -q 'kill-session' \
     && ! printf '%s' "$STOP_CODE" | grep -q 'kill-server'; then
    ok "stop-agent снимает только свою сессию, общий tmux-сервер не трогает"
  else
    bad "stop-agent трогает tmux-сервер целиком — уронит сессии всех агентов"
  fi
  if grep -q 'task-poller' orchestration/stop-agent.sh && grep -q 'plugin/src/server.ts' orchestration/stop-agent.sh; then
    ok "stop-agent прибирает поллер и осиротевший канал"
  else
    bad "stop-agent не убирает поллер или bun-канал — останутся сироты с занятым портом"
  fi
  # Поведение: на несуществующем агенте отрабатывает чисто и не падает.
  if out="$(bash orchestration/stop-agent.sh __nonexistent__ 2>&1)" \
     && printf '%s' "$out" | grep -q 'сессии labops-__nonexistent__ не было'; then
    ok "stop-agent идемпотентен: несуществующий агент не ошибка"
  else
    bad "stop-agent падает на несуществующем агенте"
  fi
else
  bad "нет исполняемого orchestration/stop-agent.sh — у юнита не будет ExecStop"
fi

# 14c. Один и тот же CLAUDE_LAB в обоих скриптах. Расхождение уводило скаффолд
# в ЖИВУЮ лабораторию при заданной CLAUDE_LAB.
if grep -q 'LAB_DIR="\${CLAUDE_LAB:-\${HOME}/.claude-lab}"' agent-template/install.sh; then
  ok "install.sh учитывает CLAUDE_LAB так же, как new-agent.sh"
else
  bad "install.sh прошивает ~/.claude-lab — скаффолд уедет мимо заданной CLAUDE_LAB"
fi

NA="skills/create-agent/new-agent.sh"
# 14d. Токен выдаётся от имени владельца .env (0600 second_brain:second_brain),
# иначе канонический самобутстрап падает с PermissionError.
if grep -q 'sudo -n -u second_brain' "$NA"; then
  ok "выдача токена идёт через sudo -u second_brain, как в docs/setup.md"
else
  bad "new-agent.sh зовёт issue-agent-token напрямую — PermissionError на .env"
fi

# 14e. Причина отказа выдачи должна доходить до оператора.
if grep -q 'issue-agent-token.py' "$NA" && ! grep -qE 'issue-agent-token\.py.*2>/dev/null' "$NA"; then
  ok "ошибка выдачи токена не глушится"
else
  bad "ошибка выдачи токена уходит в /dev/null — оператор не увидит причину"
fi

# 14f. Должен существовать неинтерактивный способ отдать готовый токен:
# AGENT_BEARER стирается общим unset (он прилетает чужим из родительской сессии).
if grep -q 'NEW_AGENT_BEARER' "$NA"; then
  ok "готовый токен передаётся через NEW_AGENT_BEARER"
else
  bad "нет способа отдать токен заранее — AGENT_BEARER стирается unset-ом"
fi

# 14g. read под set -e не должен убивать установку посередине.
if grep -q 'read -r __i || __i=""' "$NA" && grep -q 'NONINTERACTIVE' "$NA"; then
  ok "ask переживает закрытый stdin и умеет неинтерактивный режим"
else
  bad "ask падает на EOF — установка оборвётся между воркспейсом и юнитом"
fi

# 14h. Smoke обязан проверять РАБОТАЮЩЕГО агента, а не токен из памяти.
if grep -q 'сессия стартовала РАНЬШЕ последней правки' "$NA" \
   && grep -q 'Перечитывание конфига живой сессией' "$NA"; then
  ok "smoke ловит сессию со старым конфигом, установка её пересоздаёт"
else
  bad "smoke зелёный поверх сессии со старым .mcp.json"
fi

echo "── 15. Сессия подбирает самообновившийся Claude Code ──"

# 15a. Поведенческий тест библиотеки: реальные процессы, реальный /proc.
if bash orchestration/lib/cli-version.test.sh >/dev/null 2>&1; then
  ok "cli-version: дрейф версии и fail-open — юнит-тест зелёный"
else
  bad "cli-version: юнит-тест провален (orchestration/lib/cli-version.test.sh)"
fi

# 15b. Регрессия 08.09.2026: перезапуск ради версии допустим ТОЛЬКО из ветки
# чистого простоя. Внутри хода он стоил бы агенту потерянной работы.
if awk '/clean idle prompt/,/^  fi$/' orchestration/watchdog.sh | grep -q 'cli_version_drifted'; then
  ok "перезапуск под обновление живёт в ветке простоя"
else
  bad "проверка версии вне ветки простоя — рестарт может оборвать ход агента"
fi

# 15c. Обновление не должно срабатывать на первом же цикле простоя: между двумя
# сообщениями оператора агент тоже выглядит простаивающим.
if grep -q 'IDLE_COUNT" -ge "\$CLI_UPDATE_IDLE_CYCLES' orchestration/watchdog.sh; then
  ok "перед перезапуском выдерживается пауза простоя"
else
  bad "рестарт под обновление без выдержки простоя"
fi

# 15d. readlink -f канонизирует и несуществующий путь — без -e пропавший бинарь
# читался бы как дрейф и уводил агента в перезапуск на пустом месте.
if grep -q '\[ -n "\$bin" \] && \[ -e "\$bin" \]' orchestration/lib/cli-version.sh; then
  ok "отсутствующий бинарь не принимается за дрейф"
else
  bad "cli-version не проверяет существование бинаря перед readlink"
fi

# 15e. Регрессия 09.09.2026: обновившийся CLI встретил перезапущенные сессии
# мастером первого запуска, и обе простояли на выборе темы двое суток. Метку
# онбординга надо проставлять ДО подъёма сессии, иначе перезапуск под
# обновление (15b) сам же агента и обездвиживает.
mark_grep="$(grep -n 'cli_version_mark_onboarding_done' orchestration/start-agent.sh | tail -1)"
mark_line="${mark_grep%%:*}"
tmux_line="$(grep -n 'tmux new-session' orchestration/start-agent.sh | head -1 | cut -d: -f1)"
if [ -n "$mark_line" ] && [ -n "$tmux_line" ] && [ "$mark_line" -lt "$tmux_line" ]; then
  ok "метка онбординга ставится до подъёма сессии"
else
  bad "start-agent не помечает онбординг пройденным — мастер остановит сессию"
fi

echo "── 16. Модель задаётся алиасом, а не прибитой версией ──"

# 16a. Регрессия 08.09.2026: в подсказках оператору стояло «opus = Opus 4.8», и
# это молча устарело — алиас opus давно резолвится в следующее поколение. Номер
# версии в тексте устаревает всегда, алиас — никогда. Комментарии из проверки
# исключаем: объяснение, ПОЧЕМУ версий тут быть не должно, само содержит пример.
MODEL_FILES="skills/create-agent/new-agent.sh agent-template/install.sh"
MODEL_FILES="$MODEL_FILES $(ls agent-template/templates/*.template 2>/dev/null)"
pinned=""
for f in $MODEL_FILES; do
  [ -f "$f" ] || continue
  if grep -vE '^[[:space:]]*#' "$f" | grep -qE '(Opus|Sonnet|Haiku|Fable)[[:space:]]+[0-9]'; then
    pinned="$pinned $f"
  fi
done
if [ -z "$pinned" ]; then
  ok "в подсказках и шаблонах нет прибитых номеров версий модели"
else
  bad "прибитая версия модели устареет молча:$pinned"
fi

# 16b. Оператору должен предлагаться алиас последней модели и возможность
# закрепить версию полным именем — иначе выбор между ними негде сделать.
if grep -qE 'ask PRIMARY_MODEL.*алиас последней' skills/create-agent/new-agent.sh \
   && grep -qE 'ask PRIMARY_MODEL.*полное имя' skills/create-agent/new-agent.sh; then
  ok "подсказка объясняет и алиас, и закрепление версии"
else
  bad "подсказка модели не объясняет разницу алиаса и полного имени"
fi

# 16c. PRIMARY_MODEL по-прежнему доезжает до settings.json — без этого агент
# молча уедет на дефолт CLI мимо выбора оператора.
if grep -q '"model": "{{PRIMARY_MODEL}}"' agent-template/templates/settings.json.template; then
  ok "выбранная модель попадает в settings.json агента"
else
  bad "settings.json.template не подставляет PRIMARY_MODEL"
fi

echo "── 17. Секреты не попадают в командную строку ──"

# 17a. Поведенческий тест: реальный запуск session-exec.sh с подставным claude,
# который печатает свою cmdline и своё окружение.
if bash orchestration/lib/agent-env.test.sh >/dev/null 2>&1; then
  ok "agent-env: секреты в окружении, но не в argv — юнит-тест зелёный"
else
  bad "agent-env: юнит-тест провален (orchestration/lib/agent-env.test.sh)"
fi

# 17b. Регрессия 08.09.2026: секреты уезжали в сессию флагами tmux -e VAR=value,
# то есть лежали в командной строке и были видны в обычном ps любому
# пользователю машины — и не мельком, а до перезапуска всего роя, потому что
# tmux-сервер живёт с cmdline поднявшей его команды.
if grep -n 'tmux new-session' orchestration/start-agent.sh | grep -q . \
   && ! grep -qE '^\s*-e (TELEGRAM|AGENT_BEARER|GROQ|MCP_|SECOND_BRAIN)' orchestration/start-agent.sh; then
  ok "сессия поднимается без передачи секретов флагами"
else
  bad "секреты снова уходят в командную строку tmux (-e VAR=value)"
fi

# 17c. Мало убрать -e: сам start-agent.sh не должен затягивать секреты в СВОЁ
# окружение, иначе они снова окажутся в cmdline всего, что он запускает дальше.
# Отсюда вызов резолва в подоболочке — только ради кода возврата.
if grep -q 'if ! ( resolve_agent_env "\$AGENT" >/dev/null ); then' orchestration/start-agent.sh; then
  ok "start-agent проверяет окружение, не втягивая его в себя"
else
  bad "start-agent резолвит секреты в собственное окружение"
fi

# 17d. Панель обязана СТАТЬ claude: без exec pane_pid укажет на обёртку, и мимо
# промахнутся детектор дрейфа версии и снятие агента.
if grep -qE '^exec "\$CLAUDE_BIN"' orchestration/session-exec.sh; then
  ok "обёртка панели делает exec в claude"
else
  bad "session-exec.sh не делает exec — pane_pid укажет на bash"
fi

echo "── 18. Предполётная проверка доступности хостов ──"

# 18a. Классификация ответа хоста (403 ≠ нет связи) — на подставном curl.
if bash orchestration/lib/preflight.test.sh >/dev/null 2>&1; then
  ok "preflight: разбор кодов ответа — юнит-тест зелёный"
else
  bad "preflight: юнит-тест провален (orchestration/lib/preflight.test.sh)"
fi

# 18b. Поведение самого install.sh: реальный запуск с закрытым хостом должен
# останавливать установку на шаге 0, до пакетов и создания пользователя.
if bash install-preflight.test.sh >/dev/null 2>&1; then
  ok "install.sh останавливается на закрытом хосте — юнит-тест зелёный"
else
  bad "preflight в install.sh: юнит-тест провален (install-preflight.test.sh)"
fi

# 18c. Регрессия 08.09.2026: `curl -fsSL … | bash` под set -e + pipefail обрывал
# установку молча — curl отдавал 22, конвейер падал, и die с объяснением уже не
# выполнялся. Оператор видел только «curl: (22)» и внезапный конец.
# Комментарии исключаем: объяснение, ПОЧЕМУ конвейера тут быть не должно, само
# содержит его пример — ровно та же ловушка, что в проверках 14b и 16a.
if grep -vE '^[[:space:]]*#' install.sh | grep -qE 'curl [^|]*\| *bash'; then
  bad "установка Claude Code снова идёт конвейером — ошибка проглотится молча"
else
  ok "claude ставится без конвейера curl|bash — код ошибки не теряется"
fi

# 18d. claude.ai — только редирект; дистрибутив лежит на downloads.claude.ai за
# другой инфраструктурой. Обход должен остаться, иначе 403 на фронте снова
# заблокирует установку целиком.
if grep -q 'downloads.claude.ai/claude-code-releases/bootstrap.sh' install.sh; then
  ok "при недоступном claude.ai есть прямой обход на downloads.claude.ai"
else
  bad "нет обхода мимо claude.ai — 403 на фронте снова остановит установку"
fi

echo "── 19. Контекст агента без нашего бренда ──"

# 19a. Регрессия 08.09.2026: описания скиллов грузятся в системный промпт агента
# при каждой сессии, и в них стояло «an labops agent». У клиента на свежей
# установке агент называл себя нашим продуктом. Технические идентификаторы
# (labops-channel, имена репозиториев в путях) под запрет НЕ попадают — их
# переименование ломает канал и ссылки.
brand=""
for f in skills/*/SKILL.md; do
  [ -f "$f" ] || continue
  # Именно frontmatter между «---»: description бывает многострочным, а тело
  # файла проверять нельзя — там законные пути к репозиториям.
  if awk 'NR==1 && /^---/ {f=1; next} f && /^---/ {exit} f' "$f" \
     | grep -i 'labops' | grep -qv 'labops-channel'; then
    brand="$brand $f"
  fi
done
if [ -z "$brand" ]; then
  ok "в описаниях скиллов нет упоминаний продукта"
else
  bad "бренд просочился в системный промпт агента через описание скилла:$brand"
fi

echo
if [ "$fail" -eq 0 ]; then
  printf "${G}✅ self-test пройден (%d проверок).${N}\n" "$pass"; exit 0
else
  printf "${R}❌ self-test провален: %d ошибок.${N}\n" "$fail"; exit 1
fi
