"""Тесты выбора харнеса в webhook-listener/listener.py.

Проверяется:
- харнес берётся из $CLAUDE_LAB/shared/swarm.env (нет файла/строки — claude, мусор — отказ);
- для claude argv и окружение прежние (`claude -p ... --dangerously-skip-permissions`);
- для codex: `codex exec --skip-git-repo-check <prompt>`, CODEX_HOME агента, AGENT_BEARER
  из agent.env и никаких других секретов, stdin закрыт, cwd — рабочая папка агента;
- без config.toml агента listener на codex не стартует (иначе мимо pii-proxy).
"""

from __future__ import annotations

import asyncio
import importlib.util
import os
import sys
import tempfile
import unittest
from importlib.machinery import SourceFileLoader
from pathlib import Path
from types import ModuleType
from typing import Any
from unittest import mock

REPO_ROOT = Path(__file__).resolve().parents[1]
LISTENER_PATH = REPO_ROOT / "webhook-listener" / "listener.py"
MODULE_NAME = "webhook_listener_harness_under_test"
AGENT_ID = "testagent"
BEARER_VALUE = "agent-bearer-value"
PROMPT = "Inter-agent task delivered via swarm webhook."

# Переменные, которые тесты выставляют в os.environ и обязаны вернуть назад.
_TOUCHED_ENV = (
    "WEBHOOK_BEARER_FILE", "WEBHOOK_LOG_DIR", "WEBHOOK_AGENT_WORKSPACE", "WEBHOOK_AGENT_NAME",
    "CLAUDE_LAB", "WEBHOOK_CODEX_HOME", "CODEX_BIN", "CLAUDE_BIN",
    "WEBHOOK_SECOND_BRAIN_AGENT_ROUTER_URL", "WEBHOOK_OWNER_CHAT_ID",
    "ANTHROPIC_API_KEY", "CLAUDE_HARNESS_MARKER", "SECRET_FOO", "OPENAI_API_KEY",
    "INVOCATION_TIMEOUT_SEC",
)
PROXY_TOML = (
    'model_provider = "labops-pii"\n'
    "[model_providers.labops-pii]\n"
    'base_url = "http://127.0.0.1:6399/backend-api/codex"\n'
)
# Сколько ждём, пока убитая по таймауту группа процессов исчезнет.
KILL_WAIT_SEC = 10
POLL_SEC = 0.1


class _Lab:
    """Песочная лаборатория: <lab>/shared/swarm.env, <lab>/<agent>/.claude и .codex."""

    def __init__(self, root: Path) -> None:
        self.root = root
        self.lab = root / "lab"
        self.workspace = self.lab / AGENT_ID / ".claude"
        self.codex_home = self.lab / AGENT_ID / ".codex"
        self.workspace.mkdir(parents=True)
        (self.lab / "shared").mkdir()

    def set_swarm(self, text: str) -> None:
        (self.lab / "shared" / "swarm.env").write_text(text, encoding="utf-8")

    def add_codex_config(self, text: str = 'model = "m"\n') -> None:
        self.codex_home.mkdir(parents=True, exist_ok=True)
        (self.codex_home / "config.toml").write_text(text, encoding="utf-8")

    def set_agent_env(self, text: str) -> None:
        (self.workspace / "agent.env").write_text(text, encoding="utf-8")

    def load(self) -> ModuleType:
        """Загрузить listener.py заново с окружением, указывающим в песочницу."""
        bearer_file = self.root / "bearer.token"
        bearer_file.write_text("listener-bearer\n", encoding="utf-8")
        log_dir = self.root / "log"
        log_dir.mkdir(exist_ok=True)
        os.environ["WEBHOOK_BEARER_FILE"] = str(bearer_file)
        os.environ["WEBHOOK_LOG_DIR"] = str(log_dir)
        os.environ["WEBHOOK_AGENT_WORKSPACE"] = str(self.workspace)
        os.environ["WEBHOOK_AGENT_NAME"] = AGENT_ID
        os.environ["CLAUDE_LAB"] = str(self.lab)
        os.environ.pop("WEBHOOK_SECOND_BRAIN_AGENT_ROUTER_URL", None)
        os.environ.pop("WEBHOOK_OWNER_CHAT_ID", None)
        sys.modules.pop(MODULE_NAME, None)
        loader = SourceFileLoader(MODULE_NAME, str(LISTENER_PATH))
        spec = importlib.util.spec_from_loader(MODULE_NAME, loader)
        assert spec is not None
        module = importlib.util.module_from_spec(spec)
        sys.modules[MODULE_NAME] = module
        loader.exec_module(module)
        return module


class _EnvGuard(unittest.TestCase):
    """Сохраняет и восстанавливает os.environ вокруг каждого теста."""

    def setUp(self) -> None:
        self._saved = {k: os.environ.get(k) for k in _TOUCHED_ENV}
        for key in ("WEBHOOK_CODEX_HOME", "CODEX_BIN", "CLAUDE_BIN", "INVOCATION_TIMEOUT_SEC"):
            os.environ.pop(key, None)
        self._tmp = tempfile.TemporaryDirectory()
        self.lab = _Lab(Path(self._tmp.name))

    def tearDown(self) -> None:
        self._tmp.cleanup()
        sys.modules.pop(MODULE_NAME, None)
        for key, val in self._saved.items():
            if val is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = val


class HarnessSelectionTest(_EnvGuard):
    def test_no_swarm_env_means_claude(self) -> None:
        self.assertEqual(self.lab.load().HARNESS, "claude")

    def test_swarm_env_without_harness_means_claude(self) -> None:
        self.lab.set_swarm("OTHER=1\n")
        self.assertEqual(self.lab.load().HARNESS, "claude")

    def test_codex_selected_last_line_wins_quotes_stripped(self) -> None:
        self.lab.add_codex_config()
        self.lab.set_swarm("HARNESS=claude\n  HARNESS=\"codex\"  \n")
        self.assertEqual(self.lab.load().HARNESS, "codex")

    def test_unknown_harness_aborts_startup(self) -> None:
        self.lab.set_swarm("HARNESS=gemini\n")
        with self.assertRaises(SystemExit):
            self.lab.load()

    def test_codex_without_config_toml_aborts_startup(self) -> None:
        self.lab.set_swarm("HARNESS=codex\n")
        with self.assertRaises(SystemExit):
            self.lab.load()

    def test_codex_home_override(self) -> None:
        other = self.lab.root / "elsewhere"
        other.mkdir()
        (other / "config.toml").write_text("", encoding="utf-8")
        self.lab.set_swarm("HARNESS=codex\n")
        os.environ["WEBHOOK_CODEX_HOME"] = str(other)
        self.assertEqual(self.lab.load().CODEX_HOME, other)


class ClaudeCommandTest(_EnvGuard):
    def test_claude_argv_unchanged(self) -> None:
        os.environ["CLAUDE_BIN"] = "/opt/bin/claude"
        module = self.lab.load()
        argv, env = module._headless_command(PROMPT)
        self.assertEqual(
            argv, ["/opt/bin/claude", "-p", PROMPT, "--dangerously-skip-permissions"])
        self.assertEqual(env, module._build_subprocess_env())
        self.assertNotIn("CODEX_HOME", env)

    def test_claude_does_not_get_agent_bearer(self) -> None:
        self.lab.set_agent_env(f'export AGENT_BEARER="{BEARER_VALUE}"\n')
        _, env = self.lab.load()._headless_command(PROMPT)
        self.assertNotIn("AGENT_BEARER", env)


class CodexCommandTest(_EnvGuard):
    def setUp(self) -> None:
        super().setUp()
        self.lab.add_codex_config()
        self.lab.set_swarm("HARNESS=codex\n")

    def test_codex_argv(self) -> None:
        os.environ["CODEX_BIN"] = "/opt/bin/codex"
        argv, _ = self.lab.load()._headless_command(PROMPT)
        self.assertEqual(argv, ["/opt/bin/codex", "exec", "--skip-git-repo-check", PROMPT])

    def test_codex_bin_default_is_user_local(self) -> None:
        argv, _ = self.lab.load()._headless_command(PROMPT)
        self.assertEqual(argv[0], str(Path.home() / ".local" / "bin" / "codex"))

    def test_codex_env_has_codex_home_and_bearer_only(self) -> None:
        self.lab.set_agent_env(
            "# runtime env\n"
            f'export AGENT_BEARER="{BEARER_VALUE}"\n'
            'export SECOND_BRAIN_TASKS_URL="http://127.0.0.1:5003/mcp"\n'
        )
        os.environ["ANTHROPIC_API_KEY"] = "anthropic-secret"
        os.environ["CLAUDE_HARNESS_MARKER"] = "yes"
        os.environ["SECRET_FOO"] = "should-not-leak"
        os.environ["OPENAI_API_KEY"] = "openai-secret"
        module = self.lab.load()
        (self.lab.workspace / "settings.json").write_text(
            '{"env": {"ANTHROPIC_BASE_URL": "http://127.0.0.1:6311"}}', encoding="utf-8")
        _, env = module._headless_command(PROMPT)
        self.assertEqual(env["CODEX_HOME"], str(self.lab.codex_home))
        self.assertEqual(env["AGENT_BEARER"], BEARER_VALUE)
        allowed = set(module._SUBPROCESS_ENV_ALLOW) | {"CODEX_HOME", "AGENT_BEARER"}
        self.assertLessEqual(set(env), allowed)
        for leaked in ("ANTHROPIC_API_KEY", "CLAUDE_HARNESS_MARKER", "SECRET_FOO",
                       "OPENAI_API_KEY", "ANTHROPIC_BASE_URL", "SECOND_BRAIN_TASKS_URL",
                       "WEBHOOK_BEARER_FILE"):
            self.assertNotIn(leaked, env)
        self.assertIn("HOME", env)

    def test_placeholder_or_missing_bearer_not_forwarded(self) -> None:
        module = self.lab.load()
        _, env = module._headless_command(PROMPT)
        self.assertNotIn("AGENT_BEARER", env)
        self.lab.set_agent_env("AGENT_BEARER=CHANGE_ME\n")
        _, env = module._headless_command(PROMPT)
        self.assertNotIn("AGENT_BEARER", env)

    def test_spawn_closes_stdin_and_runs_in_workspace(self) -> None:
        module = self.lab.load()
        seen: dict[str, Any] = {}

        class _FakeProc:
            returncode = 0

            async def wait(self) -> int:
                return 0

        async def _fake_exec(*argv: str, **kwargs: Any) -> _FakeProc:
            seen["argv"] = list(argv)
            seen.update(kwargs)
            return _FakeProc()

        async def run() -> None:
            await module._spawn_headless(PROMPT, "task-1")
            await asyncio.sleep(0)

        with mock.patch.object(module.asyncio, "create_subprocess_exec", _fake_exec):
            asyncio.run(run())
        self.assertEqual(seen["argv"][1:3], ["exec", "--skip-git-repo-check"])
        self.assertIs(seen["stdin"], asyncio.subprocess.DEVNULL)
        self.assertEqual(seen["cwd"], str(self.lab.workspace))
        self.assertEqual(seen["env"]["CODEX_HOME"], str(self.lab.codex_home))


class PiiProxyGateTest(_EnvGuard):
    """codex не запускается, пока pii-proxy агента не отвечает на /health."""

    def _load_codex(self, toml: str = PROXY_TOML) -> ModuleType:
        self.lab.add_codex_config(toml)
        self.lab.set_swarm("HARNESS=codex\n")
        return self.lab.load()

    def test_proxy_url_parsed_from_config(self) -> None:
        module = self._load_codex()
        self.assertEqual(
            module._codex_pii_proxy_url(self.lab.codex_home / "config.toml"),
            "http://127.0.0.1:6399")

    def test_non_local_or_missing_provider_means_no_proxy(self) -> None:
        module = self._load_codex()
        cfg = self.lab.codex_home / "config.toml"
        for text in ('model = "m"\n',
                     PROXY_TOML.replace("127.0.0.1:6399", "example.com:443"),
                     "not = [toml"):
            cfg.write_text(text, encoding="utf-8")
            self.assertEqual(module._codex_pii_proxy_url(cfg), "")

    def test_ready_depends_on_health(self) -> None:
        module = self._load_codex()
        for healthy in (True, False):
            async def _fake_health(url: str, _ok: bool = healthy) -> bool:
                self.assertEqual(url, "http://127.0.0.1:6399")
                return _ok
            module._pii_proxy_healthy = _fake_health
            self.assertIs(asyncio.run(module._harness_ready()), healthy)

    def test_ready_without_proxy_or_for_claude(self) -> None:
        module = self._load_codex('model = "m"\n')
        self.assertTrue(asyncio.run(module._harness_ready()))
        self.lab.set_swarm("HARNESS=claude\n")
        module = self.lab.load()
        self.assertTrue(asyncio.run(module._harness_ready()))

    def test_unreachable_proxy_reports_unhealthy(self) -> None:
        # Порт 1 на loopback никто не слушает: соединение отклоняется сразу.
        module = self._load_codex()
        self.assertFalse(asyncio.run(module._pii_proxy_healthy("http://127.0.0.1:1")))

    def test_webhook_with_dead_proxy_is_not_acked_or_spawned(self) -> None:
        module = self._load_codex()
        calls: list[str] = []

        async def _dead(_url: str) -> bool:
            return False

        async def _fake_spawn(_prompt: str, _task_id: str) -> None:
            calls.append("spawn")

        async def _fake_notify(*_args: Any) -> None:
            calls.append("notify")

        module._pii_proxy_healthy = _dead
        module._spawn_headless = _fake_spawn
        module._notify_owner = _fake_notify

        class _FakeRequest:
            remote = "127.0.0.1"
            headers = {"Authorization": "Bearer listener-bearer"}

            async def read(self) -> bytes:
                return b'{"task_id": "t-1", "from_agent": "boss", "title": "x"}'

        resp = asyncio.run(module.handle_webhook(_FakeRequest()))
        # Не 2xx — воркер доставки не помечает задачу acked и повторит доставку.
        self.assertEqual(resp.status, 503)
        self.assertEqual(calls, [])


class CodexTimeoutKillTest(_EnvGuard):
    """По INVOCATION_TIMEOUT_SEC убивается вся группа процессов codex, а не только он."""

    def test_timeout_kills_process_group(self) -> None:
        self.lab.add_codex_config()
        self.lab.set_swarm("HARNESS=codex\n")
        child_pid_file = self.lab.root / "child.pid"
        fake_codex = self.lab.root / "codex"
        fake_codex.write_text(
            "#!/bin/sh\n"
            f"sleep 300 &\necho $! > '{child_pid_file}'\nwait\n",
            encoding="utf-8")
        fake_codex.chmod(0o755)
        os.environ["CODEX_BIN"] = str(fake_codex)
        os.environ["INVOCATION_TIMEOUT_SEC"] = "1"
        module = self.lab.load()

        def _alive(pid: int) -> bool:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return False
            return True

        async def run() -> int:
            await module._spawn_headless(PROMPT, "task-timeout")
            loop = asyncio.get_running_loop()
            deadline = loop.time() + KILL_WAIT_SEC
            pid = 0
            while loop.time() < deadline:
                if not pid and child_pid_file.exists():
                    text = child_pid_file.read_text().strip()
                    pid = int(text) if text else 0
                if pid and not _alive(pid):
                    break
                await asyncio.sleep(POLL_SEC)
            return pid

        pid = asyncio.run(run())
        self.assertTrue(pid, "fake codex did not start its child")
        self.assertFalse(_alive(pid), "child of codex survived the timeout kill")


if __name__ == "__main__":
    unittest.main()
