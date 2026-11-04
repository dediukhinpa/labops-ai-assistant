"""Движок расшифровки: протокол и реализация на faster-whisper (CTranslate2, CPU, int8)."""

from __future__ import annotations

import logging
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

import numpy as np

logger = logging.getLogger(__name__)

COMPUTE_TYPE = "int8"
DEVICE = "cpu"
# Секунд аудио для прогрева: хватает, чтобы прогнать энкодер и декодер один раз
WARMUP_SEC = 1
WARMUP_SAMPLE_RATE = 16_000
WARMUP_SEED = 0
WARMUP_NOISE_LEVEL = 0.05
WARMUP_LANGUAGE = "ru"


@dataclass(frozen=True, slots=True)
class Transcript:
    """Результат расшифровки.

    Attributes:
        text: Текст.
        language: Код языка (заданный или определённый).
    """

    text: str
    language: str


class Engine(Protocol):
    """Расшифровщик; реализации потокобезопасными быть не обязаны (вызов под семафором)."""

    def transcribe(self, samples: np.ndarray, language: str | None) -> Transcript:
        """Расшифровывает моно 16 кГц; language=None -- определить язык."""
        ...


class FasterWhisperEngine:
    """Обёртка над faster_whisper.WhisperModel.

    Args:
        model_path: Каталог весов CTranslate2.
        cpu_threads: Потоков CTranslate2.
        beam_size: Ширина луча.
    """

    def __init__(self, model_path: Path, cpu_threads: int, beam_size: int) -> None:
        # Импорт здесь: тесты с поддельным движком не тянут CTranslate2
        from faster_whisper import WhisperModel

        self._beam_size = beam_size
        self._model = WhisperModel(
            str(model_path),
            device=DEVICE,
            compute_type=COMPUTE_TYPE,
            cpu_threads=cpu_threads,
            local_files_only=True,
        )

    def warmup(self) -> None:
        """Прогоняет модель и VAD, чтобы первый настоящий запрос не платил за инициализацию.

        Тишина одна не годится: VAD отрезает её, и энкодер с декодером не запускаются. Поэтому
        сначала шум без VAD (греет Whisper), затем тишина через обычный путь (грузит VAD).
        """
        rng = np.random.default_rng(WARMUP_SEED)
        noise = rng.standard_normal(WARMUP_SEC * WARMUP_SAMPLE_RATE) * WARMUP_NOISE_LEVEL
        segments, _ = self._model.transcribe(
            noise.astype(np.float32),
            language=WARMUP_LANGUAGE,
            beam_size=self._beam_size,
            vad_filter=False,
        )
        for _segment in segments:  # генератор ленивый: без обхода декодер не запустится
            pass
        silence = np.zeros(WARMUP_SEC * WARMUP_SAMPLE_RATE, dtype=np.float32)
        self.transcribe(silence, WARMUP_LANGUAGE)

    def transcribe(self, samples: np.ndarray, language: str | None) -> Transcript:
        """См. Engine.transcribe. VAD отсекает тишину и снижает галлюцинации Whisper."""
        segments, info = self._model.transcribe(
            samples,
            language=language,
            beam_size=self._beam_size,
            vad_filter=True,
            condition_on_previous_text=False,
        )
        text = " ".join(seg.text.strip() for seg in segments).strip()
        return Transcript(text=text, language=info.language)
