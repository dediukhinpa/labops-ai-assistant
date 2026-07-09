# Hooks System — Детерминистический слой контроля

**Цель:** Сделать поведение агентов детерминистичным, независимым от LLM памяти.

**Проблема:** 
- Агент запоминает правило в rules.md
- Но при контекст-компакции память теряется
- Агент нарушает правило → записывает в rules.md снова
- На подскажи LLM может забыть про правило → нарушить снова

**Решение:** Hooks = shell-команды на lifecycle-событиях Claude Code (28 event'ов).
- SessionStart, UserPromptSubmit, PreToolUse, **PostToolUse**, Stop, Notification и др.
- Выполняются **независимо от LLM**, гарантированно
- Агент НЕ может их отключить

---

## 🎯 Наша реализация: update-rules Hook

### Что делает

```
Edit/Write/MultiEdit → PostToolUse → update-rules.sh
                                    ├─ читает LEARNINGS.md
                                    ├─ ищет CRITICAL / HARD RULE / MUST NOT
                                    ├─ проверяет, не в rules.md ли уже
                                    └─ дописывает в rules.md + дату
```

### Где установлено

| Агент | Файл | Hook |
|---|---|---|
| developer | `~/.claude-lab/developer/.claude/settings.json` | PostToolUse + `update-rules.sh` |
| researcher | `~/.claude-lab/researcher/.claude/settings.json` | PostToolUse + `update-rules.sh` |
| assistant | `~/.claude-lab/assistant/.claude/settings.json` | PostToolUse + `update-rules.sh` |

### Конфигурация в settings.json

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "marker": "update-rules-hook",
        "hooks": [
          {
            "type": "command",
            "command": "bash /home/agent/.claude-lab/update-rules.sh developer ./.claude 2>/dev/null || true"
          }
        ],
        "matcher": "Edit|Write|MultiEdit"
      }
    ]
  }
}
```

**Части конфига:**
- `"matcher": "Edit|Write|MultiEdit"` — срабатывает только на код-инструменты
- `bash /home/agent/.claude-lab/update-rules.sh developer ./.claude` — передаёт агент-имя и путь
- `2>/dev/null || true` — игнорирует ошибки, не блокирует сессию

---

## 📜 Скрипт: update-rules.sh

**Логика:**

1. Прочитай LEARNINGS.md (последние 20 строк)
2. Ищи паттерны: `CRITICAL`, `HARD RULE`, `MUST NOT`, `ALWAYS`, `never`
3. Для каждого найденного правила:
   - Очисти от маркеров (**, и т.д.)
   - Проверь, не дублируется ли уже в rules.md
   - Если новое — дописать в rules.md с датой и агент-именем
4. Exit 0 (не блокировать сессию)

**Пример вывода в rules.md:**

```markdown
# Rules

**[developer] 2026-05-30 10:15**
HARD RULE: никогда не пускай git push --force, всегда спрашивай подтверждение
```

---

## 🔄 Workflow: Как агент обновляет rules.md

### Сценарий 1: Новое правило

```
1. Агент Edit'ит код (например, исправляет баг)
2. PostToolUse триггер срабатывает
3. update-rules.sh читает LEARNINGS.md
4. Видит: "**HARD RULE: всегда проверяй зависимости перед git push**"
5. Этого нет в rules.md → дописывает
6. rules.md обновлена → агент видит при siguiente сессии
```

### Сценарий 2: Дублирование

```
1. Агент пишет два раза один rule в LEARNINGS
2. Hook срабатывает оба раза
3. На второй раз: скрипт видит, что rule уже в rules.md
4. Пропускает (не дублирует)
```

### Сценарий 3: Контекст-компакция

```
1. Сессия выросла → срабатывает auto-compact
2. LEARNINGS.md потеряны, но rules.md остались
3. При nueva сессии агент прочитает @include rules.md
4. Правило вернулось → агент помнит
```

---

## ⚠️ Когда rules.md становится Hook'ом

**rules.md = подсказка** (probabilistic) — агент может забыть.
**Hook = код** (deterministic) — гарантирован.

### Шаг за шагом:

1. **Агент нарушает правило → пишет в LEARNINGS** 
   - Статус: probabilistic, может забыть при compact

2. **Hook автоматически дописывает в rules.md** 
   - Статус: дешевле, чем hook, и часто достаточно

3. **Агент ВСЕГДА нарушает — даже после обновления rules.md** 
   - Статус: критично → переводим в Hook (shell-код)
   - Пример: `chmod -x rules.md` запретить редактировать, или вообще делать pre-check в SessionStart

4. **Hook срабатывает до сессии, не позволяет нарушить** 
   - Статус: гарантировано

### Пример перевода в Hook

Если agent систематически игнорирует "не пускать git push --force":

**Сейчас (rules.md):**
```markdown
**HARD RULE:** `git push --force` запрещён без explicit OK оператора
```

**Потом (SessionStart Hook):**
```json
{
  "hooks": {
    "SessionStart": [
      {
        "type": "command",
        "command": "alias git='git -c safe.branchProtection=true'; export GIT_FORCE_DENY=1"
      }
    ]
  }
}
```

Теперь agent физически не может запустить `git push --force`.

---

## 🔍 Мониторинг Hook'ов

### Проверь, что hook активен

```bash
# Проверь rules.md обновляется
tail -f ~/.claude-lab/developer/.claude/core/rules.md

# В другом терминале запусти агента и сделай Edit-операцию
# Должна появиться запись
```

### Логи hook'ов

Hook'ы запускаются молча (stderr редиректится в `/dev/null`). Чтобы отловить проблемы:

```bash
# Временно включи логирование (отредактируй settings.json)
# Замени: 2>/dev/null || true
# На: >> /tmp/update-rules.log 2>&1 || true

tail -f /tmp/update-rules.log
```

---

## 📋 Lifecycle-события Claude Code (полный список)

| Event | Когда | Пример использования |
|---|---|---|
| `SessionStart` | Начало сессии | Инициализация переменных, проверка доступа |
| `SessionEnd` | Конец сессии | Cleanup, архивирование логов |
| `UserPromptSubmit` | Юзер отправит сообщение | Логирование входящих запросов |
| `PreToolUse` | ДО вызова инструмента | Валидация параметров |
| **`PostToolUse`** | **ПОСЛЕ вызова инструмента** | **← Наш случай: обновление rules.md** |
| `PreAgentDispatch` | ДО спавнинга субагента | Проверка лимитов |
| `PostAgentDispatch` | ПОСЛЕ спавнинга субагента | Логирование результатов |
| `Stop` | Явный /stop команд | Финальная синхронизация |
| `Notification` | При PushNotification | Логирование уведомлений |

---

## 🎯 Рекомендации

### Для developer (кодер)

**rules.md достаточно:**
- "Никогда не пускай git push --force"
- "Всегда проверяй тесты перед коммитом"
- "Backup перед рискованной операцией"

**Hook нужен если:**
- Агент систематически забывает про проверку dependencies
- → Создай SessionStart hook: `npm audit` обязательна

### Для researcher (Second Brain)

**rules.md достаточно:**
- "Сохрани в raw/ ПРЕЖДЕ чем компилировать"
- "НИКОГДА не удаляй из raw/ (immutable)"

**Hook нужен если:**
- Агент стирает данные из raw/
- → SessionStart hook проверяет, что raw/ readonly: `chmod -R a-w raw/`

### Для assistant (маркетолог)

**rules.md достаточно:**
- "Всегда проверяй TOV перед постом"
- "CAC > LTV → алерт оператору"

**Hook нужен если:**
- Агент публикует без одобрения
- → SessionStart hook требует юзер-input перед каждым постом

---

## 📝 Как добавить новый Hook

1. Напиши скрипт (bash/python) — должен быть идемпотентным и быстрым
2. Сохрани в `/home/agent/.claude-lab/`
3. Добавь в settings.json:
```json
{
  "hooks": {
    "PostToolUse": [
      {
        "marker": "my-custom-hook",
        "hooks": [
          {"type": "command", "command": "bash /home/agent/.claude-lab/my-script.sh"}
        ],
        "matcher": "Write|Edit"
      }
    ]
  }
}
```
4. Перезапусти агента: `systemctl restart claude-agent-developer`
5. Проверь: логи, что скрипт срабатывает

---

## ✅ Проверка нашей установки

```bash
# Все три агента имеют update-rules hook
grep -l "update-rules-hook" ~/.claude-lab/*/.claude/settings.json

# Скрипт на месте и исполняем
ls -la /home/agent/.claude-lab/update-rules.sh

# Проверь rules.md каждого агента
ls -la ~/.claude-lab/developer/.claude/core/rules.md
ls -la ~/.claude-lab/researcher/.claude/core/rules.md
ls -la ~/.claude-lab/assistant/.claude/core/rules.md
```

**Результат:** Детерминистичная система контроля, **не зависящая от LLM памяти**. ✅

