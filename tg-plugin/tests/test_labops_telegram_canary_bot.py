import io
import importlib.util
import json
import sys
import tempfile
import unittest
from dataclasses import dataclass
from importlib.machinery import SourceFileLoader
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
BOT_PATH = REPO_ROOT / "scripts" / "labops-telegram-canary-bot"


def load_bot():
    module_name = "labops_telegram_canary_bot"
    loader = SourceFileLoader(module_name, str(BOT_PATH))
    spec = importlib.util.spec_from_loader(module_name, loader)
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    loader.exec_module(module)
    return module


@dataclass
class FakeClient:
    updates: list
    conflict_error: Exception | None = None

    def __post_init__(self):
        self.get_updates_calls = []
        self.sent_messages = []

    def get_updates(self, offset, timeout):
        self.get_updates_calls.append({"offset": offset, "timeout": timeout})
        if self.conflict_error:
            raise self.conflict_error
        return self.updates

    def send_message(self, chat_id, text, reply_to_message_id=None, html=True):
        self.sent_messages.append(
            {
                "chat_id": chat_id,
                "text": text,
                "reply_to_message_id": reply_to_message_id,
                "html": html,
            }
        )

    def set_reaction(self, chat_id, message_id, emoji="eyes"):
        self.reactions = getattr(self, "reactions", [])
        self.reactions.append({"chat_id": chat_id, "message_id": message_id, "emoji": emoji})

    def download_file(self, file_id, media_type, file_name, media_root):
        self.downloads = getattr(self, "downloads", [])
        path = media_root / f"{media_type}-{file_id}.bin"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(f"downloaded {media_type}", encoding="utf-8")
        self.downloads.append(
            {
                "file_id": file_id,
                "media_type": media_type,
                "file_name": file_name,
                "path": path,
            }
        )
        return path


@dataclass
class FakeReplyProvider:
    reply_text: str

    def __post_init__(self):
        self.messages = []

    def build_reply(self, inbound):
        self.messages.append(inbound)
        return self.reply_text


class FailingReplyProvider:
    def __init__(self, error):
        self.error = error

    def build_reply(self, inbound):
        raise self.error


class ExplodingReplyProvider:
    def build_reply(self, inbound):
        raise AssertionError("reply provider should not be called for local gateway commands")


@dataclass
class FakeTranscriber:
    transcript: str

    def __post_init__(self):
        self.paths = []

    def transcribe(self, path):
        self.paths.append(path)
        return self.transcript


class RecordingTelegramClient:
    def __init__(self):
        self.calls = []
        self.fail_first_html_parse = False
        self.error_cls = None

    def call(self, method, payload):
        self.calls.append({"method": method, "payload": dict(payload)})
        if self.fail_first_html_parse and len(self.calls) == 1:
            raise self.error_cls(400, "Bad Request: can't parse entities")
        return {"ok": True, "result": {"message_id": 123}}


class CanaryBotTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.runtime_root = Path(self.tmp.name) / "channel-runtime"
        self.token_value = "123456:DO_NOT_PRINT_THIS_TEST_TOKEN"
        self.token_path = self.runtime_root / "canary" / "secrets" / "telegram-bot-token"
        self.token_path.parent.mkdir(parents=True)
        self.token_path.write_text(self.token_value, encoding="utf-8")

    def tearDown(self):
        self.tmp.cleanup()

    def test_run_once_acknowledges_text_message_and_persists_offset_without_secret_output(self):
        bot = load_bot()
        client = FakeClient(
            [
                {
                    "update_id": 42,
                    "message": {
                        "chat": {"id": 777},
                        "text": "ping",
                    },
                }
            ]
        )
        stdout = io.StringIO()
        stderr = io.StringIO()

        code = bot.run_once(
            bot.CanaryBotConfig.from_runtime_root(self.runtime_root),
            client,
            poll_timeout=1,
            stdout=stdout,
            stderr=stderr,
        )

        self.assertEqual(code, 0)
        self.assertEqual(client.get_updates_calls, [{"offset": None, "timeout": 1}])
        self.assertEqual(len(client.sent_messages), 1)
        self.assertEqual(client.sent_messages[0]["chat_id"], 777)
        self.assertIn("labops canary ack", client.sent_messages[0]["text"])
        self.assertEqual((self.runtime_root / "canary" / "queue" / "telegram-offset.json").read_text(), "42\n")
        self.assertIn('"processed": 1', stdout.getvalue())
        self.assertNotIn(self.token_value, stdout.getvalue() + stderr.getvalue() + json.dumps(client.sent_messages))

    def test_run_once_uses_claude_reply_provider_for_text_message(self):
        bot = load_bot()
        client = FakeClient(
            [
                {
                    "update_id": 43,
                    "message": {
                        "message_id": 99,
                        "chat": {"id": 777},
                        "from": {"id": 555, "username": "tester"},
                        "text": "ping claude",
                    },
                }
            ]
        )
        provider = FakeReplyProvider("claude canary reply")

        code = bot.run_once(
            bot.CanaryBotConfig.from_runtime_root(self.runtime_root),
            client,
            poll_timeout=1,
            stdout=io.StringIO(),
            stderr=io.StringIO(),
            reply_provider=provider,
        )

        self.assertEqual(code, 0)
        self.assertEqual(
            client.sent_messages,
            [{"chat_id": 777, "text": "claude canary reply", "reply_to_message_id": 99, "html": True}],
        )
        self.assertEqual(len(provider.messages), 1)
        self.assertEqual(provider.messages[0].chat_id, 777)
        self.assertEqual(provider.messages[0].message_id, 99)
        self.assertEqual(provider.messages[0].text, "ping claude")
        self.assertEqual(provider.messages[0].username, "tester")
        self.assertNotIn("labops canary ack", client.sent_messages[0]["text"])
        self.assertNotIn(self.token_value, json.dumps(client.sent_messages))

    def test_run_once_normalizes_goat_command_to_goal_before_claude_reply(self):
        bot = load_bot()
        client = FakeClient(
            [
                {
                    "update_id": 45,
                    "message": {
                        "message_id": 100,
                        "chat": {"id": 777},
                        "from": {"id": 555, "username": "tester"},
                        "text": "/goat migrate parity",
                    },
                }
            ]
        )
        provider = FakeReplyProvider("goal accepted")

        code = bot.run_once(
            bot.CanaryBotConfig.from_runtime_root(self.runtime_root),
            client,
            poll_timeout=1,
            stdout=io.StringIO(),
            stderr=io.StringIO(),
            reply_provider=provider,
        )

        self.assertEqual(code, 0)
        self.assertEqual(provider.messages[0].text, "/goal migrate parity")
        self.assertEqual(
            client.sent_messages,
            [{"chat_id": 777, "text": "goal accepted", "reply_to_message_id": 100, "html": True}],
        )

    def test_run_once_handles_help_command_without_claude_spend(self):
        bot = load_bot()
        client = FakeClient(
            [
                {
                    "update_id": 46,
                    "message": {
                        "message_id": 101,
                        "chat": {"id": 777},
                        "from": {"id": 555, "username": "tester"},
                        "text": "/help",
                    },
                }
            ]
        )

        code = bot.run_once(
            bot.CanaryBotConfig.from_runtime_root(self.runtime_root),
            client,
            poll_timeout=1,
            stdout=io.StringIO(),
            stderr=io.StringIO(),
            reply_provider=ExplodingReplyProvider(),
        )

        self.assertEqual(code, 0)
        self.assertIn("/status", client.sent_messages[0]["text"])
        self.assertIn("/reset force", client.sent_messages[0]["text"])
        self.assertEqual(client.sent_messages[0]["reply_to_message_id"], 101)

    def test_run_once_status_and_reset_force_manage_session_files(self):
        bot = load_bot()
        config = bot.CanaryBotConfig.from_runtime_root(self.runtime_root)
        paths = bot.session_paths(config, 777)
        paths.sid_path.parent.mkdir(parents=True)
        paths.sid_path.write_text("00000000-0000-4000-8000-000000000001\n", encoding="utf-8")
        paths.started_path.write_text("1\n", encoding="utf-8")
        client = FakeClient(
            [
                {"update_id": 47, "message": {"message_id": 102, "chat": {"id": 777}, "text": "/status"}},
                {"update_id": 48, "message": {"message_id": 103, "chat": {"id": 777}, "text": "/reset force"}},
            ]
        )

        code = bot.run_once(
            config,
            client,
            poll_timeout=1,
            stdout=io.StringIO(),
            stderr=io.StringIO(),
            reply_provider=ExplodingReplyProvider(),
        )

        self.assertEqual(code, 0)
        self.assertIn("session active", client.sent_messages[0]["text"])
        self.assertIn("session reset", client.sent_messages[1]["text"])
        self.assertFalse(paths.sid_path.exists())
        self.assertFalse(paths.started_path.exists())

    def test_telegram_send_message_formats_chunks_and_replies_to_first_chunk(self):
        bot = load_bot()
        client = RecordingTelegramClient()
        client.error_cls = bot.TelegramAPIError

        bot.TelegramClient.send_message(client, 777, "**hello**\n\n" + ("x" * 4050), reply_to_message_id=99, html=True)

        self.assertEqual([call["method"] for call in client.calls], ["sendMessage", "sendMessage", "sendMessage"])
        first = client.calls[0]["payload"]
        second = client.calls[1]["payload"]
        self.assertEqual(first["reply_to_message_id"], 99)
        self.assertNotIn("reply_to_message_id", second)
        self.assertEqual(first["parse_mode"], "HTML")
        self.assertIn("<b>hello</b>", first["text"])
        self.assertTrue(all(len(call["payload"]["text"]) <= 4000 for call in client.calls))

    def test_telegram_send_message_retries_plain_text_on_html_parse_error(self):
        bot = load_bot()
        client = RecordingTelegramClient()
        client.error_cls = bot.TelegramAPIError
        client.fail_first_html_parse = True

        bot.TelegramClient.send_message(client, 777, "<b>broken", reply_to_message_id=99, html=True)

        self.assertEqual(len(client.calls), 2)
        self.assertEqual(client.calls[0]["payload"]["parse_mode"], "HTML")
        self.assertNotIn("parse_mode", client.calls[1]["payload"])

    def test_run_once_adds_forward_reply_and_media_context_to_claude_prompt(self):
        bot = load_bot()
        client = FakeClient(
            [
                {
                    "update_id": 49,
                    "message": {
                        "message_id": 104,
                        "chat": {"id": 777},
                        "from": {"id": 555, "username": "tester"},
                        "forward_sender_name": "Source Person",
                        "reply_to_message": {
                            "message_id": 88,
                            "from": {"username": "other"},
                            "text": "original question",
                        },
                        "caption": "look at this",
                        "photo": [
                            {"file_id": "small", "file_size": 10},
                            {"file_id": "large", "file_size": 20},
                        ],
                    },
                }
            ]
        )
        provider = FakeReplyProvider("context ok")

        code = bot.run_once(
            bot.CanaryBotConfig.from_runtime_root(self.runtime_root),
            client,
            poll_timeout=1,
            stdout=io.StringIO(),
            stderr=io.StringIO(),
            reply_provider=provider,
        )

        self.assertEqual(code, 0)
        inbound_text = provider.messages[0].text
        self.assertIn("forwarded from: Source Person", inbound_text)
        self.assertIn("reply_to_message", inbound_text)
        self.assertIn("original question", inbound_text)
        self.assertIn("photo", inbound_text)
        self.assertIn("large", inbound_text)

    def test_run_once_transcribes_voice_media_when_transcriber_is_available(self):
        bot = load_bot()
        transcriber = FakeTranscriber("voice transcript text")
        client = FakeClient(
            [
                {
                    "update_id": 50,
                    "message": {
                        "message_id": 105,
                        "chat": {"id": 777},
                        "from": {"id": 555, "username": "tester"},
                        "voice": {"file_id": "voice-file", "file_size": 20, "mime_type": "audio/ogg"},
                    },
                }
            ]
        )
        provider = FakeReplyProvider("voice ok")

        code = bot.run_once(
            bot.CanaryBotConfig.from_runtime_root(self.runtime_root),
            client,
            poll_timeout=1,
            stdout=io.StringIO(),
            stderr=io.StringIO(),
            reply_provider=provider,
            transcriber=transcriber,
        )

        self.assertEqual(code, 0)
        self.assertEqual(len(transcriber.paths), 1)
        self.assertIn("voice transcript text", provider.messages[0].text)

    def test_claude_reply_provider_uses_session_id_then_resume(self):
        bot = load_bot()
        calls = []

        def fake_runner(command, timeout):
            calls.append({"command": command, "timeout": timeout})
            return bot.CommandResult(0, "session reply\n", "")

        provider = bot.ClaudeReplyProvider(
            runner=fake_runner,
            timeout_seconds=12,
            max_budget_usd="0.05",
            session_root=self.runtime_root / "canary" / "sessions",
        )
        inbound = bot.InboundMessage(
            chat_id=777,
            message_id=99,
            text="remember this",
            username="tester",
        )

        provider.build_reply(inbound)
        provider.build_reply(inbound)

        first = calls[0]["command"]
        second = calls[1]["command"]
        self.assertIn("--session-id", first)
        self.assertIn("--resume", second)
        self.assertEqual(first[first.index("--session-id") + 1], second[second.index("--resume") + 1])

    def test_run_once_reports_claude_failure_without_leaking_secret_like_text(self):
        bot = load_bot()
        client = FakeClient(
            [
                {
                    "update_id": 44,
                    "message": {
                        "chat": {"id": 777},
                        "text": "ping claude",
                    },
                }
            ]
        )
        provider = FailingReplyProvider(
            bot.ClaudeReplyError(f"Not logged in; saw {self.token_value} in a lower layer")
        )
        stdout = io.StringIO()
        stderr = io.StringIO()

        code = bot.run_once(
            bot.CanaryBotConfig.from_runtime_root(self.runtime_root),
            client,
            poll_timeout=1,
            stdout=stdout,
            stderr=stderr,
            reply_provider=provider,
        )

        self.assertEqual(code, 0)
        self.assertEqual(len(client.sent_messages), 1)
        self.assertIn("Claude fallback unavailable", client.sent_messages[0]["text"])
        self.assertIn("[redacted-token]", client.sent_messages[0]["text"])
        self.assertIn("claude_reply_error", stderr.getvalue())
        self.assertNotIn(self.token_value, stdout.getvalue() + stderr.getvalue() + json.dumps(client.sent_messages))

    def test_claude_reply_provider_invokes_claude_print_without_shell_or_token(self):
        bot = load_bot()
        calls = []

        def fake_runner(command, timeout):
            calls.append({"command": command, "timeout": timeout})
            return bot.CommandResult(0, "model reply\n", "")

        provider = bot.ClaudeReplyProvider(
            runner=fake_runner,
            timeout_seconds=12,
            max_budget_usd="0.05",
        )
        inbound = bot.InboundMessage(
            chat_id=777,
            message_id=99,
            text="What is this canary doing?",
            username="tester",
        )

        reply = provider.build_reply(inbound)

        self.assertEqual(reply, "model reply")
        self.assertEqual(len(calls), 1)
        command = calls[0]["command"]
        self.assertEqual(command[:4], ["claude", "--print", "--max-budget-usd", "0.05"])
        self.assertIn("--", command)
        self.assertEqual(command[-1].count("What is this canary doing?"), 1)
        self.assertNotIn(self.token_value, " ".join(command))
        self.assertEqual(calls[0]["timeout"], 12)

    def test_run_once_uses_next_offset_after_saved_update_id(self):
        bot = load_bot()
        config = bot.CanaryBotConfig.from_runtime_root(self.runtime_root)
        config.offset_path.parent.mkdir(parents=True)
        config.offset_path.write_text("41\n", encoding="utf-8")
        client = FakeClient([])

        code = bot.run_once(config, client, poll_timeout=3, stdout=io.StringIO(), stderr=io.StringIO())

        self.assertEqual(code, 0)
        self.assertEqual(client.get_updates_calls, [{"offset": 42, "timeout": 3}])

    def test_missing_token_is_a_blocked_start_without_secret_output(self):
        bot = load_bot()
        self.token_path.unlink()
        stdout = io.StringIO()
        stderr = io.StringIO()

        code = bot.main(["--runtime-root", str(self.runtime_root), "--once"], stdout=stdout, stderr=stderr)

        self.assertEqual(code, 3)
        self.assertIn("canary_token_missing", stderr.getvalue())
        self.assertNotIn(self.token_value, stdout.getvalue() + stderr.getvalue())

    def test_get_updates_conflict_returns_clear_error(self):
        bot = load_bot()
        client = FakeClient([], conflict_error=bot.TelegramAPIError(409, "Conflict: another getUpdates request is active"))
        stdout = io.StringIO()
        stderr = io.StringIO()

        code = bot.run_once(
            bot.CanaryBotConfig.from_runtime_root(self.runtime_root),
            client,
            poll_timeout=1,
            stdout=stdout,
            stderr=stderr,
        )

        self.assertEqual(code, 4)
        self.assertIn("telegram_getupdates_conflict", stderr.getvalue())
        self.assertEqual(client.sent_messages, [])
        self.assertNotIn(self.token_value, stdout.getvalue() + stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
