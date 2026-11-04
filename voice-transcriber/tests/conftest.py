"""Общие фикстуры: приложение с поддельным движком (модель в юнит-тестах не грузится)."""

from __future__ import annotations

import threading
import time
from collections.abc import Iterator
from pathlib import Path

import numpy as np
import pytest
from fastapi.testclient import TestClient

from voice_transcriber.api import create_app
from voice_transcriber.config import Settings
from voice_transcriber.engine import Transcript

API_TOKEN = "test-voice-token-0123456789abcdefghij"
AUTH_HEADERS = {"Authorization": f"Bearer {API_TOKEN}"}
FAKE_TEXT = "привет, это проверка"


class FakeEngine:
    """Поддельный движок: возвращает фиксированный текст, может «думать» и записывать вызовы."""

    def __init__(self, text: str = FAKE_TEXT, delay_sec: float = 0.0) -> None:
        self.text = text
        self.delay_sec = delay_sec
        self.calls: list[tuple[int, str | None]] = []
        self.gate = threading.Event()
        self.gate.set()

    def transcribe(self, samples: np.ndarray, language: str | None) -> Transcript:
        """Запоминает вызов, ждёт gate и delay_sec, отдаёт текст."""
        self.calls.append((samples.size, language))
        self.gate.wait(timeout=10)
        time.sleep(self.delay_sec)
        return Transcript(text=self.text, language=language or "ru")


def make_settings(**overrides: object) -> Settings:
    """Настройки для тестов; путь к модели условный (движок подменён)."""
    fields: dict[str, object] = {
        "api_token": API_TOKEN,
        "model_path": Path("/nonexistent"),
        "max_audio_sec": 30,
        "max_body_bytes": 1024 * 1024,
        "queue_timeout_sec": 0.3,
    }
    fields.update(overrides)
    return Settings(**fields)  # type: ignore[arg-type]


@pytest.fixture
def engine() -> FakeEngine:
    """Поддельный движок."""
    return FakeEngine()


@pytest.fixture
def client(engine: FakeEngine) -> Iterator[TestClient]:
    """Клиент с токеном; lifespan выполняется (модель «загружается» в фоне)."""
    app = create_app(make_settings(), lambda _settings: engine)
    with TestClient(app, headers=AUTH_HEADERS) as test_client:
        deadline = time.monotonic() + 5
        while test_client.get("/health").status_code != 200 and time.monotonic() < deadline:
            time.sleep(0.02)
        yield test_client
