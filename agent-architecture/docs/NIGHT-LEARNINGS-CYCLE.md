# Night Learnings Cycle — Ночной цикл обновления rules.md

**Цель:** Автоматизировать процесс превращения learnings → rules.md без участия оператора.

**Проблема, которое решает:**
- Learnings накапливаются в second_brain, но rules.md не обновляется
- Агент наступает на одни и те же грабли несколько раз
- Оператору нужно вручную говорить: "напиши это в rules"

**Решение:**
```
02:00 → cron-скрипт → agent_router.notify → агент просыпается → recall learnings → анализирует → пишет в rules.md
```

---

## 🌙 Архитектура

### 1. Scheduler (Cron)

**Команда:**
```bash
0 2 * * * /home/agent/.claude-lab/night-learnings.sh
```

**Что делает:**
- Запускается каждый день в 02:00
- Вызывает `night-learnings.sh`
- Логирует результаты в `/home/agent/.claude-lab/logs/night-cycle/`

**Файл:** `/etc/cron.d/` или `crontab -l`

**Проверка:**
```bash
crontab -l | grep night-learnings
```

---

### 2. Trigger Script (night-learnings.sh)

**Путь:** `/home/agent/.claude-lab/night-learnings.sh`

**Что делает:**
1. Для каждого агента (developer, researcher, assistant):
2. Читает bearer token из `.mcp.json`
3. Отправляет `agent_router.notify` на `localhost:5000` (second_brain-agent_router)
4. Payload содержит:
   - `to_agent`: агент, который должен проснуться
   - `title`: "Night Learnings Review"
   - `body`: инструкция что делать
   - `task_type`: "rules_update"

**Логирование:**
```
/home/agent/.claude-lab/logs/night-cycle/learnings-YYYYMMDD-HHMMSS.log
/home/agent/.claude-lab/logs/cron.log
```

**Пример вывода:**
```
=== Night Learnings Cycle Started at 2026-05-30 02:00:00 ===

[developer] Triggering learnings review...
  → Sending notification to developer...
  ✓ Notification queued for developer

[researcher] Triggering learnings review...
  → Sending notification to researcher...
  ✓ Notification queued for researcher

[assistant] Triggering learnings review...
  → Sending notification to assistant...
  ✓ Notification queued for assistant

=== Night Learnings Cycle Completed ===
```

---

### 3. Agent Workflow (second_brain-agent_router.notify trigger)

Когда агент получает уведомление о night learnings:

#### Шаг 1: Получение задачи (PostSessionStart)

Агент просыпается и видит задачу в свом inbox (через second_brain-agent_router MCP).

**Инструкция в CLAUDE.md:**
```
Когда срабатывает: 02:00 ежедневно (cron: `0 2 * * *`)
Workflow:
1. Получи задачу от night-learnings.sh
2. Прочитай learnings за последние 7 дней
3. Для каждого learnings оцени: нужно ли в rules.md?
4. Обнови rules.md
5. Отправь отчёт оператору
```

#### Шаг 2: Recall learnings (7 дней назад)

```python
# Агент делает recall из second_brain
second_brain-memory_router.recall(
  query="mistakes errors patterns failures " + agent_name,
  limit=20,
  days=7
)
```

**Что ищет:**
- developer: "git bugs deploy errors architecture mistakes"
- researcher: "classification wiki organization save errors compile"
- assistant: "posts engagement metrics tone TOV audience failures"

#### Шаг 3: Анализ и фильтрация

Агент читает каждый learnings и оценивает:
- **Критичность:** это critical rule или случайная ошибка?
- **Универсальность:** это правило применимо всегда или в специфических случаях?
- **Новизна:** это уже в rules.md или новая?

#### Шаг 4: Обновление rules.md

Если правило новое и критичное:

```bash
cat >> ~/.claude/core/rules.md << EOF

**[Night Cycle - $(date '+%Y-%m-%d')]**
HARD RULE: <правило в одной строке>
EOF
```

#### Шаг 5: Отчёт оператору

```
Проверил 15 learnings за 7 дней.
Добавлено правил: 3

- HARD RULE: никогда не пускай git push --force
- HARD RULE: всегда проверяй dependencies перед коммитом
- HARD RULE: backup перед рискованной операцией на продакшене
```

---

## 🔄 Полный цикл: Таймлайн

```
23:59:59 — агенты спят, слушают только Telegram
02:00:00 — cron срабатывает
02:00:01 — night-learnings.sh запускается
02:00:02 — agent_router.notify отправляется каждому агенту
02:00:05 — developer просыпается, получает задачу
02:00:10 — developer делает recall из second_brain (memory_router)
02:00:30 — developer анализирует learnings
02:01:00 — developer пишет в rules.md
02:01:30 — developer отправляет отчёт в Telegram
02:02:00 — researcher просыпается и начинает процесс
02:05:00 — assistant завершает свой цикл
02:05:30 — все отчёты отправлены оператору
02:06:00 — цикл завершен, agents ждут утра
```

---

## 📊 Статистика и мониторинг

### Какие метрики отслеживаем

| Метрика | Что показывает | Где |
|---|---|---|
| **Rules added per night** | Сколько новых правил добавилось | Telegram отчёт |
| **Learnings reviewed** | Сколько learnings обработано | Логи агентов |
| **Duplicate avoidance** | Сколько правил было дублей (пропущены) | Логи скрипта |
| **Cycle success rate** | % успешных ночных циклов | `/logs/night-cycle/` |

### Примеры отчётов

**Успешный цикл:**
```
✓ Night Learnings Cycle (2026-05-30 02:00)
  - developer: 5 learnings reviewed, +2 rules added
  - researcher: 8 learnings reviewed, +1 rule added
  - assistant: 12 learnings reviewed, +3 rules added
  Total: 25 learnings → +6 rules
```

**Ошибка в цикле:**
```
⚠ Night Learnings Cycle (2026-05-31 02:00)
  - developer: ✓ OK
  - researcher: ✗ MCP unreachable (localhost:5002 down)
  - assistant: ✓ OK
  
Action: Отправлен алерт оператору, researcher пропущен
```

---

## ⚙️ Конфигурация

### Где настраивается

| Компонент | Файл | Параметры |
|---|---|---|
| **Cron расписание** | `/etc/cron.d/` или `crontab -l` | `0 2 * * *` (02:00) |
| **Script путь** | `crontab entry` | `/home/agent/.claude-lab/night-learnings.sh` |
| **Agent инструкции** | каждый CLAUDE.md | "Ночной learnings-цикл" раздел |
| **second_brain URL** | `night-learnings.sh` | `localhost:5000` |
| **Логи** | `night-learnings.sh` | `/home/agent/.claude-lab/logs/night-cycle/` |

### Как изменить время цикла

**Текущее:** 02:00 (2 часа ночи)

Если нужно в 03:00:
```bash
# Отредактируй crontab
crontab -e
# Измени: 0 2 → 0 3
# Сохрани
```

### Как отключить цикл (временно)

```bash
# Убери из crontab
crontab -e
# Закомментируй строку: # 0 2 * * * /home/agent/.claude-lab/night-learnings.sh
```

---

## 🚨 Troubleshooting

### Цикл не запускается

**Проверь:**
1. Cron работает: `sudo systemctl status cron`
2. Crontab установлена: `crontab -l | grep night-learnings`
3. Права на скрипт: `ls -la /home/agent/.claude-lab/night-learnings.sh`

**Лог ошибки:**
```bash
tail -50 /var/log/syslog | grep CRON
# или
tail -50 /home/agent/.claude-lab/logs/cron.log
```

### MCP unreachable

**Ошибка:** `Error: Cannot connect to localhost:5000`

**Проверь:**
```bash
curl -s http://localhost:5000/health
# Если не работает → перезагрузи second_brain
```

### Агент не отправляет отчёт

**Проверь:**
1. Агент живой: `systemctl status claude-agent-developer`
2. Telegram токен работает
3. Логи агента: `journalctl -u claude-agent-developer -f`

---

## 🎯 Результаты и ожидания

### После первого цикла (недели 1)

- ✅ night-learnings.sh запустилась
- ✅ Агенты получили задачу
- ✅ Несколько новых правил добавлены в rules.md
- ✅ Отчёты отправлены в Telegram

### После месяца

- ✅ rules.md каждого агента содержит 10+ правил с dates
- ✅ Агенты реже наступают на одни и те же грабли
- ✅ Цикл работает автоматически каждую ночь
- ✅ Можно отследить тренд: какие ошибки исчезли, какие остались

### Признак успеха

**Агент НИКОГДА не нарушает одно и то же правило дважды** (в течение недели).

Если нарушает → правило недостаточно чёткое, нужно переводить в Hook (уровень 3-4 в иерархии контроля).

---

## 📋 Команды для проверки

```bash
# 1. Проверь cron
crontab -l | grep night-learnings

# 2. Запусти вручную (для теста)
bash /home/agent/.claude-lab/night-learnings.sh

# 3. Посмотри логи цикла
tail -20 /home/agent/.claude-lab/logs/night-cycle/*.log

# 4. Посмотри логи cron
tail -20 /home/agent/.claude-lab/logs/cron.log

# 5. Проверь second_brain доступность
curl -s http://localhost:5000/health

# 6. Проверь rules.md обновился
tail -10 ~/.claude-lab/developer/.claude/core/rules.md
```

---

## 🔄 Вариации и расширения

### Вариант 1: Weekly вместо nightly

Если хочешь, чтобы цикл запускался раз в неделю (экономнее):
```bash
# Вместо 0 2 * * *
# Используй: 0 2 * * 0  (0 = Sunday)
```

### Вариант 2: По-другому распределить learnings

Сейчас все агенты делают одно и то же (review своих learnings).
Можно сделать:
- developer → review всех learnings (cross-agent synthesis)
- researcher → compile in wiki
- assistant → extract patterns for marketing

### Вариант 3: Escalation на Hook

Если правило нарушается даже после добавления в rules.md → автоматически переводить в Hook:

```bash
# В night-learnings.sh добавить:
if [repeated_violation == true]; then
  agent_router.notify(to_agent="developer", 
               payload={
                 "task": "escalate_to_hook",
                 "rule": rule_name,
                 "action": "create_SessionStart_hook"
               })
fi
```

---

## 📞 Support

Если цикл упал:
1. Проверь логи: `/home/agent/.claude-lab/logs/night-cycle/`
2. Запусти вручную и смотри output: `bash /home/agent/.claude-lab/night-learnings.sh`
3. Если нужна отладка → включи debug-логирование (раскомментируй строки в скрипте)

