"""Тесты хука flatten_system: system-блоки и патч стрима аргументов инструментов.

Гоняют настоящий AnthropicResponsesStreamWrapper из установленного LiteLLM.
Запуск: python -m pytest -q openai-adapter/tests
    или python -m unittest discover -s openai-adapter/tests
"""
import asyncio
import copy
import json
import logging
import sys
import unittest
from collections.abc import Callable
from pathlib import Path
from types import SimpleNamespace
from typing import Any
from unittest import mock

# Модуль хука лежит каталогом выше, как рядом с config.yaml на сервере.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import flatten_system as fs  # noqa: E402
from litellm.llms.anthropic.pass_through.responses_adapters import (  # noqa: E402
    streaming_iterator as si,
)

Wrapper = si.AnthropicResponsesStreamWrapper
ORIGINAL: Callable[[Any, object], None] = getattr(
    Wrapper._process_event, fs.ORIGINAL_ATTR
)
MODEL = "gpt-x"
LOGGER_NAME = fs.LOGGER_NAME
# Размер аргументов для теста длинных строк (байт заведомо больше 10 КБ).
LONG_REPEAT = 400
CHUNK_SIZE = 777


# ---- построители событий (dict, как у реального бэкенда) ----

def created() -> dict:
    return {"type": "response.created"}


def added_call(item_id: str, call_id: str, name: str = "Bash") -> dict:
    return {
        "type": "response.output_item.added",
        "item": {"type": "function_call", "id": item_id, "call_id": call_id, "name": name},
    }


def added_text(item_id: str) -> dict:
    return {"type": "response.output_item.added", "item": {"type": "message", "id": item_id}}


def text_delta(item_id: str, text: str) -> dict:
    return {"type": "response.output_text.delta", "item_id": item_id, "delta": text}


def args_delta(item_id: str, delta: str) -> dict:
    return {"type": "response.function_call_arguments.delta", "item_id": item_id, "delta": delta}


def args_done(item_id: str, arguments: str) -> dict:
    return {
        "type": "response.function_call_arguments.done",
        "item_id": item_id,
        "arguments": arguments,
    }


def item_done_call(item_id: str, arguments: str | None, call_id: str = "c") -> dict:
    item: dict = {"type": "function_call", "id": item_id, "call_id": call_id}
    if arguments is not None:
        item["arguments"] = arguments
    return {"type": "response.output_item.done", "item": item}


def item_done_text(item_id: str) -> dict:
    return {"type": "response.output_item.done", "item": {"type": "message", "id": item_id}}


def new_wrapper() -> Any:
    wrapper = Wrapper(responses_stream=None, model=MODEL)
    wrapper._message_id = "msg_fixed"
    return wrapper


def run(events: list, process: Callable[[Any, object], None] | None = None) -> list[dict]:
    """Прогоняет события через _process_event и возвращает всё, что легло в очередь."""
    wrapper = new_wrapper()
    for event in events:
        if process is None:
            wrapper._process_event(event)
        else:
            process(wrapper, event)
    return list(wrapper._chunk_queue)


def of_type(chunks: list[dict], chunk_type: str, index: int | None = None) -> list[dict]:
    return [c for c in chunks if c["type"] == chunk_type
            and (index is None or c.get("index") == index)]


def json_deltas(chunks: list[dict], index: int) -> list[str]:
    return [c["delta"]["partial_json"] for c in of_type(chunks, "content_block_delta", index)
            if c["delta"]["type"] == "input_json_delta"]


def position(chunks: list[dict], chunk_type: str, index: int, nth: int = 0) -> int:
    found = [i for i, c in enumerate(chunks) if c["type"] == chunk_type and c.get("index") == index]
    return found[nth]


class FlattenHookTest(unittest.TestCase):
    """Прежнее поведение хука: system-список -> строка."""

    def test_system_list_becomes_string(self) -> None:
        data = {
            "system": [
                {"type": "text", "text": "Первый"},
                {"type": "text", "text": ""},
                {"type": "image"},
                {"type": "text", "text": "Второй"},
            ],
            "messages": [
                {"role": "system", "content": [{"type": "text", "text": "A"},
                                               {"type": "text", "text": "B"}]},
                {"role": "user", "content": [{"type": "text", "text": "x"}]},
            ],
        }
        result = asyncio.run(fs.flatten_system.async_pre_call_hook(None, None, data, "x"))
        self.assertEqual(result["system"], "Первый\n\nВторой")
        self.assertEqual(result["messages"][0]["content"], "A\n\nB")
        self.assertEqual(result["messages"][1]["content"], [{"type": "text", "text": "x"}])

    def test_system_string_untouched(self) -> None:
        data = {"system": "уже строка", "messages": None}
        result = asyncio.run(fs.flatten_system.async_pre_call_hook(None, None, data, "x"))
        self.assertEqual(result["system"], "уже строка")


class StreamPatchTest(unittest.TestCase):
    """Патч _process_event: аргументы из .done-событий."""

    def test_patch_installed_on_real_class(self) -> None:
        self.assertTrue(getattr(Wrapper._process_event, fs.PATCH_MARKER, False))
        self.assertTrue(callable(ORIGINAL))

    def test_1_single_call_with_native_deltas_matches_original(self) -> None:
        events = [
            added_call("i1", "c1"),
            args_delta("i1", '{"command":'),
            args_delta("i1", '"ls"}'),
            args_done("i1", '{"command":"ls"}'),
            item_done_call("i1", '{"command":"ls"}'),
        ]
        patched = run(events)
        original = run(events, ORIGINAL)
        self.assertEqual(patched, original)
        self.assertEqual(json_deltas(patched, 0), ['{"command":', '"ls"}'])

    def test_2_two_calls_without_deltas_sequential(self) -> None:
        events = [
            added_call("i1", "c1"), args_done("i1", '{"a":1}'), item_done_call("i1", '{"a":1}'),
            added_call("i2", "c2"), args_done("i2", '{"b":2}'), item_done_call("i2", '{"b":2}'),
        ]
        chunks = run(events)
        for index, expected in ((0, '{"a":1}'), (1, '{"b":2}')):
            self.assertEqual(json_deltas(chunks, index), [expected])
            self.assertEqual(len(of_type(chunks, "content_block_stop", index)), 1)
            self.assertLess(position(chunks, "content_block_start", index),
                            position(chunks, "content_block_delta", index))
            self.assertLess(position(chunks, "content_block_delta", index),
                            position(chunks, "content_block_stop", index))

    def test_3_interleaved_order_goes_to_right_indexes(self) -> None:
        events = [
            added_call("i1", "c1"), added_call("i2", "c2"),
            args_done("i2", '{"b":2}'), args_done("i1", '{"a":1}'),
            item_done_call("i1", '{"a":1}'), item_done_call("i2", '{"b":2}'),
        ]
        chunks = run(events)
        self.assertEqual(json_deltas(chunks, 0), ['{"a":1}'])
        self.assertEqual(json_deltas(chunks, 1), ['{"b":2}'])
        for index in (0, 1):
            self.assertLess(position(chunks, "content_block_delta", index),
                            position(chunks, "content_block_stop", index))

    def test_4_only_item_done_with_arguments(self) -> None:
        events = [
            added_call("i1", "c1"), item_done_call("i1", '{"a":1}'),
            added_call("i2", "c2"), item_done_call("i2", '{"b":2}'),
        ]
        chunks = run(events)
        self.assertEqual(json_deltas(chunks, 0), ['{"a":1}'])
        self.assertEqual(json_deltas(chunks, 1), ['{"b":2}'])
        for index in (0, 1):
            self.assertLess(position(chunks, "content_block_delta", index),
                            position(chunks, "content_block_stop", index))

    def test_5_native_deltas_plus_done_no_duplicate(self) -> None:
        events = [
            added_call("i1", "c1"),
            args_delta("i1", '{"a":'), args_delta("i1", "1}"),
            args_done("i1", '{"a":1}'),
            item_done_call("i1", '{"a":1}'),
        ]
        chunks = run(events)
        self.assertEqual("".join(json_deltas(chunks, 0)), '{"a":1}')
        self.assertEqual(len(json_deltas(chunks, 0)), 2)

    def test_5b_duplicate_done_events_inject_once(self) -> None:
        events = [
            added_call("i1", "c1"),
            args_done("i1", '{"a":1}'), args_done("i1", '{"a":1}'),
            item_done_call("i1", '{"a":1}'), item_done_call("i1", '{"a":1}'),
        ]
        chunks = run(events)
        self.assertEqual(json_deltas(chunks, 0), ['{"a":1}'])

    def test_5c_native_deltas_on_one_block_only(self) -> None:
        """Родные дельты у первого блока не мешают дослать аргументы второму."""
        events = [
            added_call("i1", "c1"), added_call("i2", "c2"),
            args_delta("i1", '{"a":1}'),
            args_done("i1", '{"a":1}'), args_done("i2", '{"b":2}'),
            item_done_call("i1", '{"a":1}'), item_done_call("i2", '{"b":2}'),
        ]
        chunks = run(events)
        self.assertEqual(json_deltas(chunks, 0), ['{"a":1}'])
        self.assertEqual(json_deltas(chunks, 1), ['{"b":2}'])

    def test_6_text_plus_two_calls(self) -> None:
        events = [
            added_text("m1"), text_delta("m1", "Сейчас"), item_done_text("m1"),
            added_call("i1", "c1"), args_done("i1", '{"a":1}'), item_done_call("i1", '{"a":1}'),
            added_call("i2", "c2"), args_done("i2", '{"b":2}'), item_done_call("i2", '{"b":2}'),
        ]
        chunks = run(events)
        self.assertEqual(json_deltas(chunks, 0), [])
        self.assertEqual(json_deltas(chunks, 1), ['{"a":1}'])
        self.assertEqual(json_deltas(chunks, 2), ['{"b":2}'])
        text = [c for c in of_type(chunks, "content_block_delta", 0)]
        self.assertEqual([c["delta"] for c in text], [{"type": "text_delta", "text": "Сейчас"}])
        # Текстовый блок идентичен оригиналу.
        original = run(events, ORIGINAL)
        self.assertEqual([c for c in chunks if c.get("index") == 0],
                         [c for c in original if c.get("index") == 0])

    def test_7_long_arguments_with_cyrillic_and_emoji(self) -> None:
        payload = {"text": "Привет, мир! 🚀🔥 " * LONG_REPEAT, "n": [1, 2, 3]}
        arguments = json.dumps(payload, ensure_ascii=False)
        self.assertGreater(len(arguments.encode()), 10 * 1024)
        events = [added_call("i1", "c1"), args_done("i1", arguments),
                  item_done_call("i1", arguments)]
        chunks = run(events)
        self.assertEqual(json.loads("".join(json_deltas(chunks, 0))), payload)
        self.assertEqual(len(json_deltas(chunks, 0)), 1)

    def test_7b_long_native_deltas_unchanged(self) -> None:
        arguments = json.dumps({"t": "Ёж 🦔 " * LONG_REPEAT}, ensure_ascii=False)
        parts = [arguments[i:i + CHUNK_SIZE] for i in range(0, len(arguments), CHUNK_SIZE)]
        events = [added_call("i1", "c1"), *[args_delta("i1", p) for p in parts],
                  args_done("i1", arguments), item_done_call("i1", arguments)]
        chunks = run(events)
        self.assertEqual(json_deltas(chunks, 0), parts)
        self.assertEqual(chunks, run(events, ORIGINAL))

    def test_8_empty_object_at_most_once(self) -> None:
        events = [added_call("i1", "c1"), args_done("i1", "{}"), item_done_call("i1", "{}")]
        chunks = run(events)
        self.assertEqual(json_deltas(chunks, 0), ["{}"])

    def test_8b_empty_string_or_missing_arguments_not_injected(self) -> None:
        events = [
            added_call("i1", "c1"), args_done("i1", ""), item_done_call("i1", ""),
            added_call("i2", "c2"), args_done("i2", None), item_done_call("i2", None),
        ]
        chunks = run(events)
        self.assertEqual(json_deltas(chunks, 0), [])
        self.assertEqual(json_deltas(chunks, 1), [])
        self.assertEqual(chunks, run(events, ORIGINAL))

    def test_8c_late_arguments_after_stop_not_injected(self) -> None:
        events = [added_call("i1", "c1"), item_done_call("i1", None), args_done("i1", '{"a":1}')]
        chunks = run(events)
        self.assertEqual(json_deltas(chunks, 0), [])

    def test_unknown_item_id_ignored(self) -> None:
        events = [args_done("nope", '{"a":1}'), item_done_call("nope", '{"a":1}')]
        self.assertEqual(run(events), run(events, ORIGINAL))

    def test_attribute_style_events(self) -> None:
        """События-объекты с атрибутами (SimpleNamespace) ведут себя как dict-события."""
        ns = SimpleNamespace
        events = [
            ns(type="response.output_item.added",
               item=ns(type="function_call", id="i1", call_id="c1", name="Bash")),
            ns(type="response.function_call_arguments.done", item_id="i1", arguments='{"a":1}'),
            ns(type="response.output_item.done",
               item=ns(type="function_call", id="i1", arguments='{"a":1}')),
        ]
        chunks = run(events)
        self.assertEqual(json_deltas(chunks, 0), ['{"a":1}'])
        self.assertEqual(len(of_type(chunks, "content_block_stop", 0)), 1)

    def test_litellm_typed_events(self) -> None:
        """Настоящие pydantic-события из litellm.types."""
        from litellm.types.llms import openai as oa
        from litellm.types.llms.openai import ResponsesAPIStreamEvents as E

        item_added = oa.BaseLiteLLMOpenAIResponseObject(
            type="function_call", id="i1", call_id="c1", name="Bash")
        item_done = oa.BaseLiteLLMOpenAIResponseObject(
            type="function_call", id="i1", arguments='{"a":1}')
        events = [
            oa.OutputItemAddedEvent(type=E.OUTPUT_ITEM_ADDED, output_index=0, item=item_added),
            oa.FunctionCallArgumentsDoneEvent(
                type=E.FUNCTION_CALL_ARGUMENTS_DONE, item_id="i1", output_index=0,
                arguments='{"a":1}'),
            oa.OutputItemDoneEvent(type=E.OUTPUT_ITEM_DONE, output_index=0, item=item_done),
        ]
        chunks = run(events)
        self.assertEqual(json_deltas(chunks, 0), ['{"a":1}'])
        self.assertEqual(len(of_type(chunks, "content_block_stop", 0)), 1)


class FailSafeTest(unittest.TestCase):
    """Патч не должен ломать стрим."""

    def test_9_missing_structures_calls_original_with_one_warning(self) -> None:
        wrapper = new_wrapper()
        del wrapper._pending_tool_ids
        calls: list[object] = []
        patched = fs._make_patched(lambda self, event: calls.append(event))
        events = [added_call("i1", "c1"), args_done("i1", "{}"), item_done_call("i1", "{}")]
        with self.assertLogs(LOGGER_NAME, level="WARNING") as logs:
            for event in events:
                patched(wrapper, event)
        self.assertEqual(calls, events)
        self.assertEqual(len(logs.records), 1)

    def test_9b_wrong_structure_type(self) -> None:
        wrapper = new_wrapper()
        wrapper._item_id_to_block_index = []  # не dict
        calls: list[object] = []
        patched = fs._make_patched(lambda self, event: calls.append(event))
        with self.assertLogs(LOGGER_NAME, level="WARNING"):
            patched(wrapper, args_done("i1", "{}"))
        self.assertEqual(len(calls), 1)

    def test_9c_patch_logic_raises_original_still_called(self) -> None:
        wrapper = new_wrapper()
        calls: list[object] = []
        patched = fs._make_patched(lambda self, event: calls.append(event))
        events = [added_call("i1", "c1"), args_done("i1", "{}"), item_done_call("i1", "{}")]
        with mock.patch.object(fs, "_before_original", side_effect=RuntimeError("boom")):
            with self.assertLogs(LOGGER_NAME, level="WARNING") as logs:
                for event in events:
                    patched(wrapper, event)  # исключения наружу быть не должно
        self.assertEqual(calls, events)
        # Один warning: после сбоя патч на потоке отключён.
        self.assertEqual(len(logs.records), 1)

    def test_9d_original_exception_not_swallowed(self) -> None:
        def broken(self: Any, event: object) -> None:
            raise ValueError("оригинал упал")

        patched = fs._make_patched(broken)
        with self.assertRaises(ValueError):
            patched(new_wrapper(), created())


class InstallTest(unittest.TestCase):
    """Установка патча."""

    @staticmethod
    def _fake_module(cls: Any) -> SimpleNamespace:
        return SimpleNamespace(AnthropicResponsesStreamWrapper=cls)

    def test_10_import_error_returns_false(self) -> None:
        with mock.patch.object(fs.importlib, "import_module", side_effect=ImportError("нет")):
            with self.assertLogs(LOGGER_NAME, level="WARNING"):
                self.assertFalse(fs.install_stream_args_patch())

    def test_10b_missing_class_returns_false(self) -> None:
        with mock.patch.object(fs.importlib, "import_module", return_value=SimpleNamespace()):
            with self.assertLogs(LOGGER_NAME, level="WARNING"):
                self.assertFalse(fs.install_stream_args_patch())

    def test_10c_missing_method_returns_false(self) -> None:
        fake = self._fake_module(type("Fake", (), {}))
        with mock.patch.object(fs.importlib, "import_module", return_value=fake):
            with self.assertLogs(LOGGER_NAME, level="WARNING"):
                self.assertFalse(fs.install_stream_args_patch())

    def test_10d_install_is_idempotent_and_keeps_original(self) -> None:
        class Fake:
            def _process_event(self, event: object) -> None:
                self.seen = event

        original = Fake._process_event
        fake = self._fake_module(Fake)
        with mock.patch.object(fs.importlib, "import_module", return_value=fake):
            with mock.patch.object(fs.importlib.metadata, "version",
                                   return_value=fs.TESTED_LITELLM_VERSION):
                self.assertTrue(fs.install_stream_args_patch())
                first = Fake._process_event
                self.assertTrue(fs.install_stream_args_patch())
                self.assertIs(Fake._process_event, first)
        self.assertIsNot(first, original)
        self.assertIs(getattr(first, fs.ORIGINAL_ATTR), original)
        self.assertIs(first.__wrapped__, original)

    def test_10e_other_litellm_version_warns_but_installs(self) -> None:
        class Fake:
            def _process_event(self, event: object) -> None:
                return None

        fake = self._fake_module(Fake)
        with mock.patch.object(fs.importlib, "import_module", return_value=fake):
            with mock.patch.object(fs.importlib.metadata, "version", return_value="9.9.9"):
                with self.assertLogs(LOGGER_NAME, level="WARNING") as logs:
                    self.assertTrue(fs.install_stream_args_patch())
        self.assertIn("9.9.9", logs.output[0])
        self.assertTrue(getattr(Fake._process_event, fs.PATCH_MARKER))

    def test_10f_real_class_not_double_wrapped(self) -> None:
        before = Wrapper._process_event
        self.assertTrue(fs.install_stream_args_patch())
        self.assertIs(Wrapper._process_event, before)
        self.assertFalse(getattr(ORIGINAL, fs.PATCH_MARKER, False))


class FullStreamTest(unittest.TestCase):
    """Полный поток через async for."""

    @staticmethod
    async def _source(events: list) -> Any:
        for event in events:
            yield event

    def _collect(self, events: list) -> list[dict]:
        wrapper = Wrapper(responses_stream=self._source(events), model=MODEL)

        async def drain() -> list[dict]:
            return [chunk async for chunk in wrapper]

        return asyncio.run(drain())

    @staticmethod
    def _completed(items: list[dict]) -> Any:
        response = SimpleNamespace(output=items, status="completed", usage=None)
        return SimpleNamespace(type="response.completed", response=response)

    def test_full_stream_two_calls(self) -> None:
        args1, args2 = '{"command":"ls"}', '{"file_path":"/tmp/Ё.txt"}'
        events = [
            created(),
            added_call("i1", "c1", "Bash"), args_done("i1", args1), item_done_call("i1", args1),
            added_call("i2", "c2", "Read"), args_done("i2", args2), item_done_call("i2", args2),
            self._completed([{"type": "function_call", "id": "i1"},
                             {"type": "function_call", "id": "i2"}]),
        ]
        chunks = self._collect(events)
        starts = of_type(chunks, "content_block_start")
        self.assertEqual([c["index"] for c in starts], [0, 1])
        self.assertEqual([c["content_block"]["id"] for c in starts], ["c1", "c2"])
        for index, expected in ((0, args1), (1, args2)):
            self.assertEqual(len(of_type(chunks, "content_block_stop", index)), 1)
            self.assertEqual(json_deltas(chunks, index), [expected])
            self.assertLess(position(chunks, "content_block_delta", index),
                            position(chunks, "content_block_stop", index))
        delta = of_type(chunks, "message_delta")
        self.assertEqual(len(delta), 1)
        self.assertEqual(delta[0]["delta"]["stop_reason"], "tool_use")
        self.assertEqual(chunks[0]["type"], "message_start")
        self.assertEqual(chunks[-1]["type"], "message_stop")
        self.assertEqual(len(of_type(chunks, "message_start")), 1)

    def test_full_stream_matches_original_when_native_deltas(self) -> None:
        events = [
            created(),
            added_call("i1", "c1"), args_delta("i1", '{"a":1}'),
            args_done("i1", '{"a":1}'), item_done_call("i1", '{"a":1}'),
            self._completed([{"type": "function_call", "id": "i1"}]),
        ]

        def normalized(chunks: list[dict]) -> list[dict]:
            result = copy.deepcopy(chunks)
            for chunk in result:
                if chunk["type"] == "message_start":
                    chunk["message"]["id"] = "x"
            return result

        patched = self._collect(events)
        with mock.patch.object(Wrapper, "_process_event", ORIGINAL):
            original = self._collect(events)
        self.assertEqual(normalized(patched), normalized(original))

    def test_full_stream_sse_bytes(self) -> None:
        events = [created(), added_call("i1", "c1"), args_done("i1", '{"a":1}'),
                  item_done_call("i1", '{"a":1}'),
                  self._completed([{"type": "function_call", "id": "i1"}])]
        wrapper = Wrapper(responses_stream=self._source(events), model=MODEL)

        async def drain() -> bytes:
            return b"".join([frame async for frame in wrapper.async_anthropic_sse_wrapper()])

        text = asyncio.run(drain()).decode()
        self.assertEqual(text.count("input_json_delta"), 1)
        self.assertIn("event: message_stop", text)


if __name__ == "__main__":
    logging.basicConfig(level=logging.WARNING)
    unittest.main()
