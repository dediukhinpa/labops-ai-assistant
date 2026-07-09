# second_brain Vault Guide — Общая память всех агентов

**Цель:** Все агенты записывают важные решения и знания в Vault чтобы любой агент мог восстановить контекст без ручного ввода.

**Проблема:** Каждый агент помнит свои решения, но при compact теряет контекст. Нужна общая память где информация НИКОГДА не теряется.

**Решение:** second_brain Vault — Postgres с pgvector, доступная через HTTP MCP для всех агентов.

---

## 📚 Что хранить в Vault

### 1. Decisions — Архитектурные решения

**Когда записывать:** Когда принял важное решение, выбрал инструмент, определил стратегию

**Кто записывает:** developer (кодер), но может любой

**Примеры:**
```python
second_brain-memory.create_decision_note(
    title="Trunk-based development with feature branches",
    body="""
    Решение: используем trunk-based development.
    
    Почему:
    - Быстрая интеграция
    - Минимум конфликтов merge
    - CI/CD постоянно работает
    
    Как:
    - main — всегда deployable
    - feature/* → PR → review → merge в main
    - Hotfix прямо в main
    - Release tags из main
    
    Инструменты:
    - GitHub для code review
    - Actions для CI/CD
    - Semantic versioning для releases
    """,
    tags=["git", "workflow", "deployment", "developer"]
)
```

**Другие примеры:**
- "Wiki classification strategy" (researcher)
- "Content distribution channels priority" (assistant)
- "Testing approach: unit + integration + e2e" (developer)
- "Data immutability policy for Second Brain raw/" (researcher)

---

### 2. Error Patterns — Ошибки и фиксы

**Когда записывать:** Когда найдена ошибка И найден способ её фиксить

**Кто записывает:** Любой агент

**Примеры:**

```python
second_brain-memory.create_error_pattern_note(
    title="Auth middleware race condition",
    body="""
    Симптом: Случайно некоторые запросы не аутентифицированы при высокой нагрузке
    
    Диагностика:
    - Check logs для 401 errors
    - Correlate с spike в request rate
    - Look for: multiple simultaneous auth attempts
    
    Root cause: 
    Middleware не thread-safe. Несколько concurrent requests 
    конкурируют за session lock → один fails
    
    Fix:
    1. Добавить mutex/lock вокруг session check
    2. Или переделать на stateless (JWT вместо session)
    3. Или увеличить pool connections
    
    Prevention:
    - Add load test в CI (simulate 100 concurrent)
    - Monitor: track auth failure rate
    - Alert: if failure rate > 0.1% → page oncall
    
    References:
    - Commit: abc123d "Fix auth race condition"
    - PR: #456
    - Ticket: PROJ-789
    """,
    tags=["auth", "concurrency", "bug", "fixed", "developer"]
)
```

**Другие примеры:**
- "Wiki duplication when compiling raw sources twice" (researcher)
- "Post not reaching audience due to TOV mismatch" (assistant)
- "Deployment fails if .env not synced with secrets" (developer)

---

### 3. External — Полезные ссылки и кейсы

**Когда записывать:** Когда нашёл полезный ресурс, кейс, пример извне

**Кто записывает:** Любой агент (researcher особенно)

**Примеры:**

```python
second_brain-memory.create_external_note(
    title="Successful Reels examples in AI niche",
    body="""
    Тематика: AI tools, automation, agents
    
    Примеры:
    
    1. TechCrunch AI explainers
       - Format: 60 сек, chalkboard animation
       - Hook: "This AI will change X industry forever"
       - CTA: Follow for daily AI news
       - Performance: 2.5M avg views
       - Why works: News angle, authority
    
    2. AI agent demonstrations (e.g., TaskGPT)
       - Format: 45 сек, real demo of agent doing task
       - Hook: "Watch AI solve problem in 30 seconds"
       - CTA: Try it at [link]
       - Performance: 800K-1.2M views
       - Why works: Tangible proof, FOMO
    
    3. Comparison content
       - Format: 90 сек, side-by-side comparison
       - Hook: "GPT-4 vs Claude vs Gemini: which is fastest?"
       - CTA: Subscribe for benchmarks
       - Performance: 500K-700K views
       - Why works: Decisive, opinionated, useful
    
    Pattern analysis:
    - Common hook: urgency + superlative ("first", "only", "fastest")
    - Common format: under 90 secs
    - Common CTA: "subscribe" or "try"
    - Common structure: problem → solution → proof
    
    Anti-patterns to avoid:
    - Too much text (hard to read at speed)
    - Unclear purpose in first 3 seconds
    - CTA at the very end (people scroll away)
    """,
    source_url="https://instagram.com/techcrunch/...",
    tags=["marketing", "reels", "examples", "assistant"]
)
```

---

## 🔍 Recall — Восстановление контекста

### Как агент вспоминает информацию

**В boot sequence:**
```bash
# STEP 0: Recover context from vault
second_brain-memory_router.recall(
    query="my_agent_name context decisions rules",
    limit=10,
    days=7
)
# Получит: последние решения, правила, важные notes за неделю
```

**Во время работы:**
```python
# Когда нужен контекст по какой-то области
second_brain-memory_router.recall(
    query="git workflow deployment strategy developer",
    limit=5
)
# Получит: топ-5 notes которые релевантны для developer про deployment

# Когда ищешь как фиксить баг
second_brain-memory_router.recall(
    query="race condition auth concurrent requests",
    limit=3
)
# Получит: known error patterns про race conditions
```

### Recall query examples

| Агент | Query | Используется для |
|---|---|---|
| developer | "architecture design patterns decisions" | Восстановить архитектурный контекст при старте |
| developer | "deployment emergency rollback recovery" | Быстро найти error-pattern если prod упал |
| researcher | "wiki structure classification raw compile" | Помнить как организована Second Brain |
| assistant | "content strategy tone voice post launch" | Помнить TOV и content strategy перед постингом |

---

## 📝 Как записать в Vault

### Шаблоны для разных типов

#### Decision Note Template

```python
second_brain-memory.create_decision_note(
    title="[SHORT DECISION TITLE]",
    body="""
    Context: [What was the situation?]
    
    Decision: [What was chosen and why?]
    
    Rationale:
    - Pro 1
    - Pro 2
    - Pro 3
    
    Alternatives considered:
    - Option A (rejected because...)
    - Option B (rejected because...)
    
    Impact: [What changed because of this decision?]
    
    Related:
    - Ticket: PROJ-123
    - PR: #456
    - Commit: abc123d
    """,
    tags=["category", "your_agent_name"]
)
```

#### Error Pattern Template

```python
second_brain-memory.create_error_pattern_note(
    title="[ERROR NAME]",
    body="""
    Symptoms: [What the user/system sees]
    
    Diagnosis:
    - Check [log/metric] for [signal]
    - If [condition] → [likely cause]
    
    Root cause: [Technical explanation]
    
    Fix:
    1. [Short-term fix]
    2. [Long-term fix]
    
    Prevention:
    - [What to add to tests]
    - [What to monitor]
    - [What to alert on]
    
    Status: [New/Fixed/Monitoring]
    First seen: [date]
    Last seen: [date]
    """,
    tags=["error", "bug", "your_agent_name"]
)
```

---

## 🎯 Vault Audit Workflow

### Step 1: Trigger audit

```bash
# developer (или любой агент) отправляет broadcast:
bash /home/agent/.claude-lab/vault-audit-broadcast.sh

# Это отправляет всем агентам задачу на audit
```

### Step 2: Каждый агент проверяет

```bash
# Агент запускает audit skript
bash /home/agent/.claude-lab/second_brain-vault-audit.sh developer ./.claude

# Output:
# [VAULT] Found 12 existing vault entries
# [VAULT] Missing items for developer:
#   - [ ] decision: deployment-strategy
#   - [ ] error_pattern: auth-race-condition
```

### Step 3: Каждый агент заполняет пропуски

```python
# developer видит что пропущено, добавляет:
second_brain-memory.create_decision_note(
    title="Deployment strategy",
    body="..."
)

# После каждого добавления отправляет подтверждение
second_brain-agent_router.notify(
    to_agent="developer",
    payload={
        "task": "vault_entry_added",
        "agent": "developer",
        "type": "decision",
        "title": "Deployment strategy"
    }
)
```

### Step 4: Финальный отчёт

```
developer отправляет в Telegram:
"✓ second_brain Vault audit completed
- Decisions added: 2 (deployment strategy, testing approach)
- Runbooks added: 1 (emergency rollback)
- Error patterns added: 3
- Total vault now: 28 entries
- All categories covered"
```

---

## 📊 Vault Content Checklist

### For developer (кодер)

- [ ] Decision: git workflow (trunk-based? feature branches?)
- [ ] Decision: testing strategy (unit? integration? e2e?)
- [ ] Decision: deployment approach (blue-green? canary?)
- [ ] Decision: error handling pattern
- [ ] Runbook: emergency rollback
- [ ] Runbook: database migration
- [ ] Runbook: security incident response
- [ ] Error pattern: auth/session bugs
- [ ] Error pattern: database connection issues
- [ ] Error pattern: CI/CD failures

### For researcher (Second Brain)

- [ ] Decision: wiki structure (how to organize?)
- [ ] Decision: raw/ immutability policy
- [ ] Decision: source tagging strategy
- [ ] Runbook: compile workflow (raw → wiki)
- [ ] Runbook: deduplication process
- [ ] Runbook: archive old content
- [ ] Error pattern: wiki duplication
- [ ] Error pattern: source miscategorization
- [ ] External: examples of well-organized wikis

### For assistant (маркетолог)

- [ ] Decision: content strategy (focus on which topics?)
- [ ] Decision: channel priority (which channel first?)
- [ ] Decision: posting schedule
- [ ] Decision: TOV (tone of voice rules)
- [ ] Runbook: post launch checklist
- [ ] Runbook: crisis response (bad post got negative reactions)
- [ ] Error pattern: TOV violations
- [ ] Error pattern: low-performing content patterns
- [ ] External: successful post examples

---

## ✅ Признак успеха

**Vault полностью заполнен когда:**
1. ✅ Каждый агент добавил свои decisions (3+)
2. ✅ Каждый агент добавил error patterns (2+)
3. ✅ Агенты могут recall контекст при старте
4. ✅ Новый агент может быстро понять как работает система

**После этого:**
- При compact контекста → agentы восстанавливают из vault
- При new task → agent может recall relevant decisions
- При bug → agent может найти similar error pattern

---

## 🚀 Команды для проверки

```bash
# 1. Запусти broadcast
bash /home/agent/.claude-lab/vault-audit-broadcast.sh

# 2. Проверь что агенты получили задачу
# (они увидят в boot sequence → pending tasks)

# 3. Каждый агент запускает audit
bash /home/agent/.claude-lab/second_brain-vault-audit.sh developer ./.claude

# 4. Агенты добавляют missing items
# (они делают second_brain-memory.create_*_note вызовы)

# 5. Проверь что добавилось
# (смотри logs в /logs/vault-audit/)

# 6. Всё готово когда все агенты отправили подтверждение
# (смотри pending tasks у developer)
```

---

## 📚 Примеры полных vault entries

Смотри реальные примеры в:
- `/home/agent/.claude-lab/second_brain-vault-examples/` (если существует)
- second_brain web UI (если настроена)
- Логи `second_brain-memory.create_*` вызовов в журналах агентов

