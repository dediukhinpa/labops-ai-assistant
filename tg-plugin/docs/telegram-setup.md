# Настройка Telegram-бота — чек-лист

Пошагово, копипастом. Все значения ниже — **плейсхолдеры**, подставьте свои.
Реальные токены/id никогда не коммитьте (см. `examples/channel.env.example`, `chmod 640`).

## 1. Создать бота у @BotFather → получить токен

1. Откройте [@BotFather](https://t.me/BotFather) в Telegram.
2. Отправьте `/newbot`.
3. Задайте **отображаемое имя** (любое, напр. `My Agent`).
4. Задайте **username** — должен заканчиваться на `bot` (напр. `my_agent_bot`).
5. BotFather пришлёт **токен** вида:

   ```
   <BOT_ID>:<SECRET>      # формат: <числовой id>:<секретная строка>
   ```

   → это `TELEGRAM_BOT_TOKEN`.

## 2. TELEGRAM_EXPECTED_BOT_ID — числовая часть до «:»

Anti-spoof: это число **до двоеточия** в токене.

```
TELEGRAM_BOT_TOKEN=<BOT_ID>:<SECRET>
TELEGRAM_EXPECTED_BOT_ID=<BOT_ID>        # только цифры слева от ":"
```

Пример (плейсхолдеры): если токен `<BOT_ID>:<SECRET>`, то `TELEGRAM_EXPECTED_BOT_ID=<BOT_ID>`.

## 3. Свой числовой user_id → @userinfobot

1. Откройте [@userinfobot](https://t.me/userinfobot), нажмите Start.
2. Он ответит вашим числовым `Id` (напр. `<YOUR_USER_ID>`).

```
TELEGRAM_ALLOWED_USER_IDS=<YOUR_USER_ID>     # CSV, можно несколько через запятую
```

## 4. chat_id для групп (отрицательный, начинается с -100)

Личные DM: `TELEGRAM_ALLOWED_CHAT_IDS` = тот же `<YOUR_USER_ID>`.

Для **группы** chat_id **отрицательный** и начинается с `-100`:

1. Добавьте бота в группу.
2. Узнайте chat_id: переслать сообщение из группы в [@userinfobot](https://t.me/userinfobot)
   или [@RawDataBot](https://t.me/RawDataBot) — в поле `chat.id` будет `-100...`.

```
TELEGRAM_ALLOWED_CHAT_IDS=-100<GROUP_CHAT_ID>
```

## 5. Минимальный channel.env

Скопируйте [`examples/channel.env.example`](../examples/channel.env.example) и заполните:

```bash
TELEGRAM_BOT_TOKEN=<BOT_ID>:<SECRET>
TELEGRAM_EXPECTED_BOT_ID=<BOT_ID>
TELEGRAM_ALLOWED_USER_IDS=<YOUR_USER_ID>
TELEGRAM_ALLOWED_CHAT_IDS=<YOUR_USER_ID>     # DM-only: то же, что user_id
TELEGRAM_WORKSPACE_ROOT=/path/to/agent/.claude
TELEGRAM_STATE_DIR=/path/to/state/<agent>/telegram
```

Положите файл в `/etc/labops-plugin/<agent>/channel.env`, `chmod 640`,
`chown root:<service-user>`. Полный список переменных — README → «Переменные окружения».

Проверить, что токен задан, не печатая его:

```bash
CHANNEL_ENV=/etc/labops-plugin/<agent>/channel.env ./install.sh --no-tests
```
