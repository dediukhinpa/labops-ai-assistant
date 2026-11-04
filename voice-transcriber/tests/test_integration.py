"""Интеграционный тест: реальная модель на русской речи, синтезированной локально.

Нужны веса в VOICE_MODEL_DIR и espeak-ng (путь в ESPEAK_BIN, при необходимости ещё
LD_LIBRARY_PATH и ESPEAK_DATA_PATH, если он распакован без установки). Без них тест
пропускается. Речь синтезируется офлайн: внешних сервисов тест не использует.
"""

from __future__ import annotations

import os
import subprocess
import time
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from tests.conftest import AUTH_HEADERS, make_settings
from voice_transcriber.api import create_app, load_faster_whisper
from voice_transcriber.config import MODEL_DIR_PREFIX

PHRASE = "Здравствуйте. Это проверка связи. Пожалуйста, пришлите отчёт до пятницы."
# Слова, которые small узнаёт даже в грубой синтезированной речи espeak (замер 04.11.2026:
# «здравствуйте! это парамерка смяне! ... отчет в пляднице» -- проверку и пятницу он не слышит)
EXPECTED_WORDS = ("здравствуйте", "это", "отчет")
ESPEAK_SPEED = "140"
SYNTH_TIMEOUT_SEC = 30
MODEL = os.environ.get("VOICE_MODEL", "small")
MODEL_DIR = os.environ.get("VOICE_MODEL_DIR", "")
ESPEAK_BIN = os.environ.get("ESPEAK_BIN", "")
READY_TIMEOUT_SEC = 300

pytestmark = [
    pytest.mark.integration,
    pytest.mark.skipif(
        not (MODEL_DIR and (Path(MODEL_DIR) / f"{MODEL_DIR_PREFIX}{MODEL}/model.bin").is_file()),
        reason="нет весов модели: задайте VOICE_MODEL_DIR",
    ),
    pytest.mark.skipif(
        not (ESPEAK_BIN and Path(ESPEAK_BIN).is_file()),
        reason="нет espeak-ng: задайте ESPEAK_BIN",
    ),
]


def synthesize(tmp_path: Path) -> bytes:
    """Русская фраза в wav через локальный espeak-ng."""
    out = tmp_path / "phrase.wav"
    subprocess.run(
        [ESPEAK_BIN, "-v", "ru", "-s", ESPEAK_SPEED, PHRASE, "-w", str(out)],
        check=True, timeout=SYNTH_TIMEOUT_SEC,
    )
    return out.read_bytes()


def test_real_model_transcribes_russian_phrase(tmp_path: Path) -> None:
    audio_bytes = synthesize(tmp_path)
    settings = make_settings(
        model_path=Path(MODEL_DIR) / f"{MODEL_DIR_PREFIX}{MODEL}",
        max_audio_sec=60, beam_size=1, queue_timeout_sec=60,
    )
    with TestClient(create_app(settings, load_faster_whisper), headers=AUTH_HEADERS) as client:
        deadline = time.monotonic() + READY_TIMEOUT_SEC
        while client.get("/health").status_code != 200 and time.monotonic() < deadline:
            time.sleep(0.5)
        assert client.get("/health").json()["status"] == "ready"
        resp = client.post(
            "/transcribe", content=audio_bytes, headers={"Content-Type": "audio/wav"}
        )
    assert resp.status_code == 200
    body = resp.json()
    assert body["language"] == "ru"
    text = body["text"].lower().replace("ё", "е")
    hits = [word for word in EXPECTED_WORDS if word in text]
    assert len(hits) >= 2, text
