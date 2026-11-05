# Рой на моделях OpenAI: адаптер Claude Code -> OpenAI

Альтернативный вариант курса. Архитектура репозитория не меняется: рой остаётся роем Claude
Code, а вместо `api.anthropic.com` его запросы принимает локальный адаптер (LiteLLM) и
переводит их в запросы к OpenAI.

```
claude -> pii-proxy (127.0.0.1:63xx) -> адаптер (127.0.0.1:4000) -> OpenAI (Responses API)
```

Это работает, потому что Claude Code умеет ходить на любой шлюз с форматом Anthropic Messages
(`ANTHROPIC_BASE_URL`), а у `pii-proxy` адрес апстрима уже настраивается (`PII_PROXY_UPSTREAM`).

> **Статус: экспериментальный.** Anthropic [прямо пишет](https://code.claude.com/docs/en/llm-gateway),
> что не поддерживает Claude Code на не-Claude моделях через шлюзы. Качество работы агентов
> на моделях OpenAI и стоимость круглосуточного роя при оплате по токенам не измерены.

## Что проверено, а что нет

Проверено (на LiteLLM 1.106.3, Claude Code 2.1.318, заглушка вместо OpenAI):

- LiteLLM принимает `/v1/messages` и отправляет запрос в OpenAI через **Responses API**
  (`/v1/responses`), а не Chat Completions. Стриминг и обычный ответ переводятся в события Anthropic.
- Полный цикл: Claude Code шлёт 12 своих инструментов, модель просит вызвать `Bash`, Claude Code
  выполняет его, возвращает результат вторым запросом, получает итоговый ответ.
- Интерактивная сессия (как у агента в tmux) на пустом `HOME` с `ANTHROPIC_AUTH_TOKEN` в окружении
  не показывает экран входа в Claude: только мастер первого запуска, который репозиторий и так
  предзаполняет.
- Установка зависимостей строго по `requirements.lock` с `--require-hashes` (117 пакетов).
- Юнит-тесты установщика и скрипта перевода агента (`test.sh`), смоук-тест `openai-adapter/smoke/smoke.sh`.

**Не проверено** (нужна чистая машина и настоящий ключ OpenAI):

- качество агентной работы на моделях OpenAI: вызовы инструментов, длинные сессии, субагенты;
  картинки и PDF, серверный web search, extended thinking и prompt caching в документации
  Claude Code для не-Anthropic моделей не описаны;
- цепочка с настоящим `pii-proxy` и перезапуск агента watchdog'ом после перевода;
- systemd-юнит адаптера под root и полный `install.sh` на чистом VPS;
- стоимость: рой работает круглосуточно, оплата идёт за токены, а не по подписке.

## Установка

Нужен сервер с Linux, systemd, Python 3.12+, ключ API OpenAI и имя модели с
platform.openai.com (список моделей меняется - берите актуальное имя оттуда).

```bash
bash install.sh --openai-adapter
```

Установщик спросит ключ (ввод не виден) и имя модели, либо возьмёт их из окружения
(`OPENAI_API_KEY`, `LABOPS_OPENAI_MODEL`). Он:

- ставит LiteLLM в `/opt/labops-openai-adapter` по `requirements.lock` с хэшами;
- пишет `/etc/labops-openai-adapter/{config.yaml,adapter.env}` (ключ OpenAI - только во втором,
  права 640 `root:labops-llm`);
- запускает юнит `labops-openai-adapter.service` на `127.0.0.1:4000` от отдельного пользователя;
- кладёт локальный ключ шлюза в `<лаборатория>/shared/secrets/openai-adapter.env` (600).

Повтор безопасен: локальный ключ шлюза не меняется, модель можно сменить.

## Перевод агента на адаптер

```bash
bash orchestration/openai-adapter-wire.sh <агент>
sudo systemctl restart claude-agent-<агент>.service
```

Скрипт сохраняет исходные файлы в `<агент>/.claude/backup-openai-adapter/` и меняет:

| Файл | Изменение |
|---|---|
| `settings.json` | `"model"` = имя модели OpenAI |
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

## Безопасность

- В марте 2026 в PyPI были опубликованы вредоносные версии LiteLLM (1.82.7 и 1.82.8). Поэтому
  версия закреплена, а `requirements.lock` содержит хэши всех файлов каждого пакета.
- **Обновление LiteLLM** - только осознанно: поменять версию в `openai-adapter/requirements.in`,
  в чистом окружении Python 3.12 собрать новый `requirements.lock` с хэшами (`pip-compile
  --generate-hashes`), прогнать `smoke.sh` и тесты. Не ставьте «последнюю» версию на ходу.
- Ключ OpenAI не попадает в `settings.json`, `channel.env` и командные строки: он лежит только в
  `adapter.env`, который читает один юнит. Агенты получают лишь локальный ключ шлюза, действующий
  на `127.0.0.1`.
- OpenAI API не поддерживается в России. Адаптер работает на сервере в поддерживаемой стране, и
  запросы к OpenAI идут оттуда; аккаунт и оплата требуют иностранной карты.

## Смоук-тест

```bash
bash openai-adapter/smoke/smoke.sh /opt/labops-openai-adapter/.venv/bin/litellm
```

Поднимает заглушку Responses API и LiteLLM по настоящему шаблону конфига, гоняет настоящий
Claude Code в пустом `HOME` (подписка не используется) и проверяет цикл с вызовом инструмента.
Нужен после любого обновления LiteLLM или Claude Code.
