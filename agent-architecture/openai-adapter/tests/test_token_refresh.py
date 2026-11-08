"""Тесты обновления токена подписки в хуке flatten_system.

Проверяют настоящий Authenticator из LiteLLM: обмен refresh_token идёт на локальный
HTTP-сервер, имитирующий auth.openai.com. Запуск: python -m pytest -q openai-adapter/tests
"""
import base64
import json
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import flatten_system as fs  # noqa: E402
from litellm.llms.chatgpt import authenticator as auth_mod  # noqa: E402

HOUR = 3600
THREADS = 8
FRESH_AGE_H = 1
OLD_AGE_H = 30
LONG_EXP_H = 240


def make_jwt(iat: float, exp_hours: int = LONG_EXP_H) -> str:
    """JWT-подобная строка: нужны только iat и exp."""
    def enc(obj: dict) -> str:
        return base64.urlsafe_b64encode(json.dumps(obj).encode()).decode().rstrip("=")
    return ".".join([enc({"alg": "none"}), enc({"iat": int(iat), "exp": int(iat + exp_hours * HOUR)}), "sig"])


class FakeOAuth:
    """Локальный OAuth-сервер: считает обмены, выдаёт новые токены или ошибку."""

    def __init__(self, status: int = 200) -> None:
        self.calls = 0
        self.status = status
        outer = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *a):  # noqa: D401
                pass

            def do_POST(self):  # noqa: N802
                self.rfile.read(int(self.headers.get("content-length", 0)))
                outer.calls += 1
                time.sleep(0.05)  # окно для гонки параллельных потоков
                if outer.status != 200:
                    body = json.dumps({"error": "refresh_token_reused"}).encode()
                else:
                    now = time.time()
                    body = json.dumps({
                        "access_token": make_jwt(now), "id_token": make_jwt(now),
                        "refresh_token": f"refresh-{outer.calls}",
                    }).encode()
                self.send_response(outer.status)
                self.send_header("content-type", "application/json")
                self.send_header("content-length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}/oauth/token"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self) -> None:
        self.server.shutdown()


class TokenRefreshTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.oauth = FakeOAuth()
        self.addCleanup(self.oauth.close)
        patches = [
            mock.patch.dict("os.environ", {"CHATGPT_TOKEN_DIR": self.tmp.name}),
            mock.patch.object(auth_mod, "CHATGPT_OAUTH_TOKEN_URL", self.oauth.url),
            mock.patch.object(fs, "_last_refresh_at", 0.0),
        ]
        for p in patches:
            p.start()
            self.addCleanup(p.stop)
        self.auth_file = Path(self.tmp.name) / "auth.json"

    def write_auth(self, age_hours: float, refresh: str = "refresh-0") -> str:
        access = make_jwt(time.time() - age_hours * HOUR)
        self.auth_file.write_text(json.dumps({
            "access_token": access, "refresh_token": refresh, "id_token": access,
            "expires_at": int(time.time() + 10 * 24 * HOUR), "account_id": "acct",
        }))
        return access

    def stored(self) -> dict:
        return json.loads(self.auth_file.read_text())

    def test_patch_installed(self) -> None:
        self.assertTrue(fs.patch_status()["token_refresh"])
        self.assertTrue(fs.install_token_refresh_patch())  # идемпотентно
        method = auth_mod.Authenticator.get_access_token
        self.assertTrue(getattr(method, fs.AUTH_MARKER))
        self.assertFalse(getattr(getattr(method, fs.AUTH_ORIGINAL_ATTR), fs.AUTH_MARKER, False))

    def test_fresh_token_is_not_refreshed(self) -> None:
        access = self.write_auth(FRESH_AGE_H)
        self.assertEqual(auth_mod.Authenticator().get_access_token(), access)
        self.assertEqual(self.oauth.calls, 0)

    def test_old_token_refreshed_though_exp_is_far(self) -> None:
        old = self.write_auth(OLD_AGE_H)  # exp ещё через 8 суток: LiteLLM сам не обновил бы
        token = auth_mod.Authenticator().get_access_token()
        self.assertNotEqual(token, old)
        self.assertEqual(self.oauth.calls, 1)
        self.assertEqual(self.stored()["refresh_token"], "refresh-1")
        self.assertEqual(self.stored()["access_token"], token)

    def test_parallel_requests_make_one_exchange(self) -> None:
        self.write_auth(OLD_AGE_H)
        tokens: list[str] = []
        threads = [threading.Thread(
            target=lambda: tokens.append(auth_mod.Authenticator().get_access_token()))
            for _ in range(THREADS)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        self.assertEqual(self.oauth.calls, 1, "refresh_token одноразовый: обмен должен быть один")
        self.assertEqual(len(set(tokens)), 1)

    def test_force_refresh_and_cooldown(self) -> None:
        self.write_auth(FRESH_AGE_H)
        fs.force_token_refresh()
        self.assertEqual(self.oauth.calls, 1)
        fs.force_token_refresh()  # пачка 401: второй обмен не нужен
        self.assertEqual(self.oauth.calls, 1)

    def test_failure_hook_refreshes_on_401(self) -> None:
        import asyncio
        self.write_auth(FRESH_AGE_H)
        exc = type("E", (Exception,), {"status_code": 401})("token_expired")
        asyncio.run(fs.flatten_system.async_post_call_failure_hook({}, exc, None))
        self.assertEqual(self.oauth.calls, 1)

    def test_failure_hook_ignores_other_errors(self) -> None:
        import asyncio
        self.write_auth(FRESH_AGE_H)
        exc = type("E", (Exception,), {"status_code": 500})("boom")
        asyncio.run(fs.flatten_system.async_post_call_failure_hook({}, exc, None))
        self.assertEqual(self.oauth.calls, 0)

    def test_rejected_refresh_token_warns_and_request_continues(self) -> None:
        self.oauth.status = 400
        old = self.write_auth(OLD_AGE_H)
        with self.assertLogs(fs.LOGGER_NAME, level="WARNING") as logs:
            # по exp токен ещё "живой", запрос идёт со старым; ошибку скажет сам ChatGPT (401)
            self.assertEqual(auth_mod.Authenticator().get_access_token(), old)
        self.assertTrue(any("повторный вход" in r.getMessage() for r in logs.records))
        self.assertEqual(self.stored()["access_token"], old)  # файл не испорчен

    def test_max_age_from_environment(self) -> None:
        self.write_auth(OLD_AGE_H)
        with mock.patch.dict("os.environ", {fs.MAX_TOKEN_AGE_ENV: "100"}):
            auth_mod.Authenticator().get_access_token()
        self.assertEqual(self.oauth.calls, 0)

    def test_unparsable_age_leaves_litellm_logic(self) -> None:
        self.auth_file.write_text(json.dumps({
            "access_token": "not-a-jwt", "refresh_token": "r", "expires_at": int(time.time() + HOUR),
        }))
        self.assertEqual(auth_mod.Authenticator().get_access_token(), "not-a-jwt")
        self.assertEqual(self.oauth.calls, 0)

    def test_missing_names_disable_patch(self) -> None:
        with mock.patch.object(fs, "AUTH_MODULE_PATH", "no.such.module"):
            with self.assertLogs(fs.LOGGER_NAME, level="WARNING"):
                self.assertFalse(fs.install_token_refresh_patch())


if __name__ == "__main__":
    unittest.main()
