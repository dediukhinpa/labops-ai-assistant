# pii-proxy

Локальный HTTP-прокси между Claude Code и API модели: маскирует персональные данные в
запросах через сервис `pseudonymizer` и возвращает оригиналы в ответах. Один процесс на агента.

## Установка (обычно делает `agent-architecture`)

- `install.sh` ставит сервис псевдонимизации: `agent-architecture/orchestration/pii-setup.sh host`.
- `new-agent.sh` на каждого агента: `pii-setup.sh agent <id>`. Создаёт `secrets/pii-proxy.env`
  (образец: `deploy/env.example`), user-юнит `labops-pii-proxy@<id>`, прописывает
  `ANTHROPIC_BASE_URL` и хук `hooks/session-end.sh` в `settings.json` агента.
- Порты: `6300 + индекс агента` (webhook плагина - 6000+, listener - 6100/6101).
- Отключить: `SKIP_PII_PROXY=1` (ПДн тогда уходят в модель немаскированными).

## Проверка живости

`GET /health` (без авторизации, прокси слушает только `127.0.0.1`) отвечает `{"status":"ok"}`.
По нему `watchdog.sh` решает, можно ли запускать `claude`.

## Застрявшая сессия

После `STUCK_FAILURE_THRESHOLD` (3) отказов 422/503 подряд в одной сессии прокси пишет событие
`session_stuck` (отпечаток сессии, счётчик, код; значений ПДн нет), не чаще раза в час на сессию.
Если задан `PII_PROXY_ALERT_FILE`, строка JSON дописывается туда; `watchdog.sh` читает файл и
шлёт оператору алерт через `notify.sh`.

## Тесты

`bun test`, `bun run typecheck` (зависимости: `bun install`).
