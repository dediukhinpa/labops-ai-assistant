<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/labops-logo-dark.svg">
    <img src="assets/labops-logo.svg" alt="LabOps.ai" width="280">
  </picture>
</p>

<h1 align="center">labops-tg-plugin</h1>

<p align="center"><em>операционка с AI изнутри профессии</em></p>

<p align="center">
  <a href="https://labopsai.pro"><img src="https://img.shields.io/badge/%F0%9F%8C%90%20labopsai.pro-6E56CF?style=for-the-badge" alt="labopsai.pro"></a>
  <a href="./LICENSE"><img src="https://img.shields.io/badge/License-Proprietary-CC2B2B?style=for-the-badge" alt="License: Proprietary"></a>
  <img src="https://img.shields.io/badge/Built%20by-LabOps.ai-111111?style=for-the-badge" alt="Built by LabOps.ai">
</p>

<p align="center"><a href="README.md">English</a> · <a href="README.ru.md"><b>Русский</b></a></p>

<p align="center">
  <b>Система labops:</b>
  <b>tg-plugin</b> ·
  <a href="https://github.com/dediukhinpa/labops-second-brain">second-brain</a> ·
  <a href="../agent-architecture">agent-architecture</a>
</p>

<p align="center">
  <img src="assets/demo.ru.svg" alt="Демо: Telegram-чат — приём → 👀 → ответ → 👌" width="560">
</p>
<p align="center"><sub><i>Иллюстративный мокап двухстадийных реакций (👀 получил → 👌 готово) — это не запись экрана.</i></sub></p>

---

## Что это

Плагин Claude Code (runtime на [Bun](https://bun.sh), язык TypeScript), который превращает обычную сессию `claude` в **долгоживущего Telegram-агента**: ваш агент живёт постоянной сессией на сервере и общается с вами в Telegram — текстом, голосом, с медиа, реакциями статуса и интерактивными кнопками. Он регистрируется как **MCP-сервер внутри живой сессии Claude Code**, поэтому Telegram — это просто канал ввода/вывода: тот же контекст, память и инструменты, что у вас уже есть, а не новый headless-процесс на каждое сообщение. Часть архитектуры **labops** (см. также [`labops-second-brain`](#часть-labops) и [`agent-architecture`](#часть-labops)).

---

## Быстрый старт

**Требования:** не нужны — `install.sh` автоматически доустанавливает `bun ≥ 1.3`, `tmux`,
`claude ≥ v2.1.80`, если чего-то нет.

**Встроен в монорепозиторий `labops-ai-assistant`.** Этот плагин — встроенный компонент (`tg-plugin/`) рядом с [`agent-architecture`](../agent-architecture). **Единый корневой `install.sh`** (в корне монорепозитория) ставит его за вас в рамках общей установки — собственный `install.sh` компонента руками не запускаете (корневой сам его вызывает, а он остаётся доступен в `tg-plugin/`, если вдруг понадобится напрямую). BotFather, токен бота и `channel.env` каждого агента создаёт интерактивно `skills/create-agent/new-agent.sh` из `agent-architecture` — отдельно на агента; он же сам раскладывает встроенный плагин в воркспейс каждого нового агента (`~/.claude-lab/<agent>/.claude/labops-tg-plugin`) — **приватной копией**, а не симлинком (общим остаётся только `node_modules`), поэтому правка в монорепозитории не доезжает до живого агента, пока плагин не переразложат. Просто выполните из корня монорепозитория:

```bash
bash install.sh
```

**Ставите плагин отдельно** (вне монорепозитория, без общей памяти)? Он по-прежнему может работать сам по себе — но внутри этого репозитория корневой `install.sh` выше и есть правильный путь. Для полностью отдельной установки каталога `~/.claude-lab/<agent>/` тут нет и не будет — это собственное соглашение `agent-architecture`. Клонируйте внутрь **папки `.claude` вашего собственного workspace** — там, где уже лежит (или будет лежать) `CLAUDE.md` этого агента: корень проекта, либо просто домашняя директория, если агент один и глобальный. Claude Code ищет `CLAUDE.md`, поднимаясь вверх от рабочего каталога плагина — поэтому плагин должен лежать внутри того же дерева, см. [`docs/02-where-to-place-plugin.md`](docs/02-where-to-place-plugin.md). Настройте вручную:

1. Создайте бота у [@BotFather](https://t.me/BotFather) → получите токен; свой user_id — у [@userinfobot](https://t.me/userinfobot) — пошагово в [`docs/telegram-setup.md`](docs/telegram-setup.md).
2. Заполните `channel.env` минимальными переменными:
   - `TELEGRAM_BOT_TOKEN` — токен от BotFather
   - `TELEGRAM_EXPECTED_BOT_ID` — число до `:` в токене (anti-spoof)
   - `TELEGRAM_ALLOWED_USER_IDS` — CSV разрешённых user_id
   - `TELEGRAM_ALLOWED_CHAT_IDS` — CSV разрешённых chat_id
   - `TELEGRAM_WORKSPACE_ROOT` — корень workspace агента
   - `TELEGRAM_STATE_DIR` — state-каталог агента
3. Запустите `./install.sh` (ставит зависимости и хуки, затем прогоняет тесты).

```bash
# Клонировать ВНУТРЬ папки .claude вашего workspace (расположение критично —
# см. docs/02). <your-workspace> — там, где лежит CLAUDE.md этого агента:
# корень проекта, либо $HOME для одного глобального агента.
git clone <this-repo> <your-workspace>/.claude/labops-tg-plugin
cd <your-workspace>/.claude/labops-tg-plugin
./install.sh
```

> [!TIP]
> Входящие сообщения тянутся **long-poll PULL** (`getUpdates`) — **публичный IP/домен/TLS не нужны**.

> [!IMPORTANT]
> «webhook-server» — это внутренний `127.0.0.1` для маршрутизации хуков Claude Code, **не** Telegram-webhook.

По умолчанию режим **один агент, только личные DM**; multichat (несколько чатов/групп) — **opt-in**.

> [!NOTE]
> **Платформа:** целевая — **Linux + systemd**; на macOS/без systemd можно запустить вручную, но не как сервис.

---

## Чем это отличается от «бота поверх API»

Наивный Telegram-бот для LLM на каждое сообщение поднимает новый headless-процесс (`claude -p` / Agent SDK), заново грузит контекст и платит за это отдельным billing-пулом. Это дорого, медленно и без памяти между ходами.

**labops-tg-plugin работает иначе:** он регистрируется как **MCP-сервер внутри живой сессии Claude Code**. Сессия одна, держится постоянно (под tmux + автостарт), Telegram — это просто канал ввода/вывода к ней.

| | «Бот поверх API» (`claude -p`) | **labops-tg-plugin** |
|---|---|---|
| Процесс на сообщение | новый каждый раз | один долгоживущий |
| Контекст между ходами | теряется / перегружается | сохраняется |
| Биллинг | отдельный SDK-пул | ваша обычная сессия/подписка |
| Память, скиллы, хуки | надо прокидывать вручную | работают как в обычном Claude Code |
| Статус «агент думает» | нет | двухстадийные реакции (👀/👌) |

---

## Возможности

| Возможность | Что делает | Модуль |
|---|---|---|
| **Telegram-канал** | приём/отправка сообщений долгоживущей сессии | `telegram/`, `router/` |
| **Долгий poll (pull)** | `getUpdates` long-poll — без публичного IP и без Telegram-webhook | `telegram/poller.ts` |
| **Двухстадийные реакции** | 👀 «получил» сразу, 👌 «готово» в конце хода | `status/`, `telegram/handlers.ts` |
| **Голосовые** | приём voice → транскрибация → текст агенту (и ответ голосом, опционально) | `telegram/media.ts` |
| **Медиа и альбомы** | фото/документы/группы вложений с буферизацией | `telegram/album-buffer.ts`, `media.ts` |
| **AskUserQuestion** | интерактивные кнопки-варианты прямо в Telegram | `channel/ask-user-question.ts` |
| **Permission-prompt** | подтверждение опасных действий (sudo и т.п.) кнопками | `channel/permissions.ts` |
| **Multichat** | один сервер обслуживает несколько чатов/тредов | `router/multichat-router.ts` |
| **Память хода** | запись turn'ов в `active/episodic.md` + verbose-jsonl (опционально) | `memory/` |
| **HTML-фильтр** | безопасная конвертация терминального вывода в Telegram-HTML | `safety/html-validator.ts`, `format/html.ts` |
| **Rate-limit & redact** | соблюдение лимитов Telegram API, маскирование секретов | `safety/rate-limited-telegram-api.ts`, `safety/redact.ts` |

---

## Архитектура: три «лица» одного процесса

Один Bun-процесс (`src/server.ts`) одновременно играет три роли:

```mermaid
%%{init: {'theme':'base','themeVariables':{'primaryColor':'#EDE9FE','primaryTextColor':'#4C1D95','primaryBorderColor':'#8B5CF6','lineColor':'#8B5CF6','secondaryColor':'#F1F5F9','tertiaryColor':'#ffffff','clusterBkg':'transparent','clusterBorder':'#B794F4','fontFamily':'Helvetica,Arial,sans-serif'}}}%%
flowchart LR
    subgraph proc["Один процесс: bun src/server.ts"]
        MCP["① MCP stdio-сервер<br/>инструменты канала для Claude"]
        POLL["② Telegram long-poller<br/>getUpdates (pull)"]
        HOOK["③ Webhook-сервер :6000+<br/>для Claude Code hooks"]
    end

    TG["Telegram Bot API"] -- "getUpdates (long-poll)" --> POLL
    POLL -- "MCP notification<br/>notifications/claude/channel" --> SESSION

    SESSION["Живая сессия Claude Code<br/>(tmux, автостарт)"]
    SESSION <-->|stdio| MCP
    SESSION -- "PreToolUse / Stop / ..." --> HOOK
    HOOK -- "реакции, прогресс" --> TG
    MCP -- "ответы, кнопки" --> TG

    classDef brand fill:#8B5CF6,stroke:#6D28D9,color:#ffffff,font-weight:bold
    classDef ext fill:#CCFBF1,stroke:#0D9488,color:#0F766E
    classDef store fill:#FEF3C7,stroke:#D97706,color:#92400E
    classDef sys fill:#E2E8F0,stroke:#334155,color:#1E293B
    linkStyle default stroke:#8B5CF6,stroke-width:1.5px
    class MCP,SESSION brand
    class TG ext
    class POLL,HOOK sys
```

1. **MCP stdio-сервер** — регистрируется в `.mcp.json` сессии как `labops-channel`; даёт Claude инструменты канала (ответить в чат, задать вопрос с кнопками, запросить permission).
2. **Telegram long-poller** — тянет апдейты через `getUpdates` (**pull**, не webhook): не нужен публичный IP/домен/TLS, работает за NAT. Входящее сообщение он отдаёт сессии как **MCP-notification** `notifications/claude/channel`.
3. **Внутренний webhook-сервер** (`127.0.0.1:6000+`) — слушает **хуки Claude Code** (`PreToolUse`/`PostToolUse`/`Stop` и др.), чтобы рисовать двухстадийные реакции. Это **не** Telegram-webhook — чисто локальная интеграция с хуками.

> [!IMPORTANT]
> Входящее сообщение НЕ идёт через webhook-сервер. Poller → MCP-notification → сессия. Webhook-сервер дёргают только эфемерные хуки самой сессии Claude Code.

**Почему именно так:**

- **Plugin, а не gateway.** Канал живёт внутри сессии, а не поднимает сессию на каждый ход. Один контекст, одна память, один биллинг. (Подробно — [`docs/01-what-is-this.md`](docs/01-what-is-this.md).)
- **Pull (long-poll), а не push (webhook).** `getUpdates` снимает требование публичного входящего endpoint'а — агент ставится на любой VPS за NAT без домена и сертификата.
- **Разделение каналов управления.** Пользовательский ввод (Telegram → MCP-notification) и сигналы жизненного цикла (Claude hooks → локальный webhook) идут разными путями и не мешают друг другу.
- **Идемпотентность статуса.** Реакции/прогресс — отдельный слой (`status/`), который только отражает состояние и устойчив к повторам и rate-limit'ам Telegram.
- **Безопасность по умолчанию.** Allowlist по user_id/chat_id, anti-spoof проверка bot_id, redaction секретов в исходящем, валидатор HTML — см. [Безопасность](#безопасность).

### Поток входящего сообщения

```mermaid
%%{init: {'theme':'base','themeVariables':{'primaryColor':'#EDE9FE','primaryTextColor':'#4C1D95','primaryBorderColor':'#8B5CF6','lineColor':'#8B5CF6','secondaryColor':'#F1F5F9','tertiaryColor':'#ffffff','clusterBkg':'transparent','clusterBorder':'#B794F4','fontFamily':'Helvetica,Arial,sans-serif'}}}%%
sequenceDiagram
    participant U as Пользователь (Telegram)
    participant P as Poller (getUpdates)
    participant S as Сессия Claude Code
    participant H as Webhook (hooks)
    participant TG as Telegram API

    U->>P: сообщение
    P->>TG: setMessageReaction 👀  (получил)
    P->>S: MCP notification (текст/медиа)
    Note over S: агент думает, вызывает инструменты
    S->>TG: ответ (через MCP-инструмент канала)
    S->>H: Stop (ход завершён)
    H->>TG: setMessageReaction 👌  (готово)
```

---

## Двухстадийные реакции 👀 → 👌

Чтобы пользователь видел, что агент жив и работает:

- **👀 «получил»** — ставится сразу при приёме сообщения (детерминированно, в poller'е), ещё до того, как агент начал думать.
- **👌 «готово»** — ставится на `Stop`-хуке, когда ход завершён.

Это заметно отзывчивее, чем «eyes-on-read» по факту чтения. Символы ✅/❌ Telegram **не** входят в whitelist реакций — используем 👀/👌.

## Fallback-ответ (необязательно, по умолчанию выключено)

Защита от «тишины» агента. Агент отвечает инструментом канала `reply` (или правит своё сообщение через `edit_message`). Если ход закончился (`Stop`-хук) без единого такого вызова, пользователь не получит ничего, хотя финальный ответ есть в транскрипте. С включённым fallback плагин сам отправляет последний текст ассистента в чат, из которого пришло входящее сообщение, как reply на него.

Как работает:

1. Тонкий `Stop`-хук `plugin/scripts/fallback-reply-hook.ts` берёт `transcript_path` и `session_id` из stdin хука и POST'ит их (Bearer `TELEGRAM_WEBHOOK_TOKEN`, только loopback) в `/hooks/fallback-reply` внутреннего webhook плагина.
2. **Решает сервер.** Он читает хвост транскрипта (только из `~/.claude/projects` / `$CLAUDE_CONFIG_DIR/projects`, файлы `*.jsonl`, симлинки раскрываются) и идёт по *текущему ходу* — от последнего настоящего сообщения пользователя до конца. Ничего не отправляется, если:
   - в ходе был вызов `mcp__labops-channel__reply` или `mcp__labops-channel__edit_message` (ход только с `react` считается без ответа);
   - ход начат не из Telegram: пользовательское сообщение не *начинается* с `<channel source="telegram" chat_id="…" message_id="…">` (задачи task-poller, напоминания, task-notification, текст, набранный в tmux);
   - в финальном сегменте хода (после последнего результата инструмента) нет текста ассистента, либо чат не разрешён (тот же шлюз, что у `reply`, включая политику multichat);
   - этот ход уже отправлялся: дедуп по `chat_id:message_id` входящего сообщения, на сессию, в `<state>/fallback-reply/state.json` (переживает рестарт).
3. Текст уходит так же, как у `reply`: markdown в Telegram HTML, разбиение по 4000 символов, `reply_to` только на первой части, повтор простым текстом, если Telegram отверг HTML. Токены вычищает штатная обёртка исходящих. Текст длиннее 16 000 символов обрезается с маркером `…[обрезано]`. В начале стоит короткая пометка, чтобы отличать от осознанного ответа: `⚠ ответ без reply:` (меняется через `TELEGRAM_FALLBACK_REPLY_PREFIX`; пустая строка — без пометки).

Если на момент `Stop` финального текста в транскрипте ещё нет, хук делает несколько повторов (`FALLBACK_REPLY_RETRY_ATTEMPTS`, по умолчанию 4, `FALLBACK_REPLY_RETRY_DELAY_MS`, по умолчанию 150). Хук всегда завершается с кодом 0 и пустым stdout.

**Включение** (нужны оба шага; без переменной ничего не меняется, роут отвечает 503):

1. В `channel.env` агента добавить `TELEGRAM_FALLBACK_REPLY=1` и перезапустить юнит агента.
2. В `settings.json`, который реально читает сессия (см. [где регистрировать хуки](docs/05-troubleshooting.md): обычно глобальный `~/.claude/settings.json`, сначала бэкап), добавить `Stop`-хук рядом с read-receipt:

```json
{
  "hooks": {
    "Stop": [
      {
        "marker": "labops-channel-fallback-reply",
        "hooks": [
          {
            "type": "command",
            "command": "TELEGRAM_CHANNEL_ENV_FILE='/abs/path/to/channel.env' bun '/abs/path/to/plugin/scripts/fallback-reply-hook.ts'",
            "timeout": 30
          }
        ]
      }
    ]
  }
}
```

Путь до `plugin/scripts/` — приватная копия плагина агента (`~/.claude-lab/<agent>/.claude/labops-tg-plugin/plugin/...`): сначала передеплойте копию, правка в монорепо до неё не доходит. Токен в `settings.json` не пишется: хук берёт его из `channel.env`.

## Голос и медиа

- **Входящие voice/audio** скачиваются в inbox state-каталога и транскрибируются; агент получает текст. Расшифровку делает локальный сервис `voice-transcriber` (faster-whisper на этом же хосте, см. `voice-transcriber/` в монорепо); аудио во внешние сервисы не уходит. Без сервиса в сообщении короткая пометка «расшифровка недоступна».
- **Фото/документы/альбомы** буферизуются (`album-buffer.ts`) и передаются как вложения хода.
- Ответ голосом — опционально (TTS подключается на стороне агента).

## Локальный сервер Bot API (файлы до 2 ГБ)

Облачный Bot API режет отправку ботом на 50 МБ, а скачивание на 20 МБ. **Локальный** [`telegram-bot-api`](https://github.com/tdlib/telegram-bot-api) (режим `--local`) поднимает оба потолка до 2000 МБ. Канал поддерживает его через необязательную переменную; **если `TELEGRAM_API_ROOT` не задана, ничего не меняется** (облачный адрес, лимиты 50/20 МБ, те же ветки кода).

1. Получите `api_id` / `api_hash` на <https://my.telegram.org> (API development tools).
2. Соберите и запустите сервер на хосте агента, слушая только loopback:
   ```bash
   telegram-bot-api --local --api-id="$API_ID" --api-hash="$API_HASH" \
     --http-ip-address=127.0.0.1 --http-port=8081 \
     --dir=/var/lib/telegram-bot-api --temp-dir=/var/tmp/telegram-bot-api
   ```
   Запускайте как systemd-юнит от отдельного пользователя.
3. Токен бота привязан к одному серверу. **Перед переключением выведите бота из облака** (один раз; вернуться в облако с этим токеном потом нельзя ~10 минут): `curl "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/logOut"`. Вернуться назад: вызвать `close` у локального сервера и убрать переменную.
4. Доступ к файлам. В режиме `--local` `getFile` отдаёт **абсолютный путь** внутри `--dir` сервера (в нём подкаталог бота с именем из токена — не логируйте). Плагин работает от другого пользователя, поэтому сделайте `--dir` читаемым для пользователя агента (общая группа + `chmod 750`, либо оба под одним пользователем). Скачанное копируется в inbox агента (`0600`), так что каталог сервера периодически чистите.
5. Добавьте в `channel.env` (`new-agent.sh` их не пишет) и перезапустите агента:
   ```bash
   TELEGRAM_API_ROOT=http://127.0.0.1:8081
   TELEGRAM_API_LOCAL_DIR=/var/lib/telegram-bot-api
   ```

Правила (проверяются при старте через Zod, `src/telegram/local-api.ts`):

- `TELEGRAM_API_ROOT` — голый `http(s)://host[:port]`, без пути, query и логина. Простой `http` допустим **только для loopback** (`127.0.0.0/8`, `localhost`, `::1`): токен входит в каждый URL; для удалённого сервера нужен `https`. `api.telegram.org` отвергается. Пустое значение = не задано.
- `TELEGRAM_API_LOCAL_DIR` — абсолютный путь `--dir` сервера. Файл по пути из `getFile` читается с диска, только если его реальный путь (с раскрытыми симлинками) лежит внутри этого каталога; без переменной такой путь отклоняется. Относительный путь качается по HTTP с `${TELEGRAM_API_ROOT}/file/bot<token>/<path>`.
- При заданном корне: инструмент `reply` принимает файлы до 2000 МБ (описание инструмента меняется), у `download_attachment` нет потолка 20 МБ, а собственные таймауты fetch плагина действуют и на этот хост (30 минут на `getFile`/`send*`/скачивание файла: сервер сам скачивает/заливает файл до ответа). Лимит транскрибатора голоса (20 МБ) не меняется.
- Видео уходит документом (как и раньше): приходит файлом, а не встроенным плеером.
- Токен вычищается из ошибок и логов.

## Multichat

Один сервер маршрутизирует несколько чатов/тредов через пул сессий (`router/multichat-router.ts`, `router/tmux-session-pool.ts`). Включение и добавление своего `user_id` — `docs/01-what-is-this.md` и `examples/channel.env.example` (`TELEGRAM_ALLOWED_USER_IDS` / `TELEGRAM_ALLOWED_CHAT_IDS`).

### Личные сообщения: отдельная сессия на человека

Личка оператора всегда живёт в главной сессии. Личка любого другого разрешённого пользователя
идёт через multichat-роутер в отдельную сессию, ключ -- chat id этого человека (тот же путь
inbox/outbox, что у групп). Причина: прокси псевдонимизации хранит таблицу замен на сессию Claude,
и два человека в одном контексте могли бы увидеть восстановленные данные друг друга.

| Настройка (config.json / env) | Смысл |
|---|---|
| `operator_user_ids` / `TELEGRAM_OPERATOR_USER_IDS` (CSV) | Операторы. Не задано: `permission_relay.allowed_user_ids`. Пусто: маршрутизация как раньше. |
| `dm_routing` / `TELEGRAM_DM_ROUTING` | `main` (все в главную сессию, прежнее поведение) или `per_person`. Не задано: `per_person` только при включённом роутере. |

Условия для `per_person`: включён multichat, каждый человек описан в `chats/policy.yaml`
(`allowlist.users`, `allowlist.chats` и запись `chats.<его id>`, обычно `mode: private`).
Человек вне политики отбрасывается с предупреждением и в главную сессию не попадает.
OOB-команды (`/reset`, `/doctor`) и вердикты разрешений доступны только оператору. Без роутера
и при нескольких разрешённых людях плагин один раз пишет предупреждение при старте.

---

## Конфигурация

<details>
<summary>Переменные окружения, команды, детали установки и тесты</summary>

### Переменные окружения

Полный пример — [`examples/channel.env.example`](examples/channel.env.example). Кладётся в `/etc/labops-plugin/<agent>/channel.env` (`chmod 640`, `chown root:<service-user>`). Как получить токен и id — [`docs/telegram-setup.md`](docs/telegram-setup.md).

> [!WARNING]
> Секреты вне git: `channel.env` с `chmod 640` и `chown root:<service-user>`, не коммитится.

| Переменная | Назначение |
|---|---|
| `TELEGRAM_BOT_TOKEN` | токен от [@BotFather](https://t.me/BotFather) |
| `TELEGRAM_EXPECTED_BOT_ID` | числовая часть токена до `:` (anti-spoof) |
| `TELEGRAM_ALLOWED_USER_IDS` | CSV разрешённых user_id |
| `SUPPORT_FOLLOWUP_URL` / `SUPPORT_FOLLOWUP_TOKEN` | необязательный релей клиентов поддержки: приватные сообщения посторонних user_id уходят POST-ом (Bearer-токен) на этот эндпоинт вместо молчаливого дропа; агентская сессия на этом пути не запускается. Нужны обе переменные, иначе ветка выключена (`src/telegram/client-relay.ts`) |
| `TELEGRAM_COMMAND_MENU` | `off` — при каждом старте очищать меню команд «/» вместо регистрации (бот поддержки, в личку которого пишут клиенты); не задано — меню включено (`src/telegram/command-menu.ts`) |
| `TELEGRAM_ALLOWED_CHAT_IDS` | CSV разрешённых chat_id (группы — с `-100…`) |
| `TELEGRAM_WORKSPACE_ROOT` | корень workspace агента (где `CLAUDE.md`, `core/`, `.mcp.json`) |
| `TELEGRAM_API_ROOT` / `TELEGRAM_API_LOCAL_DIR` | необязательный локальный сервер Bot API (`--local`) и его каталог данных: файлы до 2000 МБ, см. [Локальный сервер Bot API](#локальный-сервер-bot-api-файлы-до-2-гб). Не заданы — облако, 50/20 МБ |
| `AGENT_ID` | идентификатор агента (маршрутизация в multi-agent + логи) |
| `TELEGRAM_STATE_DIR` | state агента: `bot.pid`, `config.json`, inbox, логи (изолируйте на агента) |
| `TELEGRAM_WEBHOOK_HOST` / `_PORT` | локальный хост/порт для Claude hooks (по агенту — свой порт, `6000+`) |
| `TELEGRAM_FALLBACK_REPLY` | `1` включает fallback-ответ для ходов, закончившихся без `reply` (по умолчанию выключено); нужен `Stop`-хук, см. [Fallback-ответ](#fallback-ответ-необязательно-по-умолчанию-выключено). `TELEGRAM_FALLBACK_REPLY_PREFIX` — пометка перед текстом |
| `TELEGRAM_MEMORY_ENABLED` | писать turn'ы в `active/episodic.md` + verbose-jsonl |
| `TELEGRAM_MEMORY_WORKSPACE` / `_AGENT_LABEL` / `_SOURCE_TAG` | параметры записи памяти хода |

### Команды

- **Slash/OOB-команды** обрабатываются в `commands/oob.ts` (out-of-band управление каналом из чата).
- Прикладные команды агента (его навыки, роли) живут в его workspace (`CLAUDE.md`, скиллы) — это слой [`agent-architecture`](#часть-labops), а не канала.

### Установка

Требования: **Bun ≥ 1.3**, **Claude Code ≥ v2.1.80**, Linux/systemd (VPS) или macOS/launchd.

```bash
# Рекомендуется — единый корневой install.sh (в корне монорепозитория) ставит
# этот встроенный компонент за вас, а каждый агент линкуется на него:
bash install.sh

# Отдельно (вне монорепозитория): клонируйте ВНУТРЬ папки .claude
# вашего workspace — расположение критично, см. docs/02. <your-workspace> —
# там, где лежит CLAUDE.md этого агента (корень проекта или $HOME), а НЕ
# ~/.claude-lab/<agent>/ — это собственное соглашение agent-architecture.
git clone <this-repo> <your-workspace>/.claude/labops-tg-plugin
cd <your-workspace>/.claude/labops-tg-plugin
./install.sh
```

`install.sh` идемпотентен: ставит зависимости (`bun install`), регистрирует хуки Claude Code (`plugin/scripts/install-hooks.sh`), и **в конце прогоняет тесты репозитория** — установка считается успешной только при зелёных тестах.

Дальше:
- [`docs/telegram-setup.md`](docs/telegram-setup.md) — чек-лист настройки бота (токен, user_id, chat_id групп)
- [`docs/01-what-is-this.md`](docs/01-what-is-this.md) — концепция и архитектура
- [`docs/02-where-to-place-plugin.md`](docs/02-where-to-place-plugin.md) — **критично:** куда класть плагин
- [`docs/03-installation-linux.md`](docs/03-installation-linux.md) / [`docs/03-installation-macos.md`](docs/03-installation-macos.md)
- [`docs/05-troubleshooting.md`](docs/05-troubleshooting.md)
- [`docs/06-how-claude-loads-session.md`](docs/06-how-claude-loads-session.md) — где Claude ищет `settings.json` (частый источник «хук молча не сработал»)

### Тесты

```bash
# Функциональные тесты плагина (TypeScript/Bun)
cd plugin && bun test

# Тесты supervisor/webhook-listener/доков (Python)
python3 -m venv .venv && .venv/bin/pip install -r webhook-listener/requirements.txt pytest
.venv/bin/python -m pytest tests/ -q
```

`install.sh` выполняет их автоматически в конце установки.

</details>

---

## Безопасность

| Механизм | Что защищает |
|---|---|
| **Allowlist** `TELEGRAM_ALLOWED_USER_IDS` / `_CHAT_IDS` | боту отвечает только разрешённым |
| **Anti-spoof** `TELEGRAM_EXPECTED_BOT_ID` | сверка bot_id с токеном — чужой апдейт отбрасывается |
| **Redaction** (`safety/redact.ts`) | маскирование секретов/токенов в исходящих сообщениях |
| **HTML-валидатор** (`safety/html-validator.ts`) | только безопасный whitelist тегов в Telegram-HTML |
| **Rate-limit** (`safety/rate-limited-telegram-api.ts`) | соблюдение лимитов Telegram API без банов |
| **Секреты вне git** | `channel.env` с `chmod 640`, не коммитится |

---

## Данные и приватность

Self-hosted by design: плагин работает на собственном сервере оператора, данные остаются на его инфраструктуре, никакой телеметрии и аналитики нет.

Внешние эндпоинты, которые реально используются:

| Эндпоинт | Назначение | Когда |
|---|---|---|
| `api.telegram.org` | Telegram Bot API — приём/отправка сообщений, загрузка вложений | Пока канал запущен |
| `TELEGRAM_API_ROOT` (например `127.0.0.1:8081`) | Локальный сервер Bot API вместо `api.telegram.org` | Только если переменная задана |
| `127.0.0.1:8310` (локальный `voice-transcriber`) | Транскрипция голоса (faster-whisper) | Только когда приходит голосовое и задан `VOICE_TRANSCRIBER_TOKEN`; хост не покидает |
| `127.0.0.1` (внутренний webhook) | Локальный IPC между хуками Claude Code и сервером канала (read-receipts, прогресс, ask-user) | Только локально — слушает loopback, наружу не публикуется |

> [!NOTE]
> Единственный исходящий трафик — в Telegram (и к тому провайдеру, которого настроит оператор, например для транскрипции голоса). Больше с хоста ничего не уходит.

Секреты лежат в `channel.env` (`chmod 640`, `chown root:<service-user>`) и никогда не коммитятся в git.

---

## Часть labops

labops — это три слоя: два встроены в монорепозиторий `labops-ai-assistant`, один внешний:

| Компонент | Роль | Зависимость |
|---|---|---|
| **tg-plugin** (этот · встроенный компонент, этот монорепозиторий) | Telegram-канал к живой сессии Claude Code | самодостаточен |
| [**labops-second-brain**](https://github.com/dediukhinpa/labops-second-brain) (внешний репозиторий) | общая память: Postgres+pgvector, MCP memory/memory_router/agent_router/tasks, слои памяти + доска задач | подключается к агенту по MCP |
| [**agent-architecture**](../agent-architecture) (встроенный компонент, этот монорепозиторий) | воркспейсы агентов, автостарт/watchdog, первый агент **Developer** + скилл создания агентов, голос | использует этот плагин и second-brain |

Этот плагин самодостаточен (можно поставить один Telegram-агент без общей памяти). Полная архитектура — собранная вместе с этим плагином в монорепозитории — в [`agent-architecture`](../agent-architecture).

> **Ставите монорепозиторий?** См. [Быстрый старт](#быстрый-старт) выше — единый
> корневой `bash install.sh` (в корне монорепозитория) ставит этот встроенный
> компонент за вас в рамках общей установки; он отрабатывает до создания первого
> агента, так что Telegram-канал уже готов, когда `new-agent.sh` его запросит.

---

## Лицензия

Проприетарная (Proprietary) — © 2026 LabOps.ai. Все права защищены. См. [LICENSE](./LICENSE).
