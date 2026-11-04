"""Синтетическое аудио для тестов: тон/тишина в wav и ogg/opus (формат голосовых Telegram)."""

from __future__ import annotations

import io
import wave

import av
import numpy as np

RATE = 16_000
TONE_HZ = 440.0
TONE_AMPLITUDE = 0.3
INT16_MAX = 32767
OPUS_RATE = 48_000
FRAME_SAMPLES = 960


def tone(seconds: float, amplitude: float = TONE_AMPLITUDE, rate: int = RATE) -> np.ndarray:
    """Синус 440 Гц (amplitude=0 -- тишина), моно float32."""
    t = np.arange(int(seconds * rate)) / rate
    return (amplitude * np.sin(2 * np.pi * TONE_HZ * t)).astype(np.float32)


def make_wav(seconds: float, amplitude: float = TONE_AMPLITUDE) -> bytes:
    """Моно 16 кГц wav заданной длительности."""
    pcm = (tone(seconds, amplitude) * INT16_MAX).astype(np.int16)
    buf = io.BytesIO()
    with wave.open(buf, "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(RATE)
        out.writeframes(pcm.tobytes())
    return buf.getvalue()


def make_ogg_opus(seconds: float, amplitude: float = TONE_AMPLITUDE) -> bytes:
    """ogg/opus (48 кГц, моно) -- как голосовое сообщение Telegram."""
    pcm = (tone(seconds, amplitude, OPUS_RATE) * INT16_MAX).astype(np.int16)
    buf = io.BytesIO()
    with av.open(buf, mode="w", format="ogg") as container:
        stream = container.add_stream("libopus", rate=OPUS_RATE)
        stream.layout = "mono"
        for start in range(0, pcm.size - FRAME_SAMPLES + 1, FRAME_SAMPLES):
            frame = av.AudioFrame.from_ndarray(
                pcm[start:start + FRAME_SAMPLES].reshape(1, -1), format="s16", layout="mono"
            )
            frame.sample_rate = OPUS_RATE
            for packet in stream.encode(frame):
                container.mux(packet)
        for packet in stream.encode(None):
            container.mux(packet)
    return buf.getvalue()
