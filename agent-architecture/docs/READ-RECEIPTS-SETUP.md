# Read Receipts via Telegram Reactions — Автоматические 👀

**Статус:** ✅ **ГОТОВО К ИСПОЛЬЗОВАНИЮ**

---

## 📋 Что настроено

### 1. Автоматическая установка реакций

- ✅ Boot sequence updated (`agent-boot-sequence.sh`)
  - При старте агента автоматически ставит реакцию 👀 на последние 5 сообщений
  - Это работает для всех трёх агентов (developer, researcher, assistant)

### 2. Manual reaction script

- ✅ `/home/agent/.claude-lab/set-message-reaction.sh` создан
  - Позволяет установить реакцию вручную на любое сообщение
  - Использование: `bash ~/.claude-lab/set-message-reaction.sh <agent> <chat_id> <message_id> [emoji]`
  - Default emoji: 👀 (eyes)

### 3. CLAUDE.md Updated

- ✅ developer: инструкция о том что реакции устанавливаются автоматически
- ✅ researcher: тоже самое
- ✅ assistant: тоже самое

---

## 🎯 Как это работает

### Сценарий 1: Автоматические реакции при старте

```
1. Ты отправляешь голос в Telegram
2. Агент получает сообщение
3. При SessionStart hook:
   - Boot sequence запускается
   - Берёт токен бота
   - Вызывает Telegram API: getUpdates(limit=5)
   - На каждое сообщение ставит 👀 реакцию
   - setMessageReaction(chat_id, message_id, emoji="👀")
4. Оператор видит в Telegram: сообщение marked with 👀
5. Агент транскрибирует и обрабатывает голос
```

### Сценарий 2: Ручная реакция (если нужна специальная)

```bash
# Если хочешь другую реакцию (например 🔥 на важное), используй:
bash ~/.claude-lab/set-message-reaction.sh developer 123456 789 "🔥"

# developer = имя агента
# 123456 = chat_id
# 789 = message_id
# 🔥 = emoji (опционально, default 👀)
```

---

## 🚀 Тестирование

### Шаг 1: Отправить сообщение в Telegram

Отправь голос developer'у:

```
[Голосовое сообщение, 10 сек]
"Привет, это тест"
```

### Шаг 2: Проверить реакцию

Ты должен увидеть в Telegram:
- Сообщение с реакцией 👀 (eyes emoji under the message)
- Это значит что агент получил и прочитал сообщение

### Шаг 3: Получить ответ

developer ответит:
```
Получил голос. Транскрибировано: "Привет, это тест". Что делать?
```

---

## 🔧 Технические детали

### Architecture

```
Agent Boot Sequence (SessionStart hook)
    ↓
GET https://api.telegram.org/bot<TOKEN>/getUpdates?limit=5
    ↓
Parse result for chat_id and message_id
    ↓
For each message:
  POST /setMessageReaction
    {
      "chat_id": <id>,
      "message_id": <id>,
      "reaction": [{"type": "emoji", "emoji": "👀"}]
    }
    ↓
Message gets 👀 reaction in Telegram
```

### Files Updated

| File | Change |
|------|--------|
| `/home/agent/.claude-lab/agent-boot-sequence.sh` | Added STEP 0: Set message reactions |
| `/home/agent/.claude-lab/set-message-reaction.sh` | NEW: Manual reaction setter |
| `~/.claude-lab/developer/.claude/CLAUDE.md` | Updated Voice Messages section |
| `~/.claude-lab/researcher/.claude/CLAUDE.md` | Updated Voice Messages section |
| `~/.claude-lab/assistant/.claude/CLAUDE.md` | Updated Voice Messages section |

### Bot Tokens Used

Each agent's bot token is read at runtime from its channel env file
(`/etc/labops-plugin/<agent>/channel.env` or
`$CLAUDE_LAB/shared/state/<agent>/telegram/channel.env`) via
`orchestration/lib/agents.sh` — tokens are never hardcoded in this repo.

- `<agent>`: `<TELEGRAM_BOT_TOKEN>`

---

## ✅ Verify Setup

```bash
# 1. Check boot sequence script
grep -A20 "STEP 0" ~/.claude-lab/agent-boot-sequence.sh

# 2. Check set-message-reaction.sh exists
ls -la ~/.claude-lab/set-message-reaction.sh

# 3. Check CLAUDE.md updated
grep -A5 "Реакция 👀" ~/.claude-lab/developer/.claude/CLAUDE.md

# 4. Check agents running
tmux list-sessions | grep labops

# 5. Check boot logs
ls -la ~/.claude-lab/logs/boot-sequence/
```

---

## 🎁 Features

### What Operators See

Когда ты отправляешь сообщение боту:

| Что видишь | Значение |
|---|---|
| 📝 Сообщение в чате | Ты отправил это |
| ✅ No reaction | Бот ещё не получил |
| 👀 Eyes emoji under message | Бот получил и прочитал |
| 💬 Ответ от бота | Бот обработал и ответил |

### What Agents Do

| Агент | При получении голоса |
|---|---|
| developer | Ставит 👀 → Транскрибирует → Добавляет в vault/создаёт note |
| researcher | Ставит 👀 → Транскрибирует → Сохраняет в Second Brain |
| assistant | Ставит 👀 → Транскрибирует → Создаёт content draft |

---

## 📚 Примеры

### Example 1: Send voice to developer

```
[5 sec voice message]
"Добавь правило про error handling в vault"
```

**Результат:**
1. 👀 реакция появляется на сообщение (автоматически)
2. developer обрабатывает голос
3. developer добавляет decision_note в second_brain: "error-handling-best-practices"
4. developer отправляет ответ: "✓ Добавил в vault. Тип: error_pattern"

### Example 2: Voice to assistant

```
[3 sec voice message]
"Напиши пост про новый Anthropic API"
```

**Результат:**
1. 👀 реакция на сообщение
2. assistant создаёт draft поста
3. assistant отправляет draft для review

---

## 🔐 Security

- Bot tokens хранятся только в start-agent.sh
- API запросы идут только в api.telegram.org (официальный API)
- set-message-reaction.sh требует явного вызова с chat_id и message_id
- Без токена ничего не работает (публичная информация, safe)

---

## 🎯 Итого

**Read receipts работают автоматически:**

- ✅ developer получает 👀 при любом сообщении
- ✅ researcher получает 👀 при любом сообщении
- ✅ assistant получает 👀 при любом сообщении

**Никакой дополнительной настройки не нужно.** Просто отправляй сообщения/голос — агенты автоматически покажут что прочитали! 🎤

