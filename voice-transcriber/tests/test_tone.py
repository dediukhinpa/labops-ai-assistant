"""Тон и тишина через реальную модель: пустой или короткий текст, без падения."""

from __future__ import annotations

import os
import time
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from tests.audio_factory import make_ogg_opus
from tests.conftest import AUTH_HEADERS, make_settings
from voice_transcriber.api import create_app, load_faster_whisper
from voice_transcriber.config import MODEL_DIR_PREFIX

MODEL = os.environ.get("VOICE_MODEL", "small")
MODEL_DIR = os.environ.get("VOICE_MODEL_DIR", "")
READY_TIMEOUT_SEC = 300
# Тон 440 Гц -- не речь: допустим пустой текст или пара коротких слов-галлюцинаций
MAX_TONE_CHARS = 40

pytestmark = [
    pytest.mark.integration,
    pytest.mark.skipif(
        not (MODEL_DIR and (Path(MODEL_DIR) / f"{MODEL_DIR_PREFIX}{MODEL}/model.bin").is_file()),
        reason="нет весов модели: задайте VOICE_MODEL_DIR",
    ),
]


@pytest.mark.parametrize("amplitude", [0.0, 0.3])
def test_non_speech_gives_short_text(amplitude: float) -> None:
    settings = make_settings(
        model_path=Path(MODEL_DIR) / f"{MODEL_DIR_PREFIX}{MODEL}", beam_size=1, queue_timeout_sec=60
    )
    with TestClient(create_app(settings, load_faster_whisper), headers=AUTH_HEADERS) as client:
        deadline = time.monotonic() + READY_TIMEOUT_SEC
        while client.get("/health").status_code != 200 and time.monotonic() < deadline:
            time.sleep(0.5)
        resp = client.post("/transcribe", content=make_ogg_opus(3.0, amplitude))
    assert resp.status_code == 200
    assert len(resp.json()["text"]) <= MAX_TONE_CHARS
