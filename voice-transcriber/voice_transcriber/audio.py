"""Декодирование аудио в моно 16 кГц float32 через PyAV с жёстким пределом длительности.

Свой цикл вместо `faster_whisper.decode_audio`: тот декодирует файл целиком без предела
(сжатый файл на 20 МБ может оказаться часами звука и съесть память), а к PyAV 19 его вызов
`av.open(metadata_errors=...)` ещё и несовместим.
"""

from __future__ import annotations

import io
from dataclasses import dataclass

import av
import numpy as np

SAMPLE_RATE = 16_000
INT16_SCALE = 32768.0
MICROSECONDS = 1_000_000
# Допуск на неточность длительности контейнера, секунд
DURATION_SLACK_SEC = 1.0


class AudioError(ValueError):
    """Базовая ошибка входного аудио."""


class AudioDecodeError(AudioError):
    """Файл не удалось разобрать как аудио."""


class AudioTooLongError(AudioError):
    """Аудио длиннее допустимого."""


@dataclass(frozen=True, slots=True)
class DecodedAudio:
    """Результат декодирования.

    Attributes:
        samples: Моно float32 в диапазоне [-1, 1], 16 кГц.
        duration_sec: Длительность в секундах.
    """

    samples: np.ndarray
    duration_sec: float


def decode(data: bytes, max_duration_sec: float) -> DecodedAudio:
    """Декодирует аудио из байтов (ogg/opus, wav, mp3, ...).

    Args:
        data: Содержимое файла.
        max_duration_sec: Предел длительности.

    Raises:
        AudioDecodeError: Не аудио или файл повреждён.
        AudioTooLongError: Длительность больше предела.
    """
    max_samples = int((max_duration_sec + DURATION_SLACK_SEC) * SAMPLE_RATE)
    chunks: list[np.ndarray] = []
    total = 0
    try:
        with av.open(io.BytesIO(data), mode="r") as container:
            if not container.streams.audio:
                raise AudioDecodeError("no audio stream")
            declared = container.duration
            if declared is not None and declared / MICROSECONDS > max_duration_sec + (
                DURATION_SLACK_SEC
            ):
                raise AudioTooLongError(f"audio is longer than {max_duration_sec} s")
            resampler = av.AudioResampler(format="s16", layout="mono", rate=SAMPLE_RATE)
            for frame in container.decode(audio=0):
                for out in resampler.resample(frame):
                    chunk = out.to_ndarray().reshape(-1)
                    total += chunk.size
                    if total > max_samples:
                        raise AudioTooLongError(f"audio is longer than {max_duration_sec} s")
                    chunks.append(chunk)
            for out in resampler.resample(None):
                chunk = out.to_ndarray().reshape(-1)
                total += chunk.size
                chunks.append(chunk)
    except AudioError:
        raise
    except Exception as exc:  # noqa: BLE001 - PyAV бросает разные типы на мусорный вход
        raise AudioDecodeError("cannot decode audio") from exc
    if total == 0:
        raise AudioDecodeError("empty audio")
    if total / SAMPLE_RATE > max_duration_sec + DURATION_SLACK_SEC:
        raise AudioTooLongError(f"audio is longer than {max_duration_sec} s")
    samples = np.concatenate(chunks).astype(np.float32) / INT16_SCALE
    return DecodedAudio(samples=samples, duration_sec=total / SAMPLE_RATE)
