<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/labops-logo-dark.svg">
    <img src="assets/labops-logo.svg" alt="LabOps.ai" width="280">
  </picture>
</p>

<h1 align="center">labops-agent-architecture</h1>

<p align="center"><em>операционка с AI изнутри профессии</em></p>

<p align="center">
  <a href="https://labopsai.pro"><img src="https://img.shields.io/badge/%F0%9F%8C%90%20labopsai.pro-6E56CF?style=for-the-badge" alt="labopsai.pro"></a>
  <a href="./LICENSE"><img src="https://img.shields.io/badge/License-Proprietary-CC2B2B?style=for-the-badge" alt="License: Proprietary"></a>
  <img src="https://img.shields.io/badge/Built%20by-LabOps.ai-111111?style=for-the-badge" alt="Built by LabOps.ai">
</p>

<p align="center"><a href="README.md">English</a> · <a href="README.ru.md"><b>Русский</b></a></p>

<p align="center">
  <b>Система labops:</b>
  <a href="https://github.com/dediukhinpa/labops-tg-plugin">tg-plugin</a> ·
  <a href="https://github.com/dediukhinpa/labops-second-brain">second-brain</a> ·
  <b>agent-architecture</b>
</p>

**Рантайм- и lifecycle-слой агентной системы labops** — воркспейсы агентов (CLAUDE.md / rules.md / слои памяти), скаффолдер `agent-template`, пер-агентный рантайм (`watchdog.sh → start-agent.sh → tmux → долгоживущая сессия Claude Code`), systemd-юниты, хуки жизненного цикла, автоматизация роя и скилл **`create-agent`**, которым первый агент (Developer / Разработчик) разворачивает остальных агентов «под ключ».

Это один из **трёх** репозиториев системы labops. Он отвечает за то, как агент **живёт** (процессы, память, самовосстановление). Канал и общий мозг — в соседних репозиториях:

- **[`labops-tg-plugin`](https://github.com/dediukhinpa/labops-tg-plugin)** — Telegram-канал: пер-агентный бот, голос, реакции, webhook.
- **[`labops-second-brain`](https://github.com/dediukhinpa/labops-second-brain)** — общая память: MCP `memory:5001` / `memory_router:5002` / `agent_router:5000` / `task:5003`. Агент получает Bearer-токен и читает/пишет через MCP.

> [!IMPORTANT]
> **Платформа:** Linux + systemd + tmux. На macOS/без systemd агент можно гонять вручную в tmux, но не как службу (нет автозапуска/самовосстановления).

---

## Содержание

1. [Зачем labops](#зачем-labops)
2. [Быстрый старт](#быстрый-старт)
3. [Архитектура рантайма](#архитектура-рантайма)
4. [Слои памяти агента](#слои-памяти-агента)
5. [agent-template — скаффолдер](#agent-template--скаффолдер)
6. [Скилл `create-agent` (end-to-end)](#скилл-create-agent-end-to-end)
7. [Хуки жизненного цикла и автоматизация роя](#хуки-жизненного-цикла-и-автоматизация-роя)
8. [Скиллы в комплекте](#скиллы-в-комплекте)
9. [Установка и модель/авторизация](#установка-и-модельавторизация)
10. [Переменные и настройки](#переменные-и-настройки)
11. [Если что-то не работает](#если-что-то-не-работает)
12. [FAQ](#faq)
13. [Данные и приватность](#данные-и-приватность)
14. [Часть системы labops](#часть-системы-labops)
15. [Лицензия](#лицензия)

---

## Зачем labops

В системе labops **бэкенд устроен Agent-Native**: память, рой и канал — это API/MCP *для агентов*, а не интерфейс для человека. Человеку (Оператору) виден только Telegram. Этот репозиторий — то, что превращает «движок» Claude Code в **постоянно живущего агента**: даёт ему рабочее место (воркспейс с памятью), супервизора (watchdog под systemd), события жизненного цикла (хуки) и связь с роем.

- **Самозагрузка роя.** Не нужно вручную поднимать каждого агента. Вы устанавливаете **первого агента — Developer / Разработчик**, а дальше он сам, через скилл [`create-agent`](#скилл-create-agent-end-to-end), разворачивает следующих.
- **Одна установка — дальше рой растёт сам.** `create-agent` скаффолдит воркспейс, регистрирует Telegram-бота, подключает голос, выдаёт second_brain-токен, ставит автозапуск под systemd и прогоняет smoke-тест — развёртывание агентов становится операцией самого роя, а не ручной процедурой оператора.
- **Вложенное самовосстановление.** systemd держит watchdog, watchdog держит tmux+claude, claude держит канал-сервер. Падение на любом уровне лечится уровнем выше.
- **Проверка побеждает память.** Иерархия истины: live-проверка (exec/grep) → second_brain (общий мозг) → git-история → локальная память. Память противоречит проверке — побеждает проверка.
- **Честная установка.** Если чего-то нет — установка честно перечислит, что **не** настроено (а не покажет ложный зелёный).

```mermaid
%%{init: {'theme':'base','themeVariables':{'primaryColor':'#EDE9FE','primaryTextColor':'#4C1D95','primaryBorderColor':'#8B5CF6','lineColor':'#8B5CF6','secondaryColor':'#F1F5F9','tertiaryColor':'#ffffff','clusterBkg':'transparent','clusterBorder':'#B794F4','fontFamily':'Helvetica,Arial,sans-serif'}}}%%
flowchart LR
  Operator["Оператор"] -->|install.sh| Dev["Агент Developer / Разработчик"]
  Dev -->|скилл create-agent| A2["Агент &lt;agent-2&gt;"]
  Dev -->|скилл create-agent| A3["Агент &lt;agent-3&gt;"]
  Dev -->|скилл create-agent| An["Агент &lt;agent-N&gt;"]
  subgraph deps["Зависимости (соседние репозитории)"]
    TG["labops-tg-plugin (канал)"]
    SB["labops-second-brain (общий мозг)"]
  end
  Dev -.->|канал + токен| deps
  A2 -.-> deps
  A3 -.-> deps
  classDef brand fill:#8B5CF6,stroke:#6D28D9,color:#ffffff,font-weight:bold
  classDef ext fill:#CCFBF1,stroke:#0D9488,color:#0F766E
  classDef store fill:#FEF3C7,stroke:#D97706,color:#92400E
  classDef sys fill:#E2E8F0,stroke:#334155,color:#1E293B
  linkStyle default stroke:#8B5CF6,stroke-width:1.5px
  class Dev brand
  class TG,SB ext
```

Границы ответственности трёх репозиториев:

| Репозиторий | Слой | Отвечает за |
|---|---|---|
| **labops-agent-architecture** (этот) | Рантайм / lifecycle | воркспейсы, память, watchdog, systemd, хуки, автоматизация роя, скилл `create-agent` |
| **labops-tg-plugin** | Канал | приём из Telegram (long-poll), отправка ответов/реакций, голос, webhook `:6000+` |
| **labops-second-brain** | Память | Postgres+pgvector, MCP memory/memory_router/agent_router/task, RBAC по Bearer-токенам |

---

## Быстрый старт

Остальное в README можно читать по мере надобности — для первого агента достаточно:

Это три **отдельных** скрипта `install.sh`, по одному на репозиторий — ни один не запускает установщик другого за вас. `install.sh` из `labops-agent-architecture` ставит только сам себя (зависимости + Claude Code) и **клонирует** (но не устанавливает) два соседних репозитория; их вы ставите каждый своим install.sh сами.

1. **Ставим этот репозиторий — одна команда делает всё для него:** `bash install.sh` — сначала устанавливает tmux/git/curl/jq/unzip (нужен root/sudo); если запущен от root, дальше предлагает создать отдельного непривилегированного пользователя (агенты работают через `--dangerously-skip-permissions`, под root это небезопасно — а системные пакеты к этому моменту уже стоят, так что остальной установке sudo не нужен) и перезапускает себя от его имени; затем устанавливает Claude Code (нативный установщик, Node.js не нужен), клонирует рядом `labops-tg-plugin`/`labops-second-brain` (не устанавливая их), прогоняет self-test, спрашивает авторизацию (`claude setup-token`, подписка Max/Pro), если вы ещё не входили, и создаёт Developer-агента: спросит имя/модель/Telegram-бота, всё развернёт и прогонит smoke (модель по умолчанию `opus`/Opus 4.8). Если соседние репо ещё не установлены — агент стартует в деградированном режиме, установщик подскажет, чего не хватает. Хотите создать агента позже сами? `bash install.sh --no-agent` останавливается прямо перед авторизацией/созданием агента.
2. **Ставим `labops-tg-plugin`** — свой репозиторий, свой `install.sh`: см. [его Quickstart](https://github.com/dediukhinpa/labops-tg-plugin#quickstart) (бот через BotFather, `channel.env`, `./install.sh`).
3. **Ставим `labops-second-brain`** — свой репозиторий, своя установка: см. [его Quickstart](https://github.com/dediukhinpa/labops-second-brain#quickstart) (вручную `scripts/install.sh`, либо отдать Claude Code агенту по `AGENT.md`).

> [!TIP]
> Для Developer модель по умолчанию `opus` (Opus 4.8). Вы ставите только первого агента — дальше рой растёт сам: Developer разворачивает остальных через скилл `create-agent`.

```bash
git clone https://github.com/dediukhinpa/labops-agent-architecture.git
cd labops-agent-architecture

# Одна команда: зависимости + self-test + авторизация (если нужна) +
# Developer-агент. Она ЖЕ клонирует (но не устанавливает) оба соседа —
# labops-tg-plugin -> ~/labops-tg-plugin, labops-second-brain -> ~/labops-second-brain —
# так что после неё на диске уже все три репо. Установка каждого соседа —
# отдельная команда из его же репозитория, шаги 2-3 выше.
bash install.sh   # модель → идентичность → скаффолд → бот → голос → токен → systemd → smoke
```

Все три репо оказываются на диске после блока выше (`git clone` — этот репо, `bash install.sh` — оба соседа). Но *устанавливает* он только себя — `labops-tg-plugin` и `labops-second-brain` всё ещё нужно поставить их собственными `install.sh` из `~/labops-tg-plugin` и `~/labops-second-brain` (шаги 2-3 выше, там же ссылки на их Quickstart). Если чего-то нет — установка честно перечислит, что **не** настроено (а не покажет ложный зелёный).

---

## Архитектура рантайма

Никто не запускает агентов «вручную» — всё держит **systemd**, и агент сам себя поднимает после любого падения. Страховка **вложенная**: systemd держит watchdog → watchdog держит tmux+claude → claude держит канал-сервер (bun). Падение на любом уровне лечится уровнем выше.

```mermaid
%%{init: {'theme':'base','themeVariables':{'primaryColor':'#EDE9FE','primaryTextColor':'#4C1D95','primaryBorderColor':'#8B5CF6','lineColor':'#8B5CF6','secondaryColor':'#F1F5F9','tertiaryColor':'#ffffff','clusterBkg':'transparent','clusterBorder':'#B794F4','fontFamily':'Helvetica,Arial,sans-serif'}}}%%
flowchart LR
  subgraph boot["Загрузка · надзор"]
    direction TB
    SD["systemd: claude-agent-&lt;agent&gt;.service<br/>Restart=on-failure, RestartSec=15"]
    WD["watchdog.sh &lt;agent&gt;<br/>вечный надзиратель (демон)"]
    SA["start-agent.sh &lt;agent&gt;<br/>подставляет env/секреты, создаёт сессию"]
    TM["tmux-сессия labops-&lt;agent&gt;"]
    SD -->|ExecStart| WD
    WD -->|если сессии нет / зависла| SA
    SA -->|tmux new-session| TM
  end
  subgraph live["Живой рантайм"]
    direction TB
    CC["claude (Claude Code CLI)<br/>--dangerously-skip-permissions<br/>server:labops-channel"]
    BUN["канал-сервер (bun, labops-tg-plugin)<br/>Telegram long-poll + webhook :6000+"]
    SB["second_brain MCP<br/>memory:5001 / memory_router:5002 / agent_router:5000"]
  end
  TM --> CC
  CC -->|spawn child, stdio MCP| BUN
  CC -->|HTTP + Bearer| SB
  BUN <-->|getUpdates / sendMessage| TG["Telegram (Оператор)"]
  classDef brand fill:#8B5CF6,stroke:#6D28D9,color:#ffffff,font-weight:bold
  classDef ext fill:#CCFBF1,stroke:#0D9488,color:#0F766E
  classDef store fill:#FEF3C7,stroke:#D97706,color:#92400E
  classDef sys fill:#E2E8F0,stroke:#334155,color:#1E293B
  linkStyle default stroke:#8B5CF6,stroke-width:1.5px
  class CC brand
  class SD,WD,SA,TM sys
  class BUN,SB,TG ext
```

**Цепочка запуска:**

1. **systemd** поднимает службу `claude-agent-<agent>.service` (одна на агента). Главный процесс службы — не `claude`, а `watchdog.sh`.
2. **`watchdog.sh <agent>`** — долгоживущий демон. Если tmux-сессии нет или панель зависла, зовёт `start-agent.sh`. Заодно «реапит» осиротевший канал-сервер (bun).
3. **`start-agent.sh <agent>`** читает секреты из `.claude/secrets/` (chmod 600, никогда не хардкодятся), подставляет env, создаёт tmux-сессию `labops-<agent>` и запускает в ней `claude … server:labops-channel`. Ждёт строку `Listening for channel` (до 30 c).
4. **`claude`** (движок) грузит канал-плагин, спавнит дочерний bun-процесс канала по stdio и подключает MCP second_brain по HTTP+Bearer.

### Модель живости (self-healing) в `watchdog.sh`

> [!NOTE]
> Watchdog снимает «хвост» панели tmux каждые ~30 c и классифицирует состояние. Единственный надёжный маркер «идёт ход» — футер **`esc to interrupt`**: Claude Code показывает его всё время хода и убирает в момент завершения. Строку с таймером (`Cooked for Ns`) использовать нельзя — она остаётся на экране после хода и в прошлом приводила к ложным рестартам простаивающего агента.

Два «тихих» режима сбоя, оба невидимы для наивной проверки промпта (зависший TUI всё ещё рисует `❯`):

| Режим | Признак | Реакция watchdog |
|---|---|---|
| **(A) Замёрзший ход** (frozen turn) | `esc to interrupt` присутствует, но панель байт-в-байт не меняется (таймер встал) | подтверждение через ~60 c (2 цикла) → рестарт сессии |
| **(B) Застрявший ввод** (stuck input) | в `❯` лежит неотправленный inbound, активного хода нет | эскалация: `Enter` → `Escape`+`Enter` (коммит bracketed-paste) → рестарт |
| Потерян промпт | TUI не рендерит ни `❯`, ни `bypass permissions`, ни `Listening for channel` | немедленный рестарт |
| Чистый idle-промпт | `❯` есть, поле ввода пустое | **не трогать** (здоровый агент) |

Режим (B) срабатывает **только** при непустом поле ввода — иначе чистый idle-промпт никогда не тревожится (это была главная причина «молчащих» агентов до фикса nbsp-парсинга `❯`). Отдельная защита — реапинг **осиротевшего bun**: если родительский `claude` умер, а канал-сервер «завис» с `PPID==1`, он на 2-ядерном боксе уходит в EPIPE-петлю на ~90 % CPU и душит живые сессии; watchdog/start-agent убивают его `pkill` строго по пути конкретного агента.

<details>
<summary><b>Три уровня самовосстановления</b></summary>

| Что чинит | Кто чинит | Как |
|---|---|---|
| зависшая / мёртвая сессия агента | `watchdog.sh` | детектит застывшую панель → `start-agent.sh` пересоздаёт сессию (`handoff.md` хранит последние события) |
| упавший watchdog | `systemd` | `Restart=on-failure` + `RestartSec=15` |
| осиротевший bun (claude умер, bun на PID 1) | `watchdog.sh` / `start-agent.sh` | `pkill -9` по пути агента |
| сервисы second_brain | `systemd` | отдельные службы `second_brain-*.service` |
| MCP-сервер / воркер завис или в crash-loop | `second_brain-monitor.sh` (systemd-таймер, ~60 с) | `systemctl is-active` + дельта рестартов + HTTP-проба `/mcp` (ловит *жив, но завис*) → Telegram-алерт на переходе down/up |

</details>

> [!NOTE]
> **Алерты оператору.** На каждое из этих событий watchdog ещё и пишет оператору в Telegram (через бота агента, `tg-send.sh` → `lib/notify.sh`): перезапуск сессии **с причиной**, потерянный/неотрисованный промпт, застрявший неотправленный промпт и подбор осиротевшего канал-сервера. Алерты best-effort (упавшая отправка никогда не ломает watchdog) и троттлятся по каждому сообщению, поэтому флаппинг не спамит. Включается через `WATCHDOG_TG_ALERTS` (по умолчанию `1`), окно троттлинга — `WATCHDOG_ALERT_COOLDOWN` (секунды, по умолчанию `300`), отдельный чат — `WATCHDOG_ALERT_CHAT_ID`. Тот же `lib/notify.sh` питает и **`second_brain-monitor.sh`** — systemd-таймер, который следит за MCP-серверами и воркерами (`systemctl is-active` + HTTP-проба `/mcp`, ловящая *жив, но завис*, + детект crash-loop) и алертит на тот же канал; укажи `MONITOR_AGENT` — агента, чей бот рассылает ops-алерты.

---

## Слои памяти агента

У агента четыре слоя памяти: первые три — локальные файлы в его воркспейсе (`@core/…`, частично всегда в контексте), четвёртый — общий мозг `labops-second-brain` по MCP. Иерархия истины: **live-проверка (exec/grep) → second_brain (общий мозг) → git-история → локальная память**. Память противоречит проверке — побеждает проверка.

```mermaid
%%{init: {'theme':'base','themeVariables':{'primaryColor':'#EDE9FE','primaryTextColor':'#4C1D95','primaryBorderColor':'#8B5CF6','lineColor':'#8B5CF6','secondaryColor':'#F1F5F9','tertiaryColor':'#ffffff','clusterBkg':'transparent','clusterBorder':'#B794F4','fontFamily':'Helvetica,Arial,sans-serif'}}}%%
flowchart LR
  subgraph local["Локальная память агента (файлы воркспейса)"]
    L1["L1 IDENTITY<br/>CLAUDE.md · rules.md · USER.md<br/>(всегда в контексте)"]
    L2["L2 HOT<br/>hot/recent.md (24h) · hot/handoff.md<br/>(handoff кладёт boot-хук)"]
    L3["L3 WARM<br/>warm/decisions.md (ротация >14д → COLD)<br/>COLD: MEMORY.md · LEARNINGS.md (по запросу)"]
  end
  L4["L4 ОБЩИЙ МОЗГ<br/>labops-second-brain · memory_router/memory/agent_router по MCP"]
  L1 --> L2 --> L3 --> L4
  classDef brand fill:#8B5CF6,stroke:#6D28D9,color:#ffffff,font-weight:bold
  classDef ext fill:#CCFBF1,stroke:#0D9488,color:#0F766E
  classDef store fill:#FEF3C7,stroke:#D97706,color:#92400E
  classDef sys fill:#E2E8F0,stroke:#334155,color:#1E293B
  linkStyle default stroke:#8B5CF6,stroke-width:1.5px
  class L4 brand
  class L1,L2,L3 sys
```

| Слой | Файлы / источник | В контексте | Кто правит |
|---|---|---|---|
| **L1 Идентичность** | `CLAUDE.md`, `rules.md`, `USER.md` | всегда (`@import`) | только оператор (RED-зона) |
| **L2 Hot** | `hot/recent.md` (скользящие 24 ч), `hot/handoff.md` | да (handoff кладёт boot-хук) | агент автономно (GREEN) |
| **L3 Warm** | `warm/decisions.md` (последние ~14 д, ротация в COLD) | да | агент с обоснованием (YELLOW) |
| **COLD** | `MEMORY.md`, `LEARNINGS.md` | нет — по запросу (Read) | агент (GREEN) |
| **L4 Общий** | second_brain `memory_router` / `memory` / `agent_router` | нет — по запросу (MCP) | по RBAC-scopes |

Зоны доступа к файлам: **RED** (`CLAUDE.md`, `rules.md`, `USER.md`) — только оператор; **YELLOW** (`decisions.md`, `AGENTS.md`, `TOOLS.md`) — агент с обоснованием; **GREEN** (`LEARNINGS.md`, `hot/recent.md`, `feedback_*`) — агент автономно.

**Политика записи в общий мозг** зафиксирована в [`SECONDBRAIN_WRITE_RULES.md`](SECONDBRAIN_WRITE_RULES.md) — это единый canonical-файл (RED-зона), который симлинкуется в `core/` каждого агента и **@-импортится в его `CLAUDE.md`** (`@core/SECONDBRAIN_WRITE_RULES.md`). Правишь один файл → подхватывают все агенты. Четыре дисциплины: (1) `recall` **перед** записью — не плодить дубли; (2) **dual-write** важного — и в локальный `.md`, и в second_brain (идемпотентно по sha256); (3) писать **сразу**, не «потом» (компакция знания не выгружает); (4) писать в свой `scope`. Инструменты записи жёстко зафиксированы кодом: `create_decision_note`, `create_error_pattern_note`, `create_external_note`, `create_personal_note` (→ `personal`), `create_project_note` (→ `projects`), `create_handoff`, `append_daily_log`, `supersede_decision`.

---

## agent-template — скаффолдер

[`agent-template/`](agent-template/) — полный шаблон воркспейса Claude Code, проводнённый к общему `labops-second-brain` (memory + memory_router + agent_router). Интерактивный `install.sh` спрашивает идентичность агента и параметры подключения к мозгу, рендерит шаблоны и собирает воркспейс в `~/.claude-lab/<agent-id>/.claude/`.

**Промпты при скаффолде** (попадают в плейсхолдеры `CLAUDE.md`): имя (`{{AGENT_NAME}}`), роль (`{{AGENT_ROLE}}` / `{{AGENT_ROLE_DESCRIPTION}}`), характер (`{{CHARACTER_TRAITS}}`), как обращаться к оператору, язык ответов, модель; плюс параметры мозга — `MCP_HOST` (только хост/IP), `AGENT_BEARER`, `AGENT_SCOPES`. Три переменные per-service (`SECOND_BRAIN_MEMORY_URL`, `SECOND_BRAIN_MEMORY_ROUTER_URL`, `SECOND_BRAIN_AGENT_ROUTER_URL`) выводятся автоматически из `MCP_HOST`, но могут быть переопределены напрямую.

**Что генерируется:**

```
~/.claude-lab/<agent-id>/.claude/
├── CLAUDE.md            # SOUL / идентичность (из templates/CLAUDE.md.template)
├── .mcp.json            # ТОЛЬКО 3 сервера second_brain (memory/memory_router/agent_router), chmod 600
├── settings.json        # хуки SessionStart / Stop / PreCompact
├── agent.env            # source перед запуском: MCP_HOST / SECOND_BRAIN_*_URL / AGENT_BEARER
├── core/
│   ├── USER.md · rules.md · AGENTS.md · MEMORY.md · LEARNINGS.md
│   ├── warm/decisions.md           # WARM (последние 14д)
│   └── hot/{recent.md, handoff.md, archive/, pre-compact/}
├── tools/TOOLS.md
├── scripts/             # ротация памяти + second_brain-memory_router-on-start
├── hooks/               # session-start, stop, precompact
├── logs/
└── skills/              # симлинк на общий бандл скиллов
```

| Каталог шаблона | Содержимое |
|---|---|
| `templates/` | `CLAUDE.md`, `rules.md`, `USER.md`, `tools.md`, `agents.md`, `decisions.md`, `recent.md`, `MEMORY.md`, `LEARNINGS.md`, `mcp.json`, `settings.json` |
| `hooks/` | `session-start-hook.sh`, `stop-hook.sh`, `precompact-hook.sh` |
| `scripts/` | `memory-rotate.sh`, `trim-hot.sh`, `rotate-warm.sh`, `compress-warm.sh`, `second_brain-memory_router-on-start.sh` |
| `docs/` | `ARCHITECTURE.md`, `MEMORY.md`, `HOOKS.md`, `MULTI-AGENT.md`, `SETUP-GUIDE.md`, `AGENT-LAWS.md`, … (16 файлов) |

Важно: `mcp.json.template` подключает агенту **только** second_brain (3 сервера). Канал (`labops-channel`) грузится отдельно при запуске через `claude … server:labops-channel`, а task-board MCP (`:5003`) агентам намеренно **не** заводится (heartbeat идёт отдельным кроном).

---

## Скилл `create-agent` (end-to-end)

> Лежит в `skills/create-agent/`. Это **ядро репозитория** — то, чем первый агент (Developer) разворачивает остальных. Описание ниже — целевое поведение скилла; он авторится параллельно лидом.

Когда Оператору нужен новый агент, он просит об этом Developer-агента в Telegram. Тот запускает скилл `create-agent`, который проводит развёртывание целиком — от диалога о роли до прошедшего smoke-теста — не требуя ручных шагов от оператора.

```mermaid
%%{init: {'theme':'base','themeVariables':{'primaryColor':'#EDE9FE','primaryTextColor':'#4C1D95','primaryBorderColor':'#8B5CF6','lineColor':'#8B5CF6','secondaryColor':'#F1F5F9','tertiaryColor':'#ffffff','clusterBkg':'transparent','clusterBorder':'#B794F4','fontFamily':'Helvetica,Arial,sans-serif'}}}%%
flowchart LR
  subgraph c1["Определить · скаффолд"]
    direction TB
    S1["1. Диалог: роль и имя<br/>(чем агент занимается, как зовётся)"]
    S2["2. Идентичность: провести по CLAUDE.md / rules.md<br/>(характер, зоны, принципы)"]
    S3["3. Скаффолд воркспейса<br/>agent-template → ~/.claude-lab/&lt;agent&gt;/.claude"]
    S4["4. Telegram-бот<br/>@BotFather → токен → channel.env"]
    S1 --> S2 --> S3 --> S4
  end
  subgraph c2["Провижн · проверка"]
    direction TB
    S5["5. Голос<br/>скилл groq-voice (GROQ_API_KEY)"]
    S6["6. second_brain-токен<br/>Bearer + scopes от labops-second-brain"]
    S7["7. Автозапуск<br/>systemd-юнит + watchdog"]
    S8["8. Smoke-тест<br/>проверка канала, memory_router, agent_router, реакций"]
    S5 --> S6 --> S7 --> S8
  end
  S4 --> S5
  classDef brand fill:#8B5CF6,stroke:#6D28D9,color:#ffffff,font-weight:bold
  classDef ext fill:#CCFBF1,stroke:#0D9488,color:#0F766E
  classDef store fill:#FEF3C7,stroke:#D97706,color:#92400E
  classDef sys fill:#E2E8F0,stroke:#334155,color:#1E293B
  linkStyle default stroke:#8B5CF6,stroke-width:1.5px
  class S1 brand
  class S4,S5,S6 ext
  class S7 sys
```

| Шаг | Что делает | Артефакт |
|---|---|---|
| 1. Роль и имя | спрашивает у Оператора роль (кодер / контент / ресёрч / …) и `<agent-id>` | — |
| 2. Идентичность | проводит по `CLAUDE.md` (SOUL, характер, принципы) и `rules.md` | заполненные RED-файлы |
| 3. Скаффолд | прогоняет `agent-template` → рендерит шаблоны | `~/.claude-lab/<agent>/.claude/` |
| 4. Telegram-бот | регистрирует бота через `@BotFather`, пишет токен | `channel.env` (`/etc/labops-plugin/<agent>/` или `shared/state/<agent>/telegram/`) |
| 5. Голос | подключает скилл `groq-voice` (транскрипция `.ogg`) | `GROQ_API_KEY` в секретах |
| 6. Токен мозга | запрашивает у `labops-second-brain` Bearer + `scopes` | `.mcp.json` (chmod 600) |
| 7. Автозапуск | ставит `claude-agent-<agent>.service` + watchdog, добавляет в roster | юнит + строка в `agents.conf` |
| 8. Smoke-тест | финальная проверка: канал слушает, memory_router/agent_router отвечают, реакции ставятся | зелёный прогон |

Токен Telegram-бота извлекается **не из хардкода**, а из `channel.env` через `orchestration/lib/agents.sh::agent_bot_token` (ищет `/etc/labops-plugin/<agent>/channel.env`, затем `$CLAUDE_LAB/shared/state/<agent>/telegram/channel.env`).

---

## Хуки жизненного цикла и автоматизация роя

### Хуки жизненного цикла

Хук — **не сервер**: движок Claude Code в определённый момент испускает событие, читает `settings.json`, спавнит команду как дочерний процесс (на stdin — JSON с путём к транскрипту и `session_id`), скрипт отрабатывает за миллисекунды-секунды и выходит. Все три хука **fail-open**: любая ошибка → `exit 0`, харнесс никогда не подвисает. Подробнее о загрузке `settings.json` — в `labops-tg-plugin/docs/06`.

| Событие | Хук (`agent-template/hooks/`) | Что делает |
|---|---|---|
| **SessionStart** | `session-start-hook.sh` | логирует старт; если есть `SECOND_BRAIN_MEMORY_ROUTER_URL`+`AGENT_BEARER` — зовёт `second_brain-memory_router-on-start.sh` (дописывает блок релевантных recall в `hot/recent.md`); surface `handoff.md`. В рое также `agent-boot-sequence.sh`: 👀 на свежие сообщения + `agent_router.list_my_pending()` (забрать делегированные задачи — pull-страховка) |
| **Stop** | `stop-hook.sh` | дописывает 200-символьный сниппет хода в `hot/recent.md` и подробную JSON-строку в `logs/verbose-YYYY-MM-DD.jsonl`. В рое также `read-receipt-hook.ts` (POST `/hooks/react` → 👌) и `reflect-error-pattern.sh` (если Оператор поправил → нудж записать error-pattern через `decision:"block"`) |
| **PreCompact** | `precompact-hook.sh` | снапшотит `hot/recent.md` в `hot/pre-compact/` перед авто-компакцией, держит последние `KEEP_SNAPSHOTS` (10) |

Все хуки несут `sdk-guard`: при `CLAUDE_SDK_CHILD=1` (или `entrypoint=sdk-ts`) сразу выходят, чтобы не зацикливаться в дочерних Agent-SDK-сессиях.

### Автоматизация роя

Скрипты в [`orchestration/`](orchestration/) — это «однодневки» по триггеру (cron / событие), а не постоянные процессы. Roster агентов берётся через `orchestration/lib/agents.sh::list_agents` — **не хардкодом**: сначала `$CLAUDE_LAB/agents.conf` (по строке на agent-id, см. `agents.conf.example`), иначе скан `$CLAUDE_LAB/*/.claude` с исключением инфра-каталогов (`shared`, `logs`, `mcp-servers`).

<details>
<summary><b>Скрипты оркестрации</b></summary>

| Скрипт | Триггер | Назначение |
|---|---|---|
| `heartbeat-all.sh` | cron, раз в минуту | heartbeat только живых tmux-сессий → супервизор отличает живых агентов от мёртвых (у мёртвых `last_seen` устаревает, их задачи реклеймятся) |
| `night-learnings.sh` | cron, 02:00 UTC | ночной learnings-цикл: `agent_router.notify` каждому → review 7-дневных learnings → обновить `rules.md` |
| `message-reaction-daemon.sh` | фоновый демон на агента | ставит 👀 на **все** входящие (текст/голос/стикеры) немедленно, опрос каждые ~3 c |
| `start-reaction-daemons.sh` | `@reboot` | поднимает reaction-демоны для всех агентов roster, с PID-файлами |
| `set-message-reaction.sh` / `handle-incoming-messages.sh` | вспомогательные | примитивы реакций и обработки входящих |
| `vault-audit-broadcast.sh` + `second_brain-vault-audit.sh` | по запросу / cron | рассылает рою задачу проверить и дозаполнить общий vault |
| `agent-boot-sequence.sh` | SessionStart | детерминированно забирает делегированные задачи (`list_my_pending`) |
| `reflect-error-pattern.sh` | Stop | нудж записать error-pattern при коррекции от Оператора |
| `update-rules.sh`, `tg-send.sh`, `second_brain-heartbeat.py` | вспомогательные | обновление правил, отправка в TG, heartbeat-клиент |

</details>

**Двухстадийные реакции (2026-06-25):** 👀 «получил» — мгновенно при приёме (≈1 c, fire-and-forget) и 👌 «готово» — в конце хода (read-receipt-хук). Два эмодзи = два смысла, сигнал не «врёт» на занятой сессии. `✅` намеренно не используется — его нет в whitelist реакций Telegram-ботов.

---

## Скиллы в комплекте

Бандл в [`skills/`](skills/) ставится симлинком в `~/.claude/skills/<name>` или пер-агентно. Скиллы независимы и не зависят от second_brain.

| Скилл | Что делает | Нужно |
|---|---|---|
| `groq-voice` | транскрипция голосовых `.ogg` через Groq Whisper (обязательно при `<media:audio>`) | `GROQ_API_KEY` |
| `second_brain-doctor` | агент-сайд-диагностика second_brain: коннект, identity, memory_router, agent_router, hooks-parity, webhooks, repo, безопасность MCP-URL; вывод редактируется (секреты маскируются) | — |
| `mcp-builder` | гайд (от Anthropic) по созданию новых MCP-серверов (FastMCP / TS SDK) | — |
| `markdown-new` | чистый Markdown из любого URL через `markdown.new` (замена шумному web_fetch, ~80 % экономии токенов) | — |
| `transcript` | транскрипты YouTube через TranscriptAPI.com | `TRANSCRIPT_API_KEY` |
| `agent-browser` | браузерная автоматизация через CDP (навигация, формы, скриншоты) | бинарь `agent-browser` |

---

## Установка и модель/авторизация

> `install.sh` в корне репозитория авторится параллельно лидом; ниже — его целевое поведение.

Корневой `install.sh` ставит **только сам репозиторий** — базовые зависимости, Claude Code, клонирование (не установку) двух соседних репо — и в одном и том же запуске, если нужно, авторизует и вызывает `skills/create-agent/new-agent.sh`, который скаффолдит **первого агента — Developer / Разработчик** «под ключ» end-to-end, прогоняя тесты/smoke в конце. Соседей можно ставить до или после — порядок не важен, установщик просто подскажет, чего ещё не хватает. Внутри он использует те же примитивы, что и скилл `create-agent`: скаффолд через `agent-template`, регистрация бота, голос, second_brain-токен, systemd-автозапуск.

**Зависимости (скрипт их устанавливает):**

- **Отдельный OS-пользователь** — если `install.sh` запущен от root, после установки системных пакетов (нужен root/sudo) он предлагает создать непривилегированного пользователя (имя выбираете сами — жёсткого дефолта нет) и продолжает установку уже от его имени; агенты работают через `claude --dangerously-skip-permissions` (без подтверждения каждого действия) — держать их под root небезопасно. Пароль задаётся интерактивно через `passwd` (нужен вам для `su`/SSH, самому агенту не требуется). Пропустить: `SKIP_USER_SETUP=1`.
- **Claude Code** — устанавливается самим `install.sh` через нативный установщик (без Node.js/npm); затем **разово авторизоваться по подписке**: `install.sh` сам запускает `claude setup-token` (Max/Pro, первая сторона — без third-party риска) прямо перед созданием первого агента, если вы ещё не входили. Модель агента задаётся в `settings.json` (поле `model`); диалог `create-agent` спрашивает её и для Developer рекомендует **`opus` (Opus 4.8)**. Без авторизации агент стартует под systemd, но не достучится до модели — это ловит smoke-тест (шаг «модель отвечает»).
- **`labops-tg-plugin`** — клонируется в `~/labops-tg-plugin` скриптом `install.sh`; ставите сами своей командой `cd ~/labops-tg-plugin && ./install.sh` (сразу после настройки бота через @BotFather) — это канал, через который агент общается в Telegram. Если создать Developer-агента раньше этого шага, он стартует в деградированном режиме, пока этот репо не установлен.
- **`labops-second-brain`** — клонируется в `~/labops-second-brain` скриптом `install.sh`; ставите сами — либо запустив напрямую `sudo bash ~/labops-second-brain/scripts/install.sh`, либо отдав Claude Code агенту (`cd ~/labops-second-brain && claude`, затем вставьте промпт из шага 3 «Быстрого старта» — он следует `AGENT.md` и спрашивает подтверждение на разрушительных шагах) — выдаёт агенту Bearer-токен и поднимает MCP `memory`/`memory_router`/`agent_router`.

> [!IMPORTANT]
> **Модель и авторизация.** Разово войдите через `claude setup-token` (подписка Max/Pro, первая сторона — без third-party риска). Модель агента задаётся в `settings.json` (поле `model`); для Developer рекомендуется `opus` (Opus 4.8). Без авторизации агент стартует, но не достучится до модели.

```bash
git clone https://github.com/dediukhinpa/labops-agent-architecture.git
cd labops-agent-architecture

# Одна команда: зависимости + self-test + авторизация (если нужна) +
# Developer-агент. Она ЖЕ клонирует (но не устанавливает) обоих соседей —
# labops-tg-plugin -> ~/labops-tg-plugin, labops-second-brain -> ~/labops-second-brain.
bash install.sh   # модель → идентичность → скаффолд → бот → голос → токен → systemd → smoke
```

Все три репо оказываются на диске после блока выше (`git clone` — этот репо, `bash install.sh` — оба соседа) — но *устанавливает* он только себя. Соседей ставим сами, каждого из его репозитория — ссылки на их установку в шагах 2-3 «Быстрого старта» выше.

Скаффолд одного воркспейса без полного развёртывания — через `agent-template/install.sh` (см. [`agent-template/README.md`](agent-template/README.md)).

### Тесты

- **Синтаксис-чек bash** — `bash -n` по всем скриптам `orchestration/*.sh`, `agent-template/hooks/*.sh`, `agent-template/scripts/*.sh` (хуки fail-open, поэтому статической проверки + smoke достаточно).
- **Self-test репозитория** (`test.sh`) — синтаксис bash, компиляция python, отсутствие секретов и проверка, что модель/авторизация учтены (`settings.json` задаёт `model`, `create-agent` пробрасывает выбор модели, есть шаг `claude setup-token`).
- **Smoke-тест** в конце `install.sh` / `create-agent`: **модель отвечает** (Claude Code авторизован, `claude -p ping`); сессия агента дошла до `Listening for channel`; канал отвечает; `memory_router`/`agent_router` доступны по Bearer; реакции 👀/👌 ставятся.
- **`second_brain-doctor`** (скилл) — повторяемая агент-сайд-диагностика связки second_brain после установки.

```bash
# Синтаксис всех bash-скриптов
find orchestration agent-template -name '*.sh' -exec bash -n {} \;

# Перезапуск self-test без установки агента
bash install.sh --test-only
```

---

## Переменные и настройки

<details>
<summary><b>Переменные окружения и настройки</b></summary>

| Переменная | Где | Назначение |
|---|---|---|
| `MCP_HOST` | `agent.env` | только хост/IP, без протокола и порта (например, `127.0.0.1`); используется для вывода трёх `SECOND_BRAIN_*_URL` по умолчанию |
| `SECOND_BRAIN_MEMORY_URL` | `.mcp.json`, `agent.env` | полный URL memory `/mcp` (по умолчанию `http://${MCP_HOST}:5001/mcp`); можно переопределить, если сервер за своим reverse proxy |
| `SECOND_BRAIN_MEMORY_ROUTER_URL` | `.mcp.json`, `agent.env` | полный URL memory_router `/mcp` (по умолчанию `http://${MCP_HOST}:5002/mcp`) |
| `SECOND_BRAIN_AGENT_ROUTER_URL` | `.mcp.json`, `agent.env` | полный URL agent_router `/mcp` (по умолчанию `http://${MCP_HOST}:5000/mcp`) |
| `AGENT_BEARER` | `.mcp.json` (chmod 600) | Bearer-токен агента для MCP (в БД хранится только `token_sha256`) |
| `AGENT_SCOPES` | install | RBAC-scopes на чтение/запись (scope = первая папка пути в vault) |
| `CLAUDE_LAB` | окружение | корень лаборатории (по умолчанию `$HOME/.claude-lab`); roster и токены ищутся относительно него |
| `GROQ_API_KEY` | `.claude/secrets/groq-api-key` | транскрипция голоса (Groq Whisper) |
| `TELEGRAM_BOT_TOKEN` | `.claude/secrets/telegram-bot-token`, `channel.env` | токен бота агента (`@BotFather`) |
| `TELEGRAM_WEBHOOK_TOKEN` | `.claude/secrets/telegram-webhook-token` | Bearer для входящих POST на `/hooks/*` |
| `TELEGRAM_WEBHOOK_PORT` | `start-agent.sh` (config, не секрет) | порт webhook агента (`:6000+`, по агенту) |
| `TELEGRAM_ALLOWED_USER_IDS` | `start-agent.sh` | allowlist собеседников — только Оператор; чужие отбрасываются на гейте |
| `TELEGRAM_STATE_DIR` | `start-agent.sh` | `~/.claude/channels/labops-<agent>` — состояние канала |
| `TELEGRAM_WORKSPACE_ROOT` | `start-agent.sh` | корень для вложений (защита от path-traversal) |
| `CLAUDE_CODE_AUTO_COMPACT_WINDOW` | `settings.json` | окно авто-компакции (400000) |
| `KEEP_SNAPSHOTS` | `precompact-hook.sh` | сколько pre-compact снапшотов держать (10) |
| `CLAUDE_SDK_CHILD` | окружение | `=1` → хуки выходят сразу (anti-recursion для Agent SDK) |
| `WATCHDOG_TG_ALERTS` | env `watchdog.sh` | `=1` (по умолчанию) → алерты оператору в Telegram при рестарте/потере/застревании/осиротении; `0` выключает |
| `WATCHDOG_ALERT_COOLDOWN` | env `watchdog.sh` | окно троттлинга по сообщению, секунды (по умолчанию `300`) — чтобы флаппинг не спамил |
| `WATCHDOG_ALERT_CHAT_ID` | env `watchdog.sh` / `second_brain-monitor.sh` | отдельный чат для алертов; по умолчанию — чат оператора из `channel.env` |
| `MONITOR_AGENT` | env `second_brain-monitor.sh` | агент, чей бот рассылает backend-алерты (по умолчанию — первый агент из ростера) |
| `MONITOR_COMPONENTS` | env `second_brain-monitor.sh` | список `key\|unit\|port` через пробел (по умолчанию 5 юнитов, что включает install; добавь `task\|second_brain-task-mcp\|5003`, если включён) |

> [!WARNING]
> Секреты лежат в `~/.claude-lab/<agent>/.claude/secrets/` с `chmod 600` и **никогда не хардкодятся** в скриптах; `start-agent.sh` падает быстро, если секрет отсутствует/нечитаем.

</details>

---

## Если что-то не работает

Зелёный smoke означает: воркспейс создан, мозг отвечает по Bearer, токен бота валиден (`getMe`), модель отвечает, сервис `active`. Он **не** доказывает, что вы написали боту с разрешённого `user_id`. Частые случаи:

<details>
<summary><b>Симптомы и что делать</b></summary>

| Симптом | Где смотреть / что делать |
|---|---|
| Бот молчит в Telegram | `tmux ls` → есть ли `labops-<agent>`? `tmux attach -t labops-<agent>` — видно ошибку. Проверьте, что ваш `user_id` в `TELEGRAM_ALLOWED_USER_IDS` (`channel.env`). |
| Сервис не `active` | `systemctl status claude-agent-<agent>` + `journalctl -u claude-agent-<agent> -n50`. Частая причина — `claude` не авторизован (`claude setup-token`) или нет `channel.env`. |
| `no TELEGRAM_BOT_TOKEN` в логе | `channel.env` не там, где ищет `start-agent.sh` — он берёт из `lib/agents.sh` (`/etc/labops-plugin/<agent>/` или `$CLAUDE_LAB/shared/state/<agent>/telegram/`). Пересоздайте через `new-agent.sh`. |
| «Модель не ответила» | `claude setup-token` под пользователем агента, затем `systemctl restart claude-agent-<agent>`. |
| `second_brain недоступен` | Проверьте `SECOND_BRAIN_MEMORY_URL` / `SECOND_BRAIN_MEMORY_ROUTER_URL` / `SECOND_BRAIN_AGENT_ROUTER_URL` в `agent.env` (по умолчанию `http://127.0.0.1:5001/mcp` и т.д.) и что мозг поднят. `MCP_HOST` — только хост/IP; `SECOND_BRAIN_*_URL` — полные URL эндпоинтов. |
| Повторный запуск/коллизия имени | `new-agent.sh` не затирает существующего агента; для донастройки поверх — `REUSE_EXISTING=1`. |

</details>

---

## FAQ

<details>
<summary><b>Нужно ли ставить каждого агента вручную?</b></summary>

Нет. Вы ставите только первого агента — Developer — командой `bash install.sh`. Дальше рой растёт сам: вы просите Developer-агента в Telegram о новом агенте, и он прогоняет скилл `create-agent` end-to-end (скаффолд → бот → голос → токен → systemd → smoke).

</details>

<details>
<summary><b>Работает ли это на macOS?</b></summary>

Частично. Рантайм нацелен на Linux + systemd + tmux. На macOS / без systemd агента можно гонять вручную в tmux, но не как службу — нет автозапуска и самовосстановления.

</details>

<details>
<summary><b>Какую модель использует Developer и как авторизоваться?</b></summary>

Модель агента задаётся в `settings.json` (поле `model`). Диалог установки спрашивает её и для Developer рекомендует `opus` (Opus 4.8). Авторизация — разовый `claude setup-token` по подписке Max/Pro (первая сторона, без third-party риска). Без неё агент стартует под systemd, но не достучится до модели — это ловит smoke-тест.

</details>

<details>
<summary><b>Где хранятся токены и секреты?</b></summary>

Секреты лежат в `~/.claude-lab/<agent>/.claude/secrets/` с `chmod 600` и никогда не хардкодятся. Токен Telegram-бота читается из `channel.env` через `orchestration/lib/agents.sh::agent_bot_token`. В БД second_brain хранит только `token_sha256`, не сырой Bearer.

</details>

<details>
<summary><b>Как агент переживает падение?</b></summary>

Самовосстановление вложенное: systemd держит watchdog (`Restart=on-failure`, `RestartSec=15`), watchdog детектит зависшую/мёртвую tmux-панель и заставляет `start-agent.sh` пересоздать сессию, а осиротевший канал-сервер (bun на PID 1) реапится по пути. `handoff.md` переносит последние события через рестарт.

</details>

---

## Данные и приватность

Self-hosted by design: агенты работают на собственном Linux-сервере оператора, `second_brain` (Postgres + vault) локальный, телеметрии нет. Единственный исходящий трафик идёт к AI / мессенджер-провайдерам, которых настроил оператор.

| Endpoint | Назначение | Когда | Опционально |
|---|---|---|---|
| `api.anthropic.com` (через движок Claude Code) | инференс LLM — модель, на которой работает агент | пока агент активен | нет (ядро) |
| `api.telegram.org` | ввод-вывод чата — приём и отправка сообщений | во время работы | нет |
| `api.groq.com` | транскрипция / синтез голоса | только на голосовых сообщениях | да (опционально) |
| `second_brain` (`localhost` MCP, Postgres + vault) | память диалога и состояние | всегда | локально — не покидает хост |

> [!IMPORTANT]
> Память диалога и состояние хранятся в локальном `second_brain` (Postgres + vault) на хосте оператора. Наружу уходит только трафик промптов / ответов к настроенным AI-провайдерам — это необходимо для работы любого LLM-агента.

Секреты лежат в `channel.env` / `.claude/secrets` (`chmod 600`) и никогда не коммитятся.

---

## Часть системы labops

| Репозиторий | Слой | Что предоставляет |
|---|---|---|
| **labops-agent-architecture** (этот) | рантайм / lifecycle | воркспейсы, память, watchdog/systemd, хуки, автоматизация роя, `create-agent` |
| **[labops-tg-plugin](https://github.com/dediukhinpa/labops-tg-plugin)** | канал | пер-агентный Telegram-бот, голос, реакции, webhook `:6000+`, MCP-инструменты канала (`reply`/`react`/…) |
| **[labops-second-brain](https://github.com/dediukhinpa/labops-second-brain)** | память | Postgres+pgvector, MCP `memory:5001` / `memory_router:5002` / `agent_router:5000` / `task:5003`, RBAC по Bearer |

---

## Лицензия

Проприетарная (Proprietary) — © 2026 LabOps.ai. Все права защищены. См. [LICENSE](./LICENSE).
