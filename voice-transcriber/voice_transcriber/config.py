"""Конфигурация сервиса из переменных окружения."""

from __future__ import annotations

import os
from collections.abc import Mapping
from dataclasses import dataclass, field
from pathlib import Path

ENV_API_TOKEN = "VOICE_TRANSCRIBER_API_TOKEN"
ENV_HOST = "VOICE_TRANSCRIBER_HOST"
ENV_PORT = "VOICE_TRANSCRIBER_PORT"
ENV_MODEL = "VOICE_MODEL"
ENV_MODEL_DIR = "VOICE_MODEL_DIR"
ENV_LANGUAGE = "VOICE_LANGUAGE"
ENV_BEAM_SIZE = "VOICE_BEAM_SIZE"
ENV_CPU_THREADS = "VOICE_CPU_THREADS"
ENV_MAX_AUDIO_SEC = "VOICE_MAX_AUDIO_SEC"
ENV_MAX_BODY_BYTES = "VOICE_MAX_BODY_BYTES"
ENV_QUEUE_TIMEOUT_SEC = "VOICE_QUEUE_TIMEOUT_SEC"

DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 8310
# Модель по умолчанию выбрана по замеру на хосте 4 vCPU (README, «Замеры»).
DEFAULT_MODEL = "small"
SUPPORTED_MODELS = frozenset({"tiny", "base", "small", "medium"})
# Веса лежат в VOICE_MODEL_DIR/faster-whisper-<модель> (формат CTranslate2, Systran на HF).
MODEL_DIR_PREFIX = "faster-whisper-"
DEFAULT_LANGUAGE = "ru"
# Значение VOICE_LANGUAGE и параметра language запроса: определить язык по аудио.
LANGUAGE_AUTO = "auto"
# Жадное декодирование (1) вдвое быстрее луча 5 при малой потере точности (README, «Замеры»):
# на общем 4-vCPU хосте скорость важнее.
DEFAULT_BEAM_SIZE = 1
DEFAULT_CPU_THREADS = 4
# Предел длительности аудио. Замер small на хосте под нагрузкой: 60 с звука = 43 с счёта
# (луч 1), то есть 180 с ~ 130 с; вместе с очередью (20 с) это укладывается в таймаут
# клиента-плагина (180 с). Дольше -- 413, плагин покажет пометку «расшифровка недоступна».
DEFAULT_MAX_AUDIO_SEC = 180
# Предел тела запроса: Bot API отдаёт боту файлы до 20 МБ.
DEFAULT_MAX_BODY_BYTES = 20 * 1024 * 1024
# Сколько запрос ждёт свободного движка до 503. Расшифровка идёт по одной (RAM, CPU).
DEFAULT_QUEUE_TIMEOUT_SEC = 20.0
# Сколько расшифровок идёт одновременно: больше одной на 4 vCPU только растягивает каждую.
MAX_CONCURRENT_TRANSCRIPTIONS = 1
# Сколько запросов может стоять в очереди; следующие получают 503 сразу, не ожидая.
MAX_QUEUED_REQUESTS = 4
# Короткий токен легко подобрать: ниже этой длины сервис не стартует.
MIN_TOKEN_CHARS = 32
TRUE_VALUES = frozenset({"1", "true", "yes", "on"})


class ConfigError(RuntimeError):
    """Ошибка конфигурации: сервис не должен стартовать."""


@dataclass(frozen=True, slots=True)
class Settings:
    """Настройки сервиса.

    Attributes:
        api_token: Общий секрет клиентов (Authorization: Bearer ...); в repr не попадает.
        model_path: Каталог весов CTranslate2.
        model_name: Название модели (для логов и README).
        language: Код языка по умолчанию или None для автоопределения.
        beam_size: Ширина луча декодера.
        cpu_threads: Потоков CTranslate2.
        max_audio_sec: Предел длительности аудио, секунд.
        max_body_bytes: Предел тела запроса, байт.
        queue_timeout_sec: Сколько запрос ждёт движка до 503.
        host: Адрес прослушивания.
        port: Порт.
    """

    api_token: str = field(repr=False)
    model_path: Path
    model_name: str = DEFAULT_MODEL
    language: str | None = DEFAULT_LANGUAGE
    beam_size: int = DEFAULT_BEAM_SIZE
    cpu_threads: int = DEFAULT_CPU_THREADS
    max_audio_sec: int = DEFAULT_MAX_AUDIO_SEC
    max_body_bytes: int = DEFAULT_MAX_BODY_BYTES
    queue_timeout_sec: float = DEFAULT_QUEUE_TIMEOUT_SEC
    host: str = DEFAULT_HOST
    port: int = DEFAULT_PORT


def _positive_int(env: Mapping[str, str], name: str, default: int) -> int:
    """Целое > 0 из окружения; пусто -> default."""
    raw = env.get(name, "").strip()
    if not raw:
        return default
    try:
        value = int(raw)
    except ValueError as exc:
        raise ConfigError(f"{name}: ожидается целое число") from exc
    if value <= 0:
        raise ConfigError(f"{name}: значение должно быть больше нуля")
    return value


def load_settings(env: Mapping[str, str] | None = None) -> Settings:
    """Читает настройки из окружения.

    Args:
        env: Словарь окружения; по умолчанию os.environ.

    Raises:
        ConfigError: Нет токена или он короткий, неизвестная модель, нет каталога весов.
    """
    env = os.environ if env is None else env
    token = env.get(ENV_API_TOKEN, "").strip()
    if len(token) < MIN_TOKEN_CHARS:
        raise ConfigError(f"{ENV_API_TOKEN}: токен обязателен, не короче {MIN_TOKEN_CHARS} знаков")
    model = env.get(ENV_MODEL, "").strip() or DEFAULT_MODEL
    if model not in SUPPORTED_MODELS:
        raise ConfigError(f"{ENV_MODEL}: допустимо {sorted(SUPPORTED_MODELS)}")
    model_dir = env.get(ENV_MODEL_DIR, "").strip()
    if not model_dir:
        raise ConfigError(f"{ENV_MODEL_DIR}: не задан каталог с весами моделей")
    model_path = Path(model_dir).expanduser() / f"{MODEL_DIR_PREFIX}{model}"
    if not (model_path / "model.bin").is_file():
        # Скачивания на старте нет: веса кладёт оператор (README), сервис работает офлайн.
        raise ConfigError(f"нет весов модели: {model_path}/model.bin")
    language = env.get(ENV_LANGUAGE, "").strip().lower() or DEFAULT_LANGUAGE
    queue_timeout = env.get(ENV_QUEUE_TIMEOUT_SEC, "").strip()
    try:
        queue_timeout_sec = float(queue_timeout) if queue_timeout else DEFAULT_QUEUE_TIMEOUT_SEC
    except ValueError as exc:
        raise ConfigError(f"{ENV_QUEUE_TIMEOUT_SEC}: ожидается число") from exc
    return Settings(
        api_token=token,
        model_path=model_path,
        model_name=model,
        language=None if language == LANGUAGE_AUTO else language,
        beam_size=_positive_int(env, ENV_BEAM_SIZE, DEFAULT_BEAM_SIZE),
        cpu_threads=_positive_int(env, ENV_CPU_THREADS, DEFAULT_CPU_THREADS),
        max_audio_sec=_positive_int(env, ENV_MAX_AUDIO_SEC, DEFAULT_MAX_AUDIO_SEC),
        max_body_bytes=_positive_int(env, ENV_MAX_BODY_BYTES, DEFAULT_MAX_BODY_BYTES),
        queue_timeout_sec=queue_timeout_sec,
        host=env.get(ENV_HOST, "").strip() or DEFAULT_HOST,
        port=_positive_int(env, ENV_PORT, DEFAULT_PORT),
    )
