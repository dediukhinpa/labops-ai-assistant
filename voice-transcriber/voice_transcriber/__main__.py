"""Точка входа: `python -m voice_transcriber`."""

from __future__ import annotations

import logging
import sys

import uvicorn

from voice_transcriber.api import create_app
from voice_transcriber.config import ConfigError, load_settings
from voice_transcriber.jsonlog import configure_logging

logger = logging.getLogger("voice_transcriber")


def main() -> int:
    """Запускает сервис; при неверной конфигурации выходит с кодом 1."""
    configure_logging(logging.INFO)
    try:
        settings = load_settings()
    except ConfigError as exc:
        # Текст ошибки не пишем: в нём может оказаться путь; достаточно класса и кода
        logger.error("Старт отменён: неверная конфигурация", extra={"code": type(exc).__name__})
        print(f"voice-transcriber: {exc}", file=sys.stderr)
        return 1
    app = create_app(settings)
    # log_config=None: всё логирование идёт через JSON-обработчик; access_log=False: запрос
    # логирует middleware (в access-логе uvicorn был бы сырой путь)
    uvicorn.run(
        app, host=settings.host, port=settings.port,
        log_level="info", log_config=None, access_log=False,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
