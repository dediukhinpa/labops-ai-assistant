# Quick Reference — Быстрая шпаргалка

## 🎯 3 Агента в Telegram

| Агент | Model | Telegram | Специализация | Скорость |
|---|---|---|---|---|
| **developer** | Opus 4.8 | `labops-developer` | Код + Архитектура | 2-3 сек |
| **researcher** | Sonnet 4.6 | `labops-researcher` | Knowledge + Research | 1-2 сек |
| **assistant** | Haiku 4.5 | `labops-assistant` | Content + Marketing | 0.5-1 сек |

---

## 📋 Какого агента выбрать?

**Нужен код?** → developer  
**Нужна архитектура?** → developer  
**Code review?** → developer  
**Нужно сохранить информацию?** → researcher  
**Поиск в базе?** → researcher  
**Организовать wiki?** → researcher  
**Написать контент?** → assistant  
**Анализ метрик?** → assistant  
**Быстрый ответ?** → assistant  

---

## 🚀 5 шагов к использованию

1. **Telegram** → Search → `labops-developer` (или researcher/assistant)
2. **Отправи** → text/voice/photo/sticker
3. **Жди** → 👀 emoji (3-5 сек)
4. **Получи ответ** → Agent responds
5. **Done** → Use the result

---

## 💬 Примеры команд

### developer (Код/Архитектура)
```
"Напиши REST API для users"
"Помоги с архитектурой"
"Сделай code review"
"Как лучше организовать БД?"
```

### researcher (Knowledge)
```
"Сохрани эту статью"
"Найди про кэширование"
"Структурируй информацию"
"Какие паттерны в моих знаниях?"
```

### assistant (Content)
```
"Напиши пост про AI"
"Какой engagement?"
"Проверь тон"
"Content calendar?"
```

---

## ⚡ Special Features

| Feature | Что это | Как использовать |
|---------|---|---|
| **Voice** | Groq Whisper | Send voice message → auto transcribe |
| **Read Receipts** | 👀 emoji | Every message gets reaction |
| **Shared Brain** | second_brain vault | developer saves → researcher recalls |
| **Inter-agent** | Task delegation | developer → researcher task |
| **Night Cycle** | 02:00 learning | Agents improve automatically |

---

## 🔧 Управление (Advanced)

```bash
# Check all agents running
tmux list-sessions | grep labops

# Check reaction daemons
ps aux | grep message-reaction-daemon | grep -v grep

# View logs
tail -f ~/.claude-lab/logs/reaction-daemons/developer.log
tail -f ~/.claude-lab/logs/boot-sequence/developer*.log

# Restart daemon
killall message-reaction-daemon.sh
bash ~/.claude-lab/start-reaction-daemons.sh

# Restart agent
tmux kill-session -t labops-developer
bash ~/.claude-lab/start-agent.sh developer
```

---

## 📊 Model Specs

**Opus 4.8**
- Context: 200k tokens
- Speed: 2-3 sec
- Best: Complex reasoning, code, architecture
- Cost: $15/1M tokens

**Sonnet 4.6**
- Context: 200k tokens
- Speed: 1-2 sec
- Best: Balanced (speed + quality)
- Cost: $3/1M tokens

**Haiku 4.5**
- Context: 200k tokens
- Speed: 0.5-1 sec
- Best: Quick tasks, high volume
- Cost: $0.80/1M tokens

---

## 🎤 Voice Support

- Language: Auto-detect (Russian, English, 98+ languages)
- Cost: $0.02/hour
- Latency: <1 second
- Max length: 30+ minutes
- Format: OGG (Telegram native)

---

## 📁 Key Directories

```
~/.claude-lab/
├── developer/.claude/       ← developer workspace
├── researcher/.claude/            ← researcher workspace
├── assistant/.claude/           ← assistant workspace
├── start-agent.sh             ← startup script
├── message-reaction-daemon.sh ← reaction daemon
├── agent-boot-sequence.sh     ← boot hook
└── TELEGRAM-COMPLETE-SETUP.md ← full guide
```

---

## ✅ Status Check

```bash
# Quick status
echo "=== Agents ===" && tmux list-sessions | grep labops | wc -l
echo "=== Daemons ===" && ps aux | grep message-reaction | grep -v grep | wc -l
echo "=== API Keys ===" && ls ~/.claude-lab/*/\.claude/secrets/groq* 2>/dev/null | wc -l
```

---

## 🎯 Pro Tips

1. **Use developer for thinking**, researcher for memory, assistant for speed
2. **Send voice** for hands-free commands
3. **Read receipts appear in 3-5 sec** (don't worry if slower)
4. **Agents recall shared knowledge** automatically from vault
5. **Night cycle improves agents** at 02:00 daily
6. **Boot sequence guarantees delivery** even if webhook fails
7. **All messages get 👀** — text, voice, photos, stickers

---

## 🆘 Troubleshooting

| Problem | Solution |
|---------|----------|
| No 👀 reaction | Restart daemons: `bash ~/start-reaction-daemons.sh` |
| Agent not responding | Check tmux: `tmux list-sessions` |
| Voice not transcribed | Check API key: `cat ~/.claude-lab/developer/.claude/secrets/groq-api-key` |
| Slow response | Check which model: Opus (2-3s) vs Sonnet (1-2s) vs Haiku (0.5s) |

---

## 📚 Documentation

- **Full setup**: `TELEGRAM-COMPLETE-SETUP.md`
- **Voice guide**: `VOICE-MESSAGES-SETUP.md`
- **Read receipts**: `AUTOMATIC-READ-RECEIPTS.md`
- **All features**: `FEATURES-SUMMARY.md`

---

**Ready to use? Open Telegram and find `labops-developer` 🚀**
