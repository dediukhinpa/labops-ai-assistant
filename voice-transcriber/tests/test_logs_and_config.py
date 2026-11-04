"""Логи не содержат ни текста, ни имён файлов; конфигурация отказывает на плохих значениях."""

from __future__ import annotations

import io
import json
import logging
import threading
import time
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from tests.audio_factory import make_wav
from tests.conftest import API_TOKEN, AUTH_HEADERS, FakeEngine, make_settings
from voice_transcriber.api import create_app
from voice_transcriber.config import ConfigError, load_settings
from voice_transcriber.jsonlog import JsonFormatter

LOG_TEXT = "очень секретная фраза про Иванова Ивана"


def test_logs_have_no_content() -> None:
    stream = io.StringIO()
    handler = logging.StreamHandler(stream)
    handler.setFormatter(JsonFormatter())
    root = logging.getLogger()
    root.addHandler(handler)
    old_level = root.level
    root.setLevel(logging.INFO)
    try:
        app = create_app(make_settings(), lambda _s: FakeEngine(text=LOG_TEXT))
        with TestClient(app, headers=AUTH_HEADERS) as client:
            time.sleep(0.2)
            client.post(
                "/transcribe?language=ru",
                files={"file": ("ivanov_secret_name.wav", make_wav(1.0), "audio/wav")},
            )
            client.post("/transcribe", content=b"junk", headers={"Authorization": "Bearer bad"})
    finally:
        root.removeHandler(handler)
        root.setLevel(old_level)
    raw = stream.getvalue()
    records = [json.loads(line) for line in raw.splitlines() if line.strip()]
    events = {record["event"] for record in records}
    assert {"service_started", "model_ready", "transcribed", "http_request"} <= events
    for forbidden in (LOG_TEXT, "Иванов", "ivanov_secret_name", API_TOKEN, "bad"):
        assert forbidden not in raw
    done = next(record for record in records if record["event"] == "transcribed")
    assert done["chars"] == len(LOG_TEXT)
    assert done["audio_sec"] == pytest.approx(1.0, abs=0.1)


def test_busy_503_is_warning_not_failure() -> None:
    """Загрузка модели и занятая очередь -- ожидаемые 503: не класс serious."""
    stream = io.StringIO()
    handler = logging.StreamHandler(stream)
    handler.setFormatter(JsonFormatter())
    root = logging.getLogger()
    root.addHandler(handler)
    old_level = root.level
    root.setLevel(logging.INFO)
    try:
        release = threading.Event()

        def slow(_settings: object) -> FakeEngine:
            release.wait(timeout=10)
            return FakeEngine()

        with TestClient(create_app(make_settings(), slow)) as client:
            assert client.get("/health").status_code == 503
            release.set()
    finally:
        root.removeHandler(handler)
        root.setLevel(old_level)
    rejected = [json.loads(x) for x in stream.getvalue().splitlines() if "http_request" in x]
    assert rejected and all(r["severity"] == "warning" for r in rejected)


def make_env(tmp_path: Path, **overrides: str) -> dict[str, str]:
    """Окружение с корректными значениями и подготовленным каталогом весов."""
    weights = tmp_path / "faster-whisper-small"
    weights.mkdir()
    (weights / "model.bin").write_bytes(b"x")
    env = {
        "VOICE_TRANSCRIBER_API_TOKEN": API_TOKEN,
        "VOICE_MODEL_DIR": str(tmp_path),
    }
    env.update(overrides)
    return env


def test_load_settings_defaults(tmp_path: Path) -> None:
    settings = load_settings(make_env(tmp_path))
    assert settings.model_name == "small"
    assert settings.language == "ru"
    assert settings.host == "127.0.0.1"
    assert API_TOKEN not in repr(settings)


def test_language_auto_means_none(tmp_path: Path) -> None:
    assert load_settings(make_env(tmp_path, VOICE_LANGUAGE="auto")).language is None


@pytest.mark.parametrize(
    "overrides",
    [
        {"VOICE_TRANSCRIBER_API_TOKEN": "short"},
        {"VOICE_TRANSCRIBER_API_TOKEN": ""},
        {"VOICE_MODEL": "gigantic"},
        {"VOICE_MODEL": "medium"},  # весов medium в каталоге нет
        {"VOICE_MODEL_DIR": ""},
        {"VOICE_MAX_AUDIO_SEC": "0"},
        {"VOICE_MAX_AUDIO_SEC": "abc"},
    ],
)
def test_load_settings_rejects(tmp_path: Path, overrides: dict[str, str]) -> None:
    with pytest.raises(ConfigError):
        load_settings(make_env(tmp_path, **overrides))
