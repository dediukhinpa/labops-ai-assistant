# Аудит автоматических процессов — модели биллинга

**Дата аудита:** 2026-05-30
**Статус:** Все процессы на подписке, нет платёжных срабатываний

---

## 📊 Процессы и их модели биллинга

| # | Процесс | Тип триггера | Биллинг модель | Статус | Примечание |
|---|---------|---|---|---|---|
| 1 | **systemd: claude-agent-developer** | Telegram webhook (labops-channel) | ✅ **На подписке** | `active` | Живая интерактивная сессия, входящие сообщения от юзера |
| 2 | **systemd: claude-agent-researcher** | Telegram webhook (labops-channel) | ✅ **На подписке** | `active` | Живая интерактивная сессия, входящие сообщения от юзера |
| 3 | **systemd: claude-agent-assistant** | Telegram webhook (labops-channel) | ✅ **На подписке** | `active` | Живая интерактивная сессия, входящие сообщения от юзера |
| 4 | **labops-channel plugin** | Telegram Bot API → hook в settings.json | ✅ **На подписке** | `running` | Перенаправляет сообщения в SessionStart/UserPromptSubmit hooks |
| 5 | **MCP: second_brain-memory** | HTTP запросы от агентов | ✅ **На подписке** | `localhost:5001` | Локальные HTTP звонки, не API платёжи |
| 6 | **MCP: second_brain-memory_router** | HTTP запросы от агентов | ✅ **На подписке** | `localhost:5002` | Локальные HTTP звонки, не API платёжи |
| 7 | **MCP: second_brain-agent_router** | HTTP запросы от агентов | ✅ **На подписке** | `localhost:5000` | Локальные HTTP звонки, не API платёжи |
| 8 | **Cron jobs** | — | ✅ **Отсутствуют** | `—` | Нет периодических задач |
| 9 | **GitHub Actions** | — | ✅ **Отсутствуют** | `—` | Нет workflow'ов (платно с 15.06.2026) |
| 10 | **Agent SDK вызовы** | — | ✅ **Отсутствуют** | `—` | Нет SDK-программных вызовов, только CLI |

---

## 🔵 Детали по каждому процессу

### 1-3. Systemd Services (developer, researcher, assistant)

**Как работает:**
```bash
/usr/local/bin/claude \
  --dangerously-skip-permissions \
  --dangerously-load-development-channels server:labops-channel
```

- Агент запускается в tmux в фоне (systemd Type=oneshot + RemainAfterExit=yes)
- Слушает на labops-channel Telegram webhook
- При получении сообщения в Telegram → срабатывает SessionStart + UserPromptSubmit хук
- Агент обрабатывает → отправляет ответ через Telegram Bot API

**Биллинг:** ✅ На подписке
- Каждое сообщение = новый message в интерактивной сессии (за счёт subscription)
- Не отправляется через Agent API
- Не платёжное срабатывание

**Стоимость:** Входит в месячную подписку Claude Code

---

### 4. labops-channel Plugin

**Как работает:**
- Telegram бот запущен в отдельном процессе (`bun ~/.claude-lab/<agent>/.claude/plugins/labops-channel/...`)
- Получает webhook'и на порт 6000/6001/6002
- Реплицирует сообщение в SessionStart/UserPromptSubmit hook в settings.json

**Хук в settings.json:**
```json
{
  "hooks": {
    "SessionStart": [{
      "type": "command",
      "command": "bun /home/agent/.claude-lab/<agent>/.claude/plugins/labops-channel/plugin/scripts/post-hook.ts"
    }]
  }
}
```

**Биллинг:** ✅ На подписке (хук выполняется внутри сессии)

---

### 5-7. MCP Servers (second_brain-*)

**Как работает:**
- second_brain-memory: HTTP://localhost:5001/mcp (запись решений, ошибок, note'ов)
- second_brain-memory_router: HTTP://localhost:5002/mcp (чтение shared memory)
- second_brain-agent_router: HTTP://localhost:5000/mcp (inter-agent уведомления)

**Биллинг:** ✅ На подписке
- Это локальные HTTP запросы, не API вызовы
- Не считаются как отдельные API звонки
- Входят в контекст текущей сессии агента

**Стоимость:** 0 (локальный сервис)

---

## ⚠️ Потенциальные платёжи (если добавить)

| Сценарий | Биллинг | Статус |
|---|---|---|
| **Agent API / claude -p программно** | Платёжный (за каждый вызов) | ❌ Не используется |
| **GitHub Actions** | Платёжный после 15.06.2026 | ❌ Не используется |
| **Scheduled remote tasks (claude.ai/code)** | Платёжный (за выполнение) | ❌ Не используется |
| **External API вызовы (X, YouTube, HikerAPI, etc)** | Платёжный у провайдера | ⚠️ **Настроены** (но отдельно) |

---

## 🎯 Сводка биллинга

**Что оплачивается (через подписку):**
- ✅ Интерактивные сессии 3 агентов (developer, researcher, assistant)
- ✅ Все входящие сообщения через labops-channel
- ✅ Все MCP запросы (внутри сессий)

**Что НЕ оплачивается дополнительно:**
- ✅ Systemd services (это просто процессы на VPS)
- ✅ labops-channel plugin (это часть Claude Code установки)
- ✅ Локальные MCP серверы

**Что оплачивается отдельно (НЕ Claude):**
- 🔴 xAI x_search (X API)
- 🔴 X API (Twitter posting)
- 🔴 YouTube Data API (free tier)
- 🔴 HikerAPI (Instagram)
- 🔴 Telegram (free API)

---

## 🚀 Рекомендации

1. **Оставить как есть** — всё на подписке, нет платёжных срабатываний
2. **Если захочешь крупномасштабную автоматизацию** (>1000 сообщений/день):
   - Рассмотри Agent API + claude -p для batch-операций
   - Будет платёжно, но дешевле чем по сообщениям
3. **Scheduled tasks** — если нужны периодические ночные запуски:
   - Используй crontab + claude -p (платёжно)
   - Или оставь живые сессии (на подписке)

---

## 📝 Команды для проверки состояния

```bash
# Статус всех 3 агентов
systemctl status claude-agent-{developer,researcher,assistant}

# Логи агента
journalctl -u claude-agent-assistant -f

# Проверка MCP серверов
curl -s http://localhost:5001/health 2>/dev/null || echo "MCP down"

# Проверка Telegram вебхуков
ps aux | grep labops-channel
```

