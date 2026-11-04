"""Тесты API: авторизация, пределы, очередь, готовность, форматы входа."""

from __future__ import annotations

import threading
import time
from collections.abc import Callable

import pytest
from fastapi.testclient import TestClient

from tests.audio_factory import make_ogg_opus, make_wav
from tests.conftest import AUTH_HEADERS, FAKE_TEXT, FakeEngine, make_settings
from voice_transcriber.api import create_app
from voice_transcriber.engine import Engine

HTTP_OK = 200
HTTP_UNAUTHORIZED = 401
HTTP_TOO_LARGE = 413
HTTP_UNPROCESSABLE = 422
HTTP_BUSY = 503
SHORT_SEC = 1.0


def test_health_ready_after_load(client: TestClient) -> None:
    resp = client.get("/health")
    assert resp.status_code == HTTP_OK
    assert resp.json()["status"] == "ready"


def test_health_loading_until_model_loaded() -> None:
    release = threading.Event()

    def slow_factory(_settings: object) -> Engine:
        release.wait(timeout=10)
        return FakeEngine()

    app = create_app(make_settings(), slow_factory)
    with TestClient(app, headers=AUTH_HEADERS) as test_client:
        loading = test_client.get("/health")
        assert loading.status_code == HTTP_BUSY
        assert loading.json()["status"] == "loading"
        # До готовности модели расшифровка тоже 503
        early = test_client.post("/transcribe", content=make_wav(SHORT_SEC))
        assert early.status_code == HTTP_BUSY
        release.set()
        deadline = time.monotonic() + 5
        while test_client.get("/health").status_code != HTTP_OK and time.monotonic() < deadline:
            time.sleep(0.02)
        assert test_client.get("/health").json()["status"] == "ready"


def test_health_failed_when_model_cannot_load() -> None:
    def broken(_settings: object) -> Engine:
        raise RuntimeError("no weights")

    with TestClient(create_app(make_settings(), broken)) as test_client:
        time.sleep(0.2)
        resp = test_client.get("/health")
        assert resp.status_code == HTTP_BUSY
        assert resp.json()["status"] == "failed"


def test_transcribe_raw_ogg(client: TestClient, engine: FakeEngine) -> None:
    resp = client.post(
        "/transcribe", content=make_ogg_opus(2.0), headers={"Content-Type": "audio/ogg"}
    )
    assert resp.status_code == HTTP_OK
    body = resp.json()
    assert body["text"] == FAKE_TEXT
    assert body["language"] == "ru"
    assert body["duration_sec"] == pytest.approx(2.0, abs=0.1)
    # Язык по умолчанию из настроек -- ru
    assert engine.calls[0][1] == "ru"


def test_transcribe_multipart(client: TestClient) -> None:
    resp = client.post(
        "/transcribe", files={"file": ("voice.ogg", make_wav(SHORT_SEC), "audio/wav")}
    )
    assert resp.status_code == HTTP_OK
    assert resp.json()["text"] == FAKE_TEXT


def test_multipart_without_file_field(client: TestClient) -> None:
    resp = client.post("/transcribe", data={"x": "y"}, files={"other": ("a.wav", b"123")})
    assert resp.status_code == HTTP_UNPROCESSABLE


def test_language_param(client: TestClient, engine: FakeEngine) -> None:
    client.post("/transcribe?language=en", content=make_wav(SHORT_SEC))
    client.post("/transcribe?language=auto", content=make_wav(SHORT_SEC))
    assert [call[1] for call in engine.calls] == ["en", None]


def test_bad_language_rejected(client: TestClient) -> None:
    resp = client.post("/transcribe?language=../etc", content=make_wav(SHORT_SEC))
    assert resp.status_code == HTTP_UNPROCESSABLE


@pytest.mark.parametrize("headers", [{}, {"Authorization": "Bearer wrong-token"},
                                     {"Authorization": "Basic abc"}])
def test_unauthorized(headers: dict[str, str]) -> None:
    app = create_app(make_settings(), lambda _s: FakeEngine())
    with TestClient(app) as bare:
        resp = bare.post("/transcribe", content=make_wav(SHORT_SEC), headers=headers)
        assert resp.status_code == HTTP_UNAUTHORIZED


def test_health_needs_no_token() -> None:
    app = create_app(make_settings(), lambda _s: FakeEngine())
    with TestClient(app) as bare:
        time.sleep(0.2)
        assert bare.get("/health").status_code == HTTP_OK


def test_body_too_large_by_content_length(engine: FakeEngine) -> None:
    app = create_app(make_settings(max_body_bytes=1000), lambda _s: engine)
    with TestClient(app, headers=AUTH_HEADERS) as test_client:
        time.sleep(0.2)
        resp = test_client.post("/transcribe", content=b"0" * 5000)
        assert resp.status_code == HTTP_TOO_LARGE
        assert not engine.calls


def test_body_too_large_when_streamed(engine: FakeEngine) -> None:
    """Без Content-Length (chunked) предел всё равно срабатывает по счётчику байт."""
    app = create_app(make_settings(max_body_bytes=1000), lambda _s: engine)

    def chunks() -> Callable[[], object]:
        for _ in range(10):
            yield b"0" * 500

    with TestClient(app, headers=AUTH_HEADERS) as test_client:
        time.sleep(0.2)
        resp = test_client.post("/transcribe", content=chunks())
        assert resp.status_code == HTTP_TOO_LARGE
        assert not engine.calls


def test_audio_too_long(engine: FakeEngine) -> None:
    app = create_app(make_settings(max_audio_sec=2), lambda _s: engine)
    with TestClient(app, headers=AUTH_HEADERS) as test_client:
        time.sleep(0.2)
        resp = test_client.post("/transcribe", content=make_wav(5.0))
        assert resp.status_code == HTTP_TOO_LARGE
        assert "too long" in resp.json()["detail"]
        assert not engine.calls


def test_garbage_audio(client: TestClient, engine: FakeEngine) -> None:
    resp = client.post("/transcribe", content=b"not an audio file at all" * 50)
    assert resp.status_code == HTTP_UNPROCESSABLE
    assert not engine.calls


def test_empty_body(client: TestClient) -> None:
    assert client.post("/transcribe", content=b"").status_code == HTTP_UNPROCESSABLE


def test_engine_failure_is_500_without_details() -> None:
    class Broken(FakeEngine):
        def transcribe(self, samples, language):  # type: ignore[no-untyped-def]
            raise RuntimeError("secret internals")

    app = create_app(make_settings(), lambda _s: Broken())
    with TestClient(app, headers=AUTH_HEADERS) as test_client:
        time.sleep(0.2)
        resp = test_client.post("/transcribe", content=make_wav(SHORT_SEC))
        assert resp.status_code == 500
        assert "secret" not in resp.text


def test_queue_timeout_returns_503() -> None:
    """Второй запрос не дождался единственного слота: 503 с Retry-After."""
    busy = FakeEngine()
    busy.gate.clear()
    app = create_app(make_settings(queue_timeout_sec=0.2), lambda _s: busy)
    with TestClient(app, headers=AUTH_HEADERS) as test_client:
        time.sleep(0.2)
        results: list[int] = []
        first = threading.Thread(
            target=lambda: results.append(
                test_client.post("/transcribe", content=make_wav(SHORT_SEC)).status_code
            )
        )
        first.start()
        deadline = time.monotonic() + 3
        while not busy.calls and time.monotonic() < deadline:
            time.sleep(0.02)
        second = test_client.post("/transcribe", content=make_wav(SHORT_SEC))
        assert second.status_code == HTTP_BUSY
        assert second.headers["retry-after"]
        busy.gate.set()
        first.join(timeout=5)
        assert results == [HTTP_OK]
        # Слот освободился -- следующий запрос проходит
        assert test_client.post("/transcribe", content=make_wav(SHORT_SEC)).status_code == HTTP_OK


def test_only_one_transcription_at_a_time() -> None:
    """Параллельные запросы идут по одному: движок никогда не видит двух вызовов сразу."""
    active = {"now": 0, "max": 0}
    lock = threading.Lock()

    class Counting(FakeEngine):
        def transcribe(self, samples, language):  # type: ignore[no-untyped-def]
            with lock:
                active["now"] += 1
                active["max"] = max(active["max"], active["now"])
            time.sleep(0.1)
            with lock:
                active["now"] -= 1
            return super().transcribe(samples, language)

    app = create_app(make_settings(queue_timeout_sec=10), lambda _s: Counting())
    with TestClient(app, headers=AUTH_HEADERS) as test_client:
        time.sleep(0.2)
        codes: list[int] = []
        threads = [
            threading.Thread(
                target=lambda: codes.append(
                    test_client.post("/transcribe", content=make_wav(SHORT_SEC)).status_code
                )
            )
            for _ in range(3)
        ]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(timeout=10)
        assert codes == [HTTP_OK] * 3
        assert active["max"] == 1
