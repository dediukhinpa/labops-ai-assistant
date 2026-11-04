"""HTTP API сервиса расшифровки (FastAPI)."""

from __future__ import annotations

import asyncio
import hmac
import logging
import re
import threading
import time
from collections.abc import AsyncIterator, Callable
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException, Query, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel

from voice_transcriber import audio
from voice_transcriber.body_guard import BodyGuardMiddleware
from voice_transcriber.config import (
    LANGUAGE_AUTO,
    MAX_CONCURRENT_TRANSCRIPTIONS,
    MAX_QUEUED_REQUESTS,
    Settings,
)
from voice_transcriber.engine import Engine, FasterWhisperEngine
from voice_transcriber.jsonlog import (
    EVENT_MODEL_FAILED,
    EVENT_MODEL_READY,
    EVENT_SERVICE_STARTED,
    EVENT_SERVICE_STOPPED,
    EVENT_TRANSCRIBE_FAILED,
    EVENT_TRANSCRIBED,
    JsonLogMiddleware,
    log_event,
)

logger = logging.getLogger(__name__)

BEARER_SCHEME = "bearer"
HTTP_TOO_LARGE = 413
HTTP_UNPROCESSABLE = 422
HTTP_INTERNAL_ERROR = 500
HTTP_BUSY = 503
RETRY_AFTER_SEC = "5"
GUARDED_PATHS = ("/transcribe",)
MULTIPART_PREFIX = "multipart/form-data"
MULTIPART_FIELD = "file"
LANGUAGE_RE = re.compile(r"[a-z]{2,3}")
MS_IN_SECOND = 1000.0
DURATION_DIGITS = 2
STATE_LOADING = "loading"
STATE_READY = "ready"
STATE_FAILED = "failed"

EngineFactory = Callable[[Settings], Engine]


class TranscribeResponse(BaseModel):
    """Ответ расшифровки."""

    text: str
    language: str
    duration_sec: float


def load_faster_whisper(settings: Settings) -> Engine:
    """Загружает модель и прогревает её (иначе первый запрос ждёт инициализацию)."""
    engine = FasterWhisperEngine(settings.model_path, settings.cpu_threads, settings.beam_size)
    engine.warmup()
    return engine


def create_app(settings: Settings, engine_factory: EngineFactory = load_faster_whisper) -> FastAPI:
    """Собирает приложение.

    Модель грузится в фоновом потоке после старта: порт открывается сразу, `/health` отвечает
    503 `loading`, пока загрузка и прогрев не закончены; `/transcribe` до этого тоже 503.

    Args:
        settings: Настройки.
        engine_factory: Создаёт движок (в тестах подменяется поддельным).
    """
    expected_token = settings.api_token.encode()
    state = {"value": STATE_LOADING}
    holder: dict[str, Engine] = {}
    slots = asyncio.Semaphore(MAX_CONCURRENT_TRANSCRIPTIONS)
    queue_lock = threading.Lock()
    waiting = {"count": 0}

    def token_valid(authorization: str) -> bool:
        """Значение заголовка Authorization - «Bearer <секрет>» с верным секретом."""
        scheme, _, supplied = authorization.partition(" ")
        # compare_digest по байтам: строка не-ASCII иначе вызвала бы TypeError (500)
        return scheme.lower() == BEARER_SCHEME and hmac.compare_digest(
            supplied.strip().encode("utf-8", "surrogateescape"), expected_token
        )

    def load_model() -> None:
        """Фоновая загрузка модели; итог пишется в state."""
        started = time.perf_counter()
        try:
            holder["engine"] = engine_factory(settings)
        except Exception as exc:  # noqa: BLE001 - любой сбой загрузки = сервис не готов
            state["value"] = STATE_FAILED
            log_event(
                logger, EVENT_MODEL_FAILED, logging.CRITICAL, exc_type=type(exc).__name__
            )
            return
        state["value"] = STATE_READY
        elapsed = round((time.perf_counter() - started) * MS_IN_SECOND, 1)
        log_event(logger, EVENT_MODEL_READY, duration_ms=elapsed)

    @asynccontextmanager
    async def lifespan(_app: FastAPI) -> AsyncIterator[None]:
        log_event(logger, EVENT_SERVICE_STARTED)
        loader = asyncio.create_task(asyncio.to_thread(load_model))
        try:
            yield
        finally:
            loader.cancel()
            log_event(logger, EVENT_SERVICE_STOPPED)

    app = FastAPI(title="voice-transcriber", lifespan=lifespan)
    # Токен и предел тела - до чтения тела (иначе файл на сотни МБ попадает в память).
    app.add_middleware(
        BodyGuardMiddleware,
        max_body_bytes=settings.max_body_bytes,
        authorize=token_valid,
        guarded_paths=GUARDED_PATHS,
    )
    # Добавлен последним, значит внешний: логирует и отказы BodyGuard (401/413)
    app.add_middleware(JsonLogMiddleware)

    def resolve_language(requested: str | None) -> str | None:
        """Язык запроса: код, `auto` (None -- определить) или значение по умолчанию."""
        if requested is None or not requested.strip():
            return settings.language
        value = requested.strip().lower()
        if value == LANGUAGE_AUTO:
            return None
        if LANGUAGE_RE.fullmatch(value) is None:
            raise HTTPException(HTTP_UNPROCESSABLE, "language must be a code like 'ru' or 'auto'")
        return value

    async def read_audio(request: Request) -> bytes:
        """Тело запроса: raw или поле `file` формы multipart."""
        content_type = request.headers.get("content-type", "").lower()
        if content_type.startswith(MULTIPART_PREFIX):
            form = await request.form()
            upload = form.get(MULTIPART_FIELD)
            if upload is None or isinstance(upload, str):
                raise HTTPException(HTTP_UNPROCESSABLE, "multipart field 'file' is required")
            return await upload.read()
        return await request.body()

    @app.post("/transcribe", response_model=TranscribeResponse)
    async def transcribe(
        request: Request, language: str | None = Query(default=None)
    ) -> TranscribeResponse | JSONResponse:
        if state["value"] != STATE_READY:
            return _busy("model is not ready")
        lang = resolve_language(language)
        data = await read_audio(request)
        if not data:
            raise HTTPException(HTTP_UNPROCESSABLE, "empty request body")
        with queue_lock:
            if waiting["count"] >= MAX_QUEUED_REQUESTS:
                return _busy("service is busy, retry later")
            waiting["count"] += 1
        queued_at = time.perf_counter()
        try:
            await asyncio.wait_for(slots.acquire(), timeout=settings.queue_timeout_sec)
        except asyncio.TimeoutError:
            return _busy("service is busy, retry later")
        finally:
            with queue_lock:
                waiting["count"] -= 1
        queue_wait_ms = round((time.perf_counter() - queued_at) * MS_IN_SECOND, 1)
        try:
            return await _process(data, lang, queue_wait_ms)
        finally:
            slots.release()

    async def _process(
        data: bytes, lang: str | None, queue_wait_ms: float
    ) -> TranscribeResponse:
        """Декодирование и расшифровка под занятым слотом; ошибки сводятся к HTTP-кодам."""
        started = time.perf_counter()
        try:
            decoded = await asyncio.to_thread(audio.decode, data, settings.max_audio_sec)
        except audio.AudioTooLongError as exc:
            raise HTTPException(
                HTTP_TOO_LARGE, f"audio is too long: limit is {settings.max_audio_sec} s"
            ) from exc
        except audio.AudioDecodeError as exc:
            raise HTTPException(HTTP_UNPROCESSABLE, "cannot decode audio") from exc
        try:
            result = await asyncio.to_thread(holder["engine"].transcribe, decoded.samples, lang)
        except Exception as exc:  # noqa: BLE001 - наружу только общий 500, без деталей
            log_event(
                logger, EVENT_TRANSCRIBE_FAILED, logging.ERROR,
                exc_type=type(exc).__name__, audio_sec=round(decoded.duration_sec, 2),
            )
            raise HTTPException(HTTP_INTERNAL_ERROR, "transcription failed") from exc
        elapsed_ms = round((time.perf_counter() - started) * MS_IN_SECOND, 1)
        log_event(
            logger, EVENT_TRANSCRIBED,
            audio_sec=round(decoded.duration_sec, DURATION_DIGITS), chars=len(result.text),
            queue_wait_ms=queue_wait_ms, duration_ms=elapsed_ms, language=result.language,
        )
        return TranscribeResponse(
            text=result.text,
            language=result.language,
            duration_sec=round(decoded.duration_sec, DURATION_DIGITS),
        )

    @app.get("/health")
    def health() -> JSONResponse:
        """200 `ready` только после загрузки и прогрева модели, до того 503."""
        value = state["value"]
        code = 200 if value == STATE_READY else HTTP_BUSY
        return JSONResponse({"status": value, "model": settings.model_name}, status_code=code)

    return app


def _busy(detail: str) -> JSONResponse:
    """Ответ 503 с подсказкой, когда повторить."""
    return JSONResponse(
        {"detail": detail}, status_code=HTTP_BUSY, headers={"Retry-After": RETRY_AFTER_SEC}
    )
