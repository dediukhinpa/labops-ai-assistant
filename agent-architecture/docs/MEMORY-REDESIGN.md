# Memory redesign — active / passive / archive (maximal variant)

> Status: **IMPLEMENTED** (phases 1–7). Scope: `agent-architecture` layer of the
> `labops-ai-assistant` monorepo (+ the tg-plugin turn writer). `second_brain` is
> **not** redesigned — only used via existing MCP tools and the fixed
> `SECONDBRAIN_WRITE_RULES.md`. Live agents are not migrated; the change lands in
> the `agent-template` scaffold, orchestration, skills, and docs.
>
> Shipped: tier rename `hot/warm/cold → active/passive/archive`; `active-writer.sh`
> (episodic + salience); `working-set-build.sh` (non-blocking fused recall) +
> `recall-events.jsonl`; `reflect-nudge.sh` + `memory-consolidate` skill (in-session
> reflection, no `claude -p`); `decay-sweep.sh` + `archive-roll.sh` (pure-bash
> housekeeping, replacing the 4 model crons); watchdog idle trigger + Stop-hook
> checkpoint counter + `user-prompt-submit-hook.sh`. Verified by 50 bash unit tests
> + the tg-plugin memory suite.
>
> **Update 2026-09-10:** `working-set-build.sh`, `user-prompt-submit-hook.sh`, the
> `recall-events.jsonl` reinforcement, `MEMORY.md` and `LEARNINGS.md` were removed.
> The working set was never loaded into the agent's context, and in two months no
> agent touched the archive or the lessons log. The agent now recalls from
> second_brain itself before a task; operator corrections live in
> `passive/preferences.md` (always in context, never decays).

Заменяет старую возрастную ротацию `hot → warm → cold` (4 модельных крона) на
событийную модель памяти по **ценности**, с разделением на *эпизодическую* и
*семантическую* память.

---

## 0. Глоссарий — что означает каждый термин

Раздел специально простым языком, с бытовыми аналогиями.

- **Episodic memory (эпизодическая память)** — память о *событиях*: «что произошло».
  Аналогия: **дневник**. Дословная запись каждого хода: «14:30, оператор спросил X,
  агент ответил Y». Сырая, неосмысленная, append-only.

- **Episodic writer (эпизодический писатель)** — компонент, который после каждого
  хода агента **дописывает строку** в этот дневник (`active/episodic.md`). У нас это
  bash-скрипт на `Stop`-хуке — ничего не «думает», просто фиксирует факт хода.

- **Semantic memory (семантическая память)** — память о *знаниях/выводах*: «что я
  понял». Аналогия: не дневник, а **конспект**. Не «оператор спросил X», а вывод
  «оператор не любит длинные ответы». Живёт в `passive/`.

- **Reflect-движок (reflection / рефлексия)** — процесс, который **перечитывает
  дневник и выжимает из него выводы** в конспект. Это НЕ сжатие текста, а *синтез
  нового знания*. Аналогия: вечером перечитал записи за день и записал пару выводов.
  У нас рефлексию делает **живая сессия агента** (не фоновый процесс — `claude -p`
  запрещён): триггер лишь «подталкивает» её уведомлением, а агент сам читает
  episodic и пишет инсайты своими обычными инструментами.

- **Recall (вспоминание / подтягивание)** — когда нужное прошлое воспоминание
  **возвращается в текущий контекст**. Аналогия: собеседник упомянул проект — и ты
  «вспомнил», что вы по нему решали. У нас: на старте сессии или на новом вопросе
  идём в `second_brain` + локальный `passive/`, находим релевантные заметки и
  вкладываем их в `active/working-set.md`, чтобы агент «помнил». Модель для этого не
  нужна — это **поиск** (у second_brain уже посчитаны эмбеддинги).

- **Reinforcement (подкрепление)** — если воспоминание всплыло в recall и оказалось
  полезным, мы его **усиливаем**, чтобы жило дольше. Аналогия: интервальное
  повторение — чем чаще вспоминаешь, тем крепче помнишь. У нас: каждый recall
  добавляет строку в `recall-events.jsonl`, а заметке поднимает `recall_count` и
  продлевает «период полураспада».

- **Decay (затухание)** — воспоминания, которые **никогда не используются**,
  постепенно теряют «вес» и в итоге уезжают в архив. Аналогия: кривая забывания —
  неиспользуемое стирается. У нас: у каждой заметки есть score, падающий со временем;
  если она ни разу не всплыла и score упал ниже порога → в `archive/superseded/`.

- **Idle-триггер (триггер по простою)** — запуск консолидации, когда агент
  **молчит/простаивает** заданное время (10 мин), а не в фиксированный час.
  Аналогия: мозг консолидирует память во сне/отдыхе, а не по будильнику. У нас:
  `watchdog.sh` уже умеет видеть простой — при 10 мин тишины он шлёт сессии nudge
  «сделай рефлексию».

- **Checkpoint (чекпойнт)** — промежуточная консолидация **каждые N ходов** (не
  дожидаясь конца сессии), чтобы длинная сессия не копила всё в кучу. Дефолт `N=20`.

- **tail-idle** — сколько ждать после последнего сообщения, прежде чем считать
  «всплеск активности завершённым» (дефолт **5 мин**, идея из hivemind). Отделяет
  «оператор ещё печатает» от «диалог закончился».

- **Salience gate (фильтр значимости)** — быстрое решение «стоит ли это вообще
  запоминать/вспоминать». Аналогия: не записываешь в конспект «ок» и «спасибо». У нас
  это **эвристика на bash** (ключевые слова, наличие tool-call, правка оператором) —
  без модели.

- **Working set (рабочий набор)** — то немногое, что реально загружено в контекст
  *прямо сейчас* под текущую задачу. Не «вся память», а её релевантный срез,
  пересобираемый на старте сессии.

- **Provenance (происхождение)** — у каждого инсайта ссылка на исходные episodic-
  записи, из которых он выведен. Делает синтез **обратимым**: есть вывод — есть и
  указатель на сырьё.

- **dual-write (двойная запись)** — важное знание пишется и в локальный файл, и в
  общий `second_brain` (идемпотентно по sha256). Правило зафиксировано в
  `SECONDBRAIN_WRITE_RULES.md`.

---

## 1. Роль second_brain — и нужен ли он

`second_brain` **не дублирует** локальные тиры и **не исчезает** — у них разные задачи.

| | Локальные `active/passive/archive` | `second_brain` (L4) |
|---|---|---|
| Область | один агент, приватно | весь рой, общее |
| Хранит | сырой episodic + *своя* семантика + working-set | durable общее знание + координация |
| Доступ | файлы, без сети, в контексте | MCP по сети, on-demand |
| Роль | рабочая память + личный кэш | источник правды общего знания (vault) |

- `passive/` — это *проекция/кэш* релевантного знания для ЭТОГО агента + приватные
  заметки вне shared-scope.
- `second_brain` — слой *propagate/compound*: младший агент получает выводы старшего.
  Локальные файлы физически не умеют делиться между агентами.

**Использование по триггерам:**
- Рефлексия → инсайт → dual-write в second_brain фиксированными тулами
  (`create_decision_note` / `create_error_pattern_note` / …), recall-before-write.
- Recall → working-set собирается из second_brain (RRF) **+** локального `passive/`.
- Decay → считаем локально; temporal decay внутри second_brain его собственный, не трогаем.

**Когда second_brain не нужен:** одиночный агент без роя — работаем file-only
(лексический fallback, опц. локальный embed-демон). Движок памяти проектируем с
**graceful-degrade**: нет `SECOND_BRAIN_*` → file-only + честный лог «shared layer off».
**Для роя (цель labops) — обязателен.**

---

## 2. Ограничение: `claude -p` запрещён везде

Никаких headless-вызовов модели в фоне. Следствия:
- **Retrieval/recall** — модель не нужна: second_brain отдаёт hybrid-recall по
  готовым эмбеддингам (FastEmbed). `working-set-build.sh` = `curl` к MCP.
- **Salience/prompt-worthiness** — bash-эвристики, без модели.
- **Reflection/синтез** — делает **живая сессия**, разбуженная nudge'ом через
  `agent_router.notify` (проверенный паттерн `night-learnings.sh`). Фоновый скрипт
  только шлёт уведомление; «думает» сессия и пишет своими MCP-инструментами.
- **decay-sweep** — чистая bash-арифметика.

Итог: единственные скрипты «с интеллектом» — это nudge'и в живую сессию; сами по себе
все фоновые компоненты — чистый bash + `curl`.

---

## 3. Целевая раскладка воркспейса

```
core/
├── active/
│   ├── episodic.md         # сырой append-only лог ходов (был hot/recent.md)
│   ├── working-set.md      # материализованный recall под задачу (пересобирается)
│   ├── handoff.md          # как раньше
│   └── pre-compact/        # снапшоты PreCompact (был hot/pre-compact/)
├── passive/
│   ├── insights.md         # НОВОЕ: синтез-инсайты рефлексии (с provenance)
│   ├── decisions.md        # был warm/decisions.md
│   ├── errors.md           # error-patterns
│   └── preferences.md      # предпочтения оператора
├── archive/
│   ├── episodic/YYYY-MM.md # скрученный сырой лог (был hot/archive/ + старый MEMORY.md)
│   └── superseded/         # затухшие/вытесненные инсайты
├── recall-events.jsonl     # НОВОЕ: лог всех recall (сигнал reinforcement) — из hivemind
├── MEMORY.md / LEARNINGS.md # остаются (концептуально относятся к тиру «archive»)
```

---

## 4. Компоненты

| Файл | Тип | Заменяет | Что делает | «Интеллект» |
|---|---|---|---|---|
| `scripts/active-writer.sh` | новый | часть Stop-хука, `hot-writer.ts` | append в `episodic.md` + salience-тег (эвристика) | bash |
| `scripts/reflect-nudge.sh` | новый | `trim-hot.sh`, `compress-warm.sh` | шлёт сессии nudge «консолидируй»; синтез делает агент | сессия |
| `skills/memory-consolidate/` | новый | — | скилл: КАК агент рефлексирует (читает episodic → пишет `passive/` + dual-write) | — |
| `scripts/working-set-build.sh` | новый | `second_brain-memory_router-on-start.sh` | собрать `working-set.md`: `curl` second_brain (RRF) + `passive/`; non-blocking (timeout 1с, skip-on-timeout) + reinforce | bash+curl |
| `scripts/decay-sweep.sh` | новый | `rotate-warm.sh`, `memory-rotate.sh` | decay-score → вытеснение в `archive/superseded/` | bash |
| `scripts/archive-roll.sh` | новый | — | скрутка `episodic.md` по размеру в `archive/episodic/` | bash |
| `hooks/stop-hook.sh` | правка | — | active-writer + счётчик ходов + checkpoint-nudge каждые N | bash |
| `hooks/session-start-hook.sh` | правка | — | working-set-build + reinforce | bash |
| `hooks/user-prompt-submit-hook.sh` | новый | — | prompt-worthiness gate (эвристика) → recall → working-set | bash |
| `orchestration/watchdog.sh` | правка | — | idle-триггер: простой 10 мин → `reflect-nudge.sh` | bash |
| `settings.json.template` | правка | — | развести хуки (+ UserPromptSubmit), убрать cron-инструкции | — |
| `agent-template/` каталоги | rename | — | `hot/→active/`, `warm/→passive/`, `hot/archive→archive/episodic` | — |

---

## 5. Триггеры (рантайм-контракт)

| Событие | Механизм | Работа | Модель |
|---|---|---|---|
| UserPromptSubmit | hook + эвристика | recall под запрос → working-set (skip ack'ов, timeout 1с) | нет |
| Stop (каждый ход) | hook | episodic append + salience-тег + счётчик | нет |
| каждые **N=20** ходов | счётчик в Stop | checkpoint: `reflect-nudge` → агент пишет passive + dual-write | сессия |
| idle **10 мин** | watchdog | полная консолидация + decay + archive-roll (через nudge) | сессия |
| SessionStart | hook | пересбор working-set + reinforce | нет |
| PreCompact | hook | снапшот (как есть) | нет |
| ночью | **1 bash-крон** (страховка) | decay-sweep, без модели | нет |

Было **4 модельных крона** → стало **0 модельных кронов + 1 bash-страховка**; вся
модельная работа — в живой сессии по событию.

---

## 6. Decay / reinforcement — механика

Каждый инсайт в `passive/` имеет YAML-frontmatter:

```yaml
---
id: <sha256-8>
created: 2026-07-09T14:30:00Z
last_recalled: 2026-07-09T14:30:00Z
recall_count: 0
half_life_days: 14        # база; растёт при подкреплении
salience: decision         # ephemeral|fact|decision|error|preference
provenance: [ep-2026-07-09-0031, ep-2026-07-09-0033]
---
```

- **Recall** заметки → строка в `recall-events.jsonl` → `recall_count++`,
  `half_life_days *= 1.5` (подкрепление).
- **decay-sweep.sh** (ночью, bash): `score = 2^(-age_days / half_life_days)`;
  если `score < 0.25` **и** `recall_count == 0` → переносит в `archive/superseded/`.
- Пороги и множители — константы в шапке скрипта (без магических чисел в теле).

---

## 7. Best practices из activeloopai/hivemind (встроены)

| Практика hivemind | Применение у нас |
|---|---|
| Ноль кронов, всё событийно (stop/end + idle-tail 5 мин) | хуки + idle-триггер watchdog |
| Дешёвый gate «worth keeping?» | у нас — bash-эвристика (без модели, т.к. `claude -p` запрещён) |
| Recall non-blocking (`TIMEOUT_MS=1000`, skip-on-timeout, `MIN_OVERLAP=2`) | working-set-build с hard-timeout и порогом |
| Prompt-worthiness (skip ack'ов) | user-prompt-submit-hook: не дёргать recall на «ок» |
| `recall-events.jsonl` | тот же лог → сигнал для decay-reinforcement |
| checkpoint каждые N ходов | `N=20` |
| Codify паттернов в артефакт (SKILL.md) | инсайты могут дорастать до skill/error-pattern |
| Provenance на инъекциях | working-set помечает источник и дату |

**Где мы сильнее hivemind:** у него нет decay/eviction/тиринга («stored
indefinitely»). Наш `active/passive/archive` + decay-reinforcement закрывает эту дыру.

---

## 8. Дефолты / конфиг

| Параметр | Значение | Где |
|---|---|---|
| `MEMORY_CHECKPOINT_EVERY_N_TURNS` | `20` | stop-hook |
| `MEMORY_IDLE_CONSOLIDATE_MIN` | `10` | watchdog |
| `MEMORY_TAIL_IDLE_MIN` | `5` | stop-hook / watchdog |
| `RECALL_TIMEOUT_MS` | `1000` | working-set-build |
| `RECALL_MIN_OVERLAP` | `2` | working-set-build (lexical fallback) |
| `DECAY_HALF_LIFE_DAYS` | `14` | decay-sweep |
| `DECAY_ARCHIVE_THRESHOLD` | `0.25` | decay-sweep |
| `EPISODIC_ROLL_KB` | `40` | archive-roll |

---

## 9. Фазы (атомарно, коммит после каждой)

1. **Rename + реструктуризация каталогов** шаблона (`active/passive/archive`).
2. **Episodic-writer + salience-эвристика** (+ тесты).
3. **Reflect-nudge + скилл `memory-consolidate`** (+ тесты; graceful-degrade без second_brain).
4. **Working-set build + recall** non-blocking (+ тесты).
5. **Decay/reinforcement + housekeeping** (+ тесты).
6. **Watchdog idle-триггер + UserPromptSubmit hook**.
7. **Переписать доки** (`MEMORY.md`, `FILES-REFERENCE.md`, `SETUP-GUIDE.md`,
   `CHECKLIST.md`, `TOKEN-OPTIMIZATION.md`, README-упоминания).

---

## 10. Риски / открытые вопросы

- Все модельные операции идут через живую сессию → надо аккуратно оформить nudge,
  чтобы не зациклить хуки (использовать `CLAUDE_SDK_CHILD`-guard, как в текущих хуках).
- `test.sh` содержит ассерты про запрет `claude -p` — новая схема им **соответствует
  by design** (мы вообще не зовём headless claude). На фазе 2 подтвердить.
- Salience-эвристика без модели грубее, чем Haiku-gate у hivemind — компенсируем тем,
  что финальную оценку значимости даёт сессия на рефлексии.
- Формат salience-метки: inline-тег в episodic (`[decision]`) — принято (проще/дешевле).

---

_Источник best practices: [activeloopai/hivemind](https://github.com/activeloopai/hivemind) (Apache-2.0)._
