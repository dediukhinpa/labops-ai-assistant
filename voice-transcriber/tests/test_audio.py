"""Тесты декодера: форматы, пределы длительности, мусор."""

from __future__ import annotations

import pytest

from tests.audio_factory import make_ogg_opus, make_wav
from voice_transcriber import audio

DURATION_TOLERANCE_SEC = 0.1
MAX_SEC = 30


def test_decode_wav() -> None:
    result = audio.decode(make_wav(2.0), MAX_SEC)
    assert result.duration_sec == pytest.approx(2.0, abs=DURATION_TOLERANCE_SEC)
    assert result.samples.dtype.name == "float32"
    assert abs(result.samples).max() <= 1.0


def test_decode_ogg_opus_resampled_to_16k() -> None:
    result = audio.decode(make_ogg_opus(3.0), MAX_SEC)
    assert result.duration_sec == pytest.approx(3.0, abs=DURATION_TOLERANCE_SEC)
    assert result.samples.size == pytest.approx(3.0 * audio.SAMPLE_RATE, rel=0.05)


def test_too_long_wav() -> None:
    with pytest.raises(audio.AudioTooLongError):
        audio.decode(make_wav(10.0), 2)


def test_too_long_ogg_without_declared_duration() -> None:
    with pytest.raises(audio.AudioTooLongError):
        audio.decode(make_ogg_opus(10.0), 2)


def test_garbage() -> None:
    with pytest.raises(audio.AudioDecodeError):
        audio.decode(b"definitely not audio" * 100, MAX_SEC)
