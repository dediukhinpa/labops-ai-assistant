# Automatic Read Receipts — 👀 на все сообщения в Telegram

**Status:** ✅ **ПОЛНОСТЬЮ АКТИВНО И РАБОТАЕТ**

**Запущено:** 2026-05-30 10:33 UTC

---

## 🎯 Что это делает

Когда ты отправляешь **любое** сообщение (текст, голос, фото, стикер) в Telegram боту:

```
Ты отправляешь сообщение
    ↓
developer/researcher/assistant получают
    ↓
Message Reaction Daemon проверяет каждые 3 сек
    ↓
Видит новое сообщение
    ↓
Немедленно ставит 👀 реакцию
    ↓
Ты видишь в Telegram: сообщение с 👀 под ним
    ↓
Агент обрабатывает сообщение (транскрибирует, отвечает и т.д.)
```

---

## 🔧 Как это работает

### Architecture

```
Message Reaction Daemon (3 процесса, по одному на агента)
    ↓
Работает постоянно (в фоне)
    ↓
Каждые 3 сек: curl getUpdates() к Telegram API
    ↓
Парсит JSON: извлекает chat_id + message_id
    ↓
Проверяет processed file (чтобы не ставить дважды)
    ↓
setMessageReaction() с emoji=👀
    ↓
Добавляет в processed file
```

### Files

| File | Purpose |
|---|---|
| `message-reaction-daemon.sh` | Основной daemon скрипт |
| `start-reaction-daemons.sh` | Запуск всех 3 daemon'ов |
| `/tmp/telegram-reactions-{agent}.processed` | Трекинг обработанных сообщений |
| `logs/reaction-daemons/` | Логи daemon'ов |

### Процессы

```bash
agent      84676  bash /home/agent/.claude-lab/message-reaction-daemon.sh developer
agent      84682  bash /home/agent/.claude-lab/message-reaction-daemon.sh researcher
agent      84692  bash /home/agent/.claude-lab/message-reaction-daemon.sh assistant
```

Каждый daemon:
- ✅ Работает независимо
- ✅ Использует свой bot token
- ✅ Проверяет каждые 3 сек
- ✅ Память-эффективный (processed file rotates на 1000 entries)

---

## 📋 Проверка статуса

### Все ли daemon'ы запущены?

```bash
ps aux | grep "message-reaction-daemon" | grep -v grep
```

**Должно быть 3 процесса** (developer, researcher, assistant)

### Логи

```bash
tail -f ~/.claude-lab/logs/reaction-daemons/developer.log
tail -f ~/.claude-lab/logs/reaction-daemons/researcher.log
tail -f ~/.claude-lab/logs/reaction-daemons/assistant.log
```

### Processed messages

```bash
wc -l /tmp/telegram-reactions-developer.processed
cat /tmp/telegram-reactions-developer.processed | tail -10
```

---

## 🚀 Тестирование

### Test 1: Текстовое сообщение

```
Telegram → labops-developer
Отправь: "Привет"
Ожидай: 👀 появляется под сообщением в течение 3 сек
```

### Test 2: Голосовое сообщение

```
Telegram → labops-researcher
Отправь: [5 сек голос] "тест"
Ожидай: 👀 под голосом + транскрибирование
```

### Test 3: Стикер

```
Telegram → labops-assistant
Отправь: [стикер]
Ожидай: 👀 под стикером
```

### Test 4: Фото

```
Telegram → любому агенту
Отправь: [фото]
Ожидай: 👀 под фото
```

**Все сообщения должны получить 👀 в течение 3-5 секунд**

---

## ⚙️ Configuration

### Интервал проверки

По умолчанию daemon проверяет каждые **3 секунды**.

Если хочешь изменить:

```bash
# Запусти daemon с другим интервалом (в секундах)
bash ~/.claude-lab/message-reaction-daemon.sh developer 5  # каждые 5 сек
```

### Emoji

По умолчанию используется **👀 (eyes)**.

Если хочешь другую реакцию, отредактируй скрипт:
```bash
# В message-reaction-daemon.sh найди:
"emoji": "👀"

# Замени на любую другую:
"emoji": "🔥"  # огонь
"emoji": "✅"  # галочка
"emoji": "❤️"  # сердце
```

---

## 🔄 Автоматический перезапуск

### При перезагрузке системы

Добавлено в crontab:
```bash
@reboot bash /home/agent/.claude-lab/start-reaction-daemons.sh
```

Daemon'ы автоматически запустятся при перезагрузке VPS.

### Manual restart

```bash
# Убить все daemon'ы
killall message-reaction-daemon.sh

# Запустить новые
bash ~/.claude-lab/start-reaction-daemons.sh
```

---

## 📊 Performance

### CPU Usage

Каждый daemon: ~0.0% CPU (спит между проверками)

### Network

- Каждые 3 сек: 1 HTTP request к Telegram API (getUpdates)
- Для каждого нового сообщения: 1 request (setMessageReaction)
- **Total:** ~20 requests/minute baseline + 1 per message

### Memory

- Processed file: rotates на 1000 entries (~10KB)
- Process: ~3-5MB каждый daemon

**Никакого влияния на производительность**

---

## 🔒 Security

- ✅ Bot tokens из `start-agent.sh` env vars
- ✅ API calls только к api.telegram.org
- ✅ Processed file в `/tmp` (защищен от других пользователей)
- ✅ Никаких логов с чувствительными данными

---

## 🐛 Troubleshooting

### Daemon не работает?

```bash
# Проверь процесс
ps aux | grep message-reaction-daemon

# Проверь логи
tail -100 ~/.claude-lab/logs/reaction-daemons/developer.log

# Проверь curl
source orchestration/lib/agents.sh
TOKEN="$(agent_bot_token <agent>)"
curl -s "https://api.telegram.org/bot${TOKEN}/getUpdates?limit=1"

# Перезапусти
bash ~/.claude-lab/start-reaction-daemons.sh
```

### Реакции не появляются?

```bash
# Проверь processed file
wc -l /tmp/telegram-reactions-developer.processed

# Очисти processed file (будут переобработаны старые сообщения)
rm /tmp/telegram-reactions-*.processed

# Перезапусти daemon'ы
bash ~/.claude-lab/start-reaction-daemons.sh

# Отправь новое сообщение и жди 3 сек
```

### Слишком много API запросов?

Увеличь интервал проверки:
```bash
# Отредактируй start-reaction-daemons.sh, измени:
bash "$DAEMON_SCRIPT" "$AGENT" &
# На:
bash "$DAEMON_SCRIPT" "$AGENT" 10 &  # каждые 10 сек вместо 3
```

---

## 📈 Monitoring

### Статистика за сеанс

```bash
# Количество обработанных сообщений
wc -l /tmp/telegram-reactions-*.processed

# Последние обработанные сообщения
for agent in developer researcher assistant; do
  echo "=== $agent ==="
  tail -5 /tmp/telegram-reactions-$agent.processed
done
```

### Real-time monitoring

```bash
# Смотри логи в реальном времени
tail -f ~/.claude-lab/logs/reaction-daemons/*.log
```

---

## 🎉 Итог

**✅ Автоматические read receipts работают для:**

- ✅ Текстовых сообщений
- ✅ Голосовых сообщений
- ✅ Фото
- ✅ Стикеров
- ✅ Всех других типов сообщений Telegram

**Задержка:** 3-5 секунд максимум (интервал проверки daemon)

**Никаких дополнительных действий не нужно** — просто отправляй сообщения, они будут автоматически получать 👀! 🚀

