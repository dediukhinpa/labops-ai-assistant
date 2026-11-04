# voice-transcriber

Локальный сервис расшифровки голосовых сообщений: faster-whisper (CTranslate2, CPU, int8).
Заменяет внешний Groq: голос может содержать персональные данные, и по решению владельца он
не покидает хост. Плагин Telegram (`tg-plugin`) зовёт сервис по loopback и вставляет текст
в сообщение для модели; дальше текст идёт к модели через прокси маскирования.

## API

| Запрос | Что делает |
|---|---|
| `POST /transcribe` | тело: сырое аудио (`Content-Type: audio/ogg` и т. п.) или multipart с полем `file`. Параметр `?language=ru` / `en` / `auto` (по умолчанию `VOICE_LANGUAGE`). Ответ: `{"text", "language", "duration_sec"}` |
| `GET /health` | `200 {"status":"ready"}` только после загрузки и прогрева модели, до того `503 {"status":"loading"}` (`failed` -- модель не загрузилась). Токен не нужен |

`/transcribe` требует `Authorization: Bearer <VOICE_TRANSCRIBER_API_TOKEN>`; сравнение через
`hmac.compare_digest`, проверка идёт до чтения тела. Коды отказа:

| Код | Когда |
|---|---|
| 401 | нет или неверный токен |
| 413 | тело больше `VOICE_MAX_BODY_BYTES` (проверяется по `Content-Length` и потоково) или аудио длиннее `VOICE_MAX_AUDIO_SEC` (проверяется по заголовку контейнера и по факту декодирования) |
| 422 | пустое тело, не аудио, неверный `language` |
| 503 | модель ещё грузится, расшифровка уже идёт и очередь не освободилась за `VOICE_QUEUE_TIMEOUT_SEC`, или в очереди уже `MAX_QUEUED_REQUESTS` запросов; есть `Retry-After` |

Расшифровка идёт по одной (`MAX_CONCURRENT_TRANSCRIPTIONS = 1`: на 4 vCPU вторая только
растягивает обе). Декодирование -- PyAV (идёт вместе с faster-whisper), отдельный ffmpeg не
нужен; ogg/opus Telegram разбирается напрямую. Свой декодер в `audio.py` вместо
`faster_whisper.decode_audio`: тот не ограничивает длительность и несовместим с PyAV 19
(`av.open(metadata_errors=...)`).

## Журнал

JSON-строки в stderr (формат `jsonlog.py`, как у `pseudonymizer`). В журнал не попадают ни
текст, ни аудио, ни имена файлов, ни токен, ни query-строка: только маршрут, статус, время,
`audio_sec`, число символов, `queue_wait_ms`, код языка. Событие `transcribed` -- успешная
расшифровка, `transcribe_failed` -- сбой движка, `model_load_failed` -- модель не загрузилась.

## Запуск

```bash
python3.12 -m venv .venv
.venv/bin/pip install -c constraints.txt -e ".[dev]"
# Веса -- вне репозитория (публичные веса Systran на Hugging Face, см. «Модели»)
export VOICE_MODEL_DIR="$HOME/voice-models"
export VOICE_TRANSCRIBER_API_TOKEN="$(.venv/bin/python -c 'import secrets; print(secrets.token_urlsafe(32))')"
.venv/bin/python -m voice_transcriber      # 127.0.0.1:8310
.venv/bin/python -m pytest -q
```

Сервис работает офлайн (`local_files_only=True`) и сам ничего не скачивает. Без токена
(короче 32 знаков) или без весов он не стартует (код выхода 1). Токен тот же кладётся агентам:
`~/.claude-lab/shared/secrets/voice-transcriber-token` (`chmod 600`) или
`VOICE_TRANSCRIBER_TOKEN` в `channel.env`; `agent-env.sh` и `new-agent.sh` его подхватывают.

Деплой: `deploy/voice-transcriber.service.template` и `deploy/voice-transcriber.env.example`
(копия env-файла вне репозитория, `chmod 600`). Юнит не устанавливается автоматически.

## Модели

Формат CTranslate2, веса публичные, версии зафиксированы по ревизии репозитория на момент
замера (04.11.2026). Скачивание в каталог вне репозитория:

```bash
.venv/bin/python - <<'PY'
from huggingface_hub import snapshot_download
snapshot_download("Systran/faster-whisper-small", local_dir="/home/labops/voice-models/faster-whisper-small")
PY
```

| Модель | Репозиторий | Размер на диске |
|---|---|---|
| `small` (по умолчанию) | https://huggingface.co/Systran/faster-whisper-small | 464 МБ |
| `medium` | https://huggingface.co/Systran/faster-whisper-medium | 1,5 ГБ |

Каталог весов: `<VOICE_MODEL_DIR>/faster-whisper-<VOICE_MODEL>`. Версии библиотек закреплены
в `constraints.txt` (`faster-whisper 1.2.1`, `ctranslate2 4.8.5`, `av 19.0.2`).

## Переменные окружения

| Переменная | Назначение | По умолчанию |
|---|---|---|
| `VOICE_TRANSCRIBER_API_TOKEN` | общий секрет API (Bearer), **обязателен**, >= 32 знаков | -- |
| `VOICE_MODEL_DIR` | каталог с весами, **обязателен** | -- |
| `VOICE_MODEL` | `tiny` / `base` / `small` / `medium` | `small` |
| `VOICE_LANGUAGE` | язык по умолчанию; `auto` -- определять по аудио | `ru` |
| `VOICE_BEAM_SIZE` | ширина луча | `1` |
| `VOICE_CPU_THREADS` | потоки CTranslate2 | `4` |
| `VOICE_MAX_AUDIO_SEC` | предел длительности (413 выше) | `180` |
| `VOICE_MAX_BODY_BYTES` | предел тела (413 выше); Bot API отдаёт до 20 МБ | `20971520` |
| `VOICE_QUEUE_TIMEOUT_SEC` | сколько запрос ждёт очереди до 503 | `20` |
| `VOICE_TRANSCRIBER_HOST` / `VOICE_TRANSCRIBER_PORT` | адрес прослушивания | `127.0.0.1` / `8310` |

## Замеры

Хост Fornex: 4 vCPU, общий с роем агентов и соседними задачами (во время замера load average
5-10, steal до 29 %), поэтому цифры пессимистичны и шумят. int8, 4 потока, русская речь,
синтезированная локально espeak-ng (по тексту ~ 1 мин; качество синтеза плохое, поэтому по
тексту модели сравнивать можно лишь грубо). Время -- на `transcribe()` после прогрева, звук в
ogg/opus 24 кбит/с.

| Модель, луч | Загрузка | RSS после загрузки | Пик RSS (VmHWM) | 10 с звука | 60 с звука |
|---|---|---|---|---|---|
| small, луч 5 | 4-8 с | 555 МБ | 900 МБ | 10-12 с | 75 с |
| small, луч 1 | 2-5 с | 555 МБ | 836 МБ | 5-10 с | 43 с |
| medium, луч 5 | 12 с | 1613 МБ | 2286 МБ | 28-30 с | 197 с |
| medium, луч 1 | 16 с | 1613 МБ | 2097 МБ | 30-36 с | 126 с |

Выбор: **small, луч 1**. Medium считает 60 с звука 3,3 минуты (3x медленнее реального времени)
и держит 2,3 ГБ при ~5 ГБ свободной памяти хоста; small укладывается в реальное время и в
900 МБ. Medium заметно точнее на трудной речи (на синтезе small исказил «коллеги»), так что
на хосте посвободнее (8+ vCPU) стоит взять `VOICE_MODEL=medium` с `MemoryMax=3G` и
`VOICE_MAX_AUDIO_SEC` не выше 60. `MemoryMax=1536M` для small: пик 900 МБ, запас 1,7x.

Прогрев: тишина одна не запускает энкодер/декодер (VAD её отрезает), поэтому прогрев гоняет
секунду шума без VAD, затем тишину через обычный путь. Медленный первый запрос без прогрева:
10-25 с против 5-10 с.

## Тесты

`.venv/bin/python -m pytest -q`: поддельный движок, синтетические wav и ogg/opus (кодируются
PyAV). Интеграционный тест на реальной русской фразе (`-m integration`) нужен весам в
`VOICE_MODEL_DIR` и `espeak-ng` (путь в `ESPEAK_BIN`); без них он пропускается.
