# Рой на подписке ChatGPT: адаптер Claude Code -> ChatGPT

Альтернативный вариант курса, на случай если аккаунт Claude недоступен. Архитектура
репозитория не меняется: рой остаётся роем Claude Code, а вместо `api.anthropic.com` его
запросы принимает локальный адаптер (LiteLLM) и отправляет в ChatGPT **по подписке**
(Plus/Pro), без ключа API.

```
claude -> pii-proxy (127.0.0.1:63xx) -> адаптер (127.0.0.1:4000) -> бэкенд подписки ChatGPT
```

Это работает, потому что Claude Code умеет ходить на любой шлюз с форматом Anthropic Messages
(`ANTHROPIC_BASE_URL`), у `pii-proxy` адрес апстрима настраивается (`PII_PROXY_UPSTREAM`), а в
LiteLLM есть провайдер `chatgpt/` (вход по коду устройства, как у Codex CLI).

> **Статус: экспериментальный.** Anthropic [не поддерживает](https://code.claude.com/docs/en/llm-gateway)
> Claude Code на чужих моделях через шлюзы. Вход по подписке опирается на недокументированный
> бэкенд ChatGPT: если OpenAI изменит проверку, схема перестанет работать до обновления LiteLLM.
> Официального заявления OpenAI о запрете или разрешении такого использования токенов
> подписки в сторонних инструментах мы не нашли; ответственность за соблюдение условий OpenAI
> лежит на владельце аккаунта.

## Что проверено, а что нет

Проверено (LiteLLM 1.106.3, Claude Code 2.1.318, заглушка вместо бэкенда ChatGPT):

- `/v1/messages` -> LiteLLM -> `POST /responses` с токеном входа в заголовке, стриминг и обычный
  ответ переводятся в события Anthropic.
- Полный цикл: Claude Code шлёт 12 своих инструментов, модель просит вызвать `Bash`, Claude Code
  выполняет его, возвращает результат вторым запросом, получает итоговый ответ.
- Для модели, которой нет в справочнике LiteLLM, запрос без `model_info: mode: responses` уходит
  в `/chat/completions`, поэтому режим задан в шаблоне конфига явно (тест это проверяет).
- Установка зависимостей по `requirements.lock` с `--require-hashes`; юнит-тесты установщика и
  скрипта перевода агента (`test.sh`), смоук `openai-adapter/smoke/smoke.sh`.

**Не проверено** (нужны подписка ChatGPT и чистая машина):

- сам вход по коду устройства против настоящего `auth.openai.com` и работа с реальным бэкендом
  `chatgpt.com/backend-api/codex`; какие модели доступны на каком тарифе;
- качество агентной работы на моделях OpenAI: вызовы инструментов, длинные сессии, субагенты;
  картинки и PDF, prompt caching не проверялись; поведение `thinking` и серверного web search
  в LiteLLM разобрано в разделе «Известные ограничения», но с настоящим бэкендом не сверялось;
- обновление токена в долгой работе (должно идти само, при отзыве доступа нужен повторный вход);
- цепочка с настоящим `pii-proxy`, перезапуск агента watchdog'ом, юнит под root, полный
  `install.sh` на чистом VPS;
- лимиты: тариф считает расход окнами по пять часов и недельным лимитом, круглосуточный рой
  может упереться в них.

## Установка

Нужен сервер с Linux, systemd, Python 3.12+ и подписка ChatGPT (Plus или Pro), оформленная
в стране, которую поддерживает OpenAI.

```bash
AGENT_OS_USER=<пользователь агентов> bash install.sh --openai-adapter
```

Команда запускается от root (или с sudo). `AGENT_OS_USER` нужен, чтобы ключ шлюза лёг в
лабораторию агентов, а не в `/root`; без него берётся тот, кто запустил команду.

Установщик предложит модель (Enter - рекомендуемая `gpt-6.1-sol`; на проверенной подписке отвечали также `gpt-6-sol`, `gpt-5.6-sol`, `gpt-5.6-luna`, а `gpt-5.5`, `gpt-5.4`, `gpt-5.3-codex` бэкенд отвергал; набор зависит от тарифа; либо `LABOPS_OPENAI_MODEL=<имя>`), затем
покажет ссылку и код: откройте ссылку в браузере, где вы вошли в аккаунт OpenAI, введите код и
подтвердите вход. Он:

- ставит LiteLLM в `/opt/labops-openai-adapter` по `requirements.lock` с хэшами;
- входит в ChatGPT от имени службы, токены - в `/var/lib/labops-openai-adapter` (700);
- пишет `/etc/labops-openai-adapter/{config.yaml,adapter.env,flatten_system.py}` (без секретов
  подписки; `flatten_system.py` - хук LiteLLM, см. раздел «Хук flatten_system.py»);
- запускает `labops-openai-adapter.service` на `127.0.0.1:4000` от отдельного пользователя;
- кладёт локальный ключ шлюза в `<лаборатория>/shared/secrets/openai-adapter.env` (600).

Повтор безопасен: ключ шлюза и вход остаются, модель можно сменить. Если вход перестал
работать (доступ отозван, пароль сменён), запустите ту же команду снова.

Если страница входа сообщает, что вход по коду отключён, включите его в настройках
безопасности ChatGPT и повторите.

## Перевод агента на адаптер

```bash
runuser -u <пользователь агентов> -- bash ~<пользователь агентов>/labops-ai-assistant/agent-architecture/orchestration/openai-adapter-wire.sh <агент>
sudo systemctl restart claude-agent-<агент>.service
```

Скрипт запускается от пользователя агентов: он правит файлы его лаборатории.

Скрипт сохраняет исходные файлы в `<агент>/.claude/backup-openai-adapter/` и меняет:

| Файл | Изменение |
|---|---|
| `settings.json` | `"model"` = имя модели |
| `secrets/pii-proxy.env` | `PII_PROXY_UPSTREAM` = адаптер вместо `api.anthropic.com` |
| `channel.env` агента | `ANTHROPIC_AUTH_TOKEN` = локальный ключ шлюза |

`ANTHROPIC_AUTH_TOKEN` обязателен: без него Claude Code отправил бы на шлюз OAuth-токен
подписки Claude. Агент без `pii-proxy` получает `ANTHROPIC_BASE_URL` на адаптер прямо в
`settings.json`, но тогда маскирования персональных данных нет (скрипт предупреждает).

Откат: `bash orchestration/openai-adapter-wire.sh <агент> --revert`, затем перезапуск агента.

## Что меняется для агента

- Подписка Claude и вход в неё не используются. `doctor.sh` и `new-agent.sh` предупредят, что
  нет `~/.claude/.credentials.json`: для этого варианта это ожидаемо.
- Claude Code для неизвестного имени модели считает окно контекста 200 тыс. токенов и пишет
  предупреждение `unrecognized_model`. Шаблон агента ставит `CLAUDE_CODE_AUTO_COMPACT_WINDOW=400000`:
  подгоните его под реальное окно выбранной модели.
- Remote Control и голосовой ввод самого Claude Code при заданном `ANTHROPIC_AUTH_TOKEN` недоступны
  (голос агента в Telegram - отдельный сервис, его это не касается).

## Хук flatten_system.py

Файл `openai-adapter/flatten_system.py` подключён в конфиге как
`callbacks: flatten_system.flatten_system` и лежит в `/etc/labops-openai-adapter/` рядом с
`config.yaml`; LiteLLM импортирует его при старте юнита. Хук делает две вещи.

1. **System -> строка.** Claude Code присылает system списком блоков. Бэкенд подписки
   отвечает «System messages are not allowed», если такие блоки попадают во вход Responses API
   как сообщения; хук склеивает текстовые блоки в строку, она уходит в `instructions`.
2. **Восстановление аргументов параллельных вызовов инструментов в стриме.**
   - *Симптом:* когда за ход модель вызывает 2 и более инструментов, Claude Code получал
     `tool_use` с пустым `input` (`{}`), инструмент падал с `InputValidationError`, модель
     повторяла вызов - лишние ходы. На боевом шлюзе за сутки так прошли 51 из 971 вызовов
     (около 5% ходов).
   - *Причина:* при нескольких вызовах за ход бэкенд подписки не шлёт
     `response.function_call_arguments.delta`; аргументы приходят целиком только в
     `response.function_call_arguments.done` и `response.output_item.done`, а LiteLLM берёт
     аргументы только из `.delta`.
   - *Маршрут:* для провайдера `chatgpt/` (все четыре проверенные модели) `/v1/messages` идёт
     не через `AnthropicResponsesStreamWrapper`, а через адаптер Anthropic -> chat/completions
     (`llms/anthropic/pass_through/adapters/streaming_iterator.py`, `AnthropicStreamWrapper`)
     и мост Responses -> chat (`completion_extras/litellm_responses_transformation/
     transformation.py`, `OpenAiResponsesToChatCompletionStreamIterator.chunk_parser`). Причина
     в `llms/anthropic/pass_through/messages/handler.py`: `_RESPONSES_API_PROVIDERS = {"openai"}`,
     `chatgpt` в наборе нет.
   - *Как исправлено:* хук при импорте ставит два независимых патча.
     Основной - на `chunk_parser` моста (отложенная атомарная выдача): чанк
     `output_item.added` придерживается, и вызов уходит одним `tool_call` сразу с id, именем и
     аргументами - на первой дельте либо на `arguments.done` / `output_item.done`. Так работает и
     перемешанный порядок событий: адаптер Anthropic последовательный и кладёт аргументы в
     текущий блок, поэтому открывать блок без аргументов нельзя.
     Запасной - на `AnthropicResponsesStreamWrapper._process_event`, на случай если маршрут
     переключится на Responses: если по блоку не было родных дельт, перед `content_block_stop`
     вставляется один `input_json_delta` с полными `arguments`. Если дельты были, дубля нет.
     Текстовые блоки, reasoning и ответ без стриминга не затрагиваются.

Патчи привязаны к внутренностям LiteLLM, проверенным на **1.106.3**. Поведение при
расхождении:

- версия LiteLLM другая, а нужные имена на месте - предупреждение в журнал, патч ставится;
- модуль, класс, метод или поля не найдены - предупреждение в журнал, этот патч отключается, хук
  system продолжает работать (шлюз живёт, но параллельные вызовы могут приходить с пустым
  `input`);
- сбой внутри самого патча на потоке - предупреждение, поток дальше идёт штатным путём.

Проверка после выкатки описана в разделе «Обновление хука на установленном сервере».
Надёжнее всего `smoke.sh`: сценарии с параллельными вызовами падают, если аргументы не дошли.
После любого обновления LiteLLM смоук обязателен.

## Известные ограничения

Проверено на реальном маршруте через заглушку бэкенда (LiteLLM 1.106.3). На бэкенд всегда
уходит фиксированный набор ключей: `include: ["reasoning.encrypted_content"]`, `input`,
`instructions`, `model`, `store: false`, `stream: true`, плюс `reasoning` и `tools`, если они
есть. Запрос клиента без стриминга тоже уходит на бэкенд как `stream: true`. С настоящим
бэкендом подписки поведение не сверялось.

- **`max_tokens` не действует.** Провайдер `chatgpt/` оставляет в запросе только разрешённые
  ключи, и LiteLLM молча вырезает `max_output_tokens` сам: до бэкенда он не доходит. Ответ не
  ограничивается по длине, а `stop_reason: max_tokens` возможен только если бэкенд сам вернёт
  статус `incomplete`. Так же вырезаются `temperature` и `top_p`.
- **Бюджет мышления не передаётся.** `thinking` не отбрасывается целиком, а сводится к уровню:
  и `{type: enabled, budget_tokens: N}` (наблюдалось при бюджете 4000), и `{type: adaptive}`
  превращаются в `reasoning: {effort: "medium"}`. Сам бюджет в токенах теряется. Блоки `thinking`
  Claude Code получит только если бэкенд пришлёт сводки рассуждений; иначе их не будет.
- **Серверный web search не работает.** Инструмент `web_search_20250305` молча отбрасывается:
  до бэкенда он не доходит (обычные function-инструменты остаются), ошибки нет. Модель отвечает
  без поиска, а клиент об этом не узнаёт. Результатов поиска (`web_search_tool_result`) и
  ссылок не будет.
- Обычные инструменты Claude Code (`Bash`, `Read`, `Edit` и т.д.) - это функции, они
  переводятся штатно; ограничения выше их не касаются.

## Безопасность

- В марте 2026 в PyPI были опубликованы вредоносные версии LiteLLM (1.82.7 и 1.82.8). Поэтому
  версия закреплена, а `requirements.lock` содержит хэши всех файлов каждого пакета.
- **Обновление LiteLLM** - только осознанно: поменять версию в `openai-adapter/requirements.in`,
  в чистом окружении Python 3.12 собрать новый `requirements.lock` с хэшами (`pip-compile
  --generate-hashes`), прогнать `smoke.sh` и тесты.
- Токены подписки лежат только в `/var/lib/labops-openai-adapter/auth.json` (700, пользователь
  службы). Агенты получают лишь локальный ключ шлюза, действующий на `127.0.0.1`. Тот, кто
  прочитает `auth.json`, получает доступ к подписке: не копируйте файл и не кладите в репозиторий.
- OpenAI доступен не во всех странах; регистрация, оплата и сервер должны быть в стране из
  [списка OpenAI](https://help.openai.com/en/articles/7947663-chatgpt-supported-countries-and-territories).

## Смоук-тест

```bash
bash openai-adapter/smoke/smoke.sh /opt/labops-openai-adapter/.venv/bin/litellm [путь к claude]
```

Нужен после любого обновления LiteLLM или Claude Code и после правки хука. Шаги:

1. Юнит-тесты хука `openai-adapter/tests/` (venv-питоном: `python -m pytest -q openai-adapter/tests`
   или `python -m unittest discover`). Они всегда идут против хука из рабочей копии.
2. Заглушка Responses API (`smoke/mock_openai.py`) вместо бэкенда ChatGPT и LiteLLM по настоящему
   шаблону конфига с подставными токенами входа.
3. Проверка потока `/v1/messages` на уровне протокола (`smoke/check_stream.py`) без Claude Code:
   склейка `partial_json` каждого `tool_use` равна ожидаемым аргументам (без дублей и потерь),
   индексы блоков идут подряд, у блока один start и один stop, `stop_reason` верный.
4. Настоящий Claude Code в пустом `HOME` с подставным токеном шлюза: запрос -> вызов `Bash` ->
   результат -> ответ.

Сценарии заглушки (все обязательные, мягкого режима нет):

| Сценарий | Что моделирует |
|---|---|
| `RUN_TOOL` | один вызов инструмента, аргументы приходят дельтами |
| `PARALLEL_NODELTA` | два вызова без `.delta`, аргументы только в `.done` (случай бага) |
| `PARALLEL_INTERLEAVED` | то же, но оба `output_item.added` идут раньше обоих `.done` |
| `PARALLEL_DELTA` | два вызова с дельтами: дублей быть не должно |
| `MIXED` | текст и вызовы вперемешку |
| `LONG` | длинные аргументы (больше 10 КБ, кириллица и эмодзи) |
| `EMPTY` | вызов инструмента с пустыми аргументами `{}` |

Переменные окружения:

- `SMOKE_MODEL` - имя модели (по умолчанию `gpt-smoke`);
- `SMOKE_HOOK` - путь к файлу хука вместо `openai-adapter/flatten_system.py`;
- `SMOKE_MOCK_PORT`, `SMOKE_LLM_PORT` - порты заглушки и LiteLLM (по умолчанию 18081 и 18000);
- `MOCK_DEBUG=1` - журнал заглушки с ключами запроса к бэкенду.

**Мутационная проверка.** Чтобы убедиться, что смоук ловит баг, а не проходит всегда, подайте
через `SMOKE_HOOK` исходный хук без патчей потока. `SMOKE_HOOK` влияет только на хук, который
грузит LiteLLM; юнит-тесты шага 1 остаются на хуке из рабочей копии. Результат на проверенных
файлах: с новым хуком всё зелёное; с исходным 10 провалов - потоки `PARALLEL_NODELTA`,
`PARALLEL_INTERLEAVED`, `MIXED`, `LONG` и Claude Code `PARALLEL_NODELTA`, `MIXED`, `LONG`
(`InputValidationError`).

## Обновление хука на установленном сервере

Хук читается один раз при старте юнита, поэтому после замены файла нужен перезапуск.
Файл, права и владелец те же, что у установщика (`orchestration/lib/openai-adapter-install.sh`):
режим `640`, владелец `root` (`LABOPS_LLM_OWNER`), группа `labops-llm` (`LABOPS_LLM_USER`),
каталог `/etc/labops-openai-adapter` (`LABOPS_LLM_ETC`). Если при установке эти переменные
менялись, подставьте свои значения.

```bash
# 1. Копия старого файла
sudo cp -a /etc/labops-openai-adapter/flatten_system.py \
  /etc/labops-openai-adapter/flatten_system.py.bak-$(date +%F)

# 2. Новый файл из репозитория (только хук; tests/ и smoke/ на сервер не ставятся)
sudo install -m 640 -o root -g labops-llm \
  <репозиторий>/agent-architecture/openai-adapter/flatten_system.py \
  /etc/labops-openai-adapter/flatten_system.py

# 3. Перезапуск и проверка
sudo systemctl restart labops-openai-adapter.service
curl -fsS -m 3 http://127.0.0.1:4000/health/liveliness
sudo journalctl -u labops-openai-adapter.service --since "-5min" --no-pager | grep "flatten_system:"
```

Как читать результат:

- Информационная строка об успешной установке патчей в журнал юнита не попадает (уровень
  логов LiteLLM по умолчанию выше, `LITELLM_LOG` не задан). Основной признак - **отсутствие
  строк `flatten_system:` уровня WARNING** после перезапуска: `grep` выше должен ничего не
  вывести.
- Прямая проверка, что патчи встают на установленной версии LiteLLM:

```bash
sudo -u labops-llm bash -c 'cd /etc/labops-openai-adapter && \
  /opt/labops-openai-adapter/.venv/bin/python -B -c \
  "import flatten_system as f; print(f.patch_status())"'
```

  Ожидается `{'stream_args': True, 'chat_bridge': True}`. Пользователь `labops-llm` читает хук
  (режим 640, группа `labops-llm`). Импорт хука вне прокси сам ставит патчи в этот процесс
  питона, поэтому ответ показывает именно совместимость патчей с установленным LiteLLM.

Перед боевой заменой прогоните `smoke.sh` на тестовой машине с той же версией LiteLLM.

**Откат:**

```bash
sudo cp -a /etc/labops-openai-adapter/flatten_system.py.bak-<дата> \
  /etc/labops-openai-adapter/flatten_system.py
sudo systemctl restart labops-openai-adapter.service
```

Старый хук без патча потока вернёт симптом пустых `input` у параллельных вызовов, но шлюз
останется рабочим. Повторный `install.sh --openai-adapter` тоже обновляет хук, но заодно
пересоздаёт конфиг и юнит, поэтому для одной замены файла проще шаги выше.

## Токен подписки: обновление

Сервер ChatGPT перестаёт принимать `access_token` раньше срока `exp`, записанного в нём:
на живой подписке токен с `exp` через 10 суток был отвергнут (401 `token_expired`) примерно
через 53 часа после выпуска. LiteLLM обновляет токен только по `exp` и на 401 не реагирует,
поэтому шлюз вставал на третьи сутки. Для этого `flatten_system.py` делает две вещи
(`patch_status()` показывает `token_refresh: True`):

- **По возрасту.** Перед запросом токен старше `LABOPS_CHATGPT_MAX_TOKEN_AGE_H` часов (по
  `iat`, по умолчанию 12; при необходимости переменную можно добавить в `adapter.env`) обновляется по `refresh_token`.
- **После 401.** При ответе 401 `token_expired` хук обновляет токен сразу (не чаще раза в
  30 секунд), и повтор запроса клиентом проходит. Первый запрос с 401 до клиента всё же
  доходит: Claude Code повторяет его сам.

Обновление идёт под одной блокировкой с перечитыванием `auth.json`: `refresh_token`
одноразовый (у Codex это `refresh_token_reused`), два параллельных обмена испортили бы вход.
Если OpenAI отклоняет сам `refresh_token` (HTTP 400/401/403, сменён пароль, отозвана сессия),
в журнале появляется предупреждение «нужен повторный вход по коду»: запустите
`install.sh --openai-adapter` снова.

`router_settings: disable_cooldowns: true` в конфиге нужен потому, что модель одна:
без него после ошибки LiteLLM отвечает 429 на 5 секунд, даже если токен уже обновлён.

Codex CLI делает похоже: обновляет токен за 5 минут до `exp` (или через 8 суток по
`last_refresh`, если `exp` не разобрать) и на 401 перечитывает файл и обновляет токен.
