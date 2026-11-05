"""Точка входа: `python -m media_masker`."""

from __future__ import annotations

import logging
import sys

import uvicorn

from media_masker.api import create_app
from media_masker.config import ConfigError, load_settings
from media_masker.faces import FaceError
from media_masker.jsonlog import configure_logging
from media_masker.ocr import OcrError

logger = logging.getLogger("media_masker")


def main() -> int:
    """Запускает сервис; при неверной конфигурации или отсутствии Tesseract выходит с 1."""
    configure_logging(logging.INFO)
    try:
        settings = load_settings()
        app = create_app(settings)
    except (ConfigError, OcrError, FaceError) as exc:
        logger.error("Старт отменён", extra={"code": type(exc).__name__})
        return 1
    uvicorn.run(
        app, host=settings.host, port=settings.port, log_level="info", log_config=None,
        access_log=False,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
