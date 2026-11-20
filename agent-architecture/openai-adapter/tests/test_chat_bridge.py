"""Тесты патча моста Responses->chat (маршрут chatgpt/).

События Responses подаются в chunk_parser настоящего
OpenAiResponsesToChatCompletionStreamIterator, а получившиеся чанки идут через настоящий
AnthropicStreamWrapper (async и sync). Проверяются итоговые события Anthropic.
"""
import asyncio
import json
import sys
import unittest
from collections.abc import Callable
from pathlib import Path
from typing import Any
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import flatten_system as fs  # noqa: E402
from litellm.completion_extras.litellm_responses_transformation import (  # noqa: E402
    transformation as bridge,
)
from litellm.llms.anthropic.pass_through.adapters.streaming_iterator import (  # noqa: E402
    AnthropicStreamWrapper,
)

Parser = bridge.OpenAiResponsesToChatCompletionStreamIterator
ORIGINAL_PARSER: Callable[[Any, Any], Any] = getattr(Parser.chunk_parser, fs.BRIDGE_ORIGINAL_ATTR)
MODEL = "gpt-x"
LONG_REPEAT = 400
CHUNK_SIZE = 777


class ChunkStream:
    """Источник чанков с sync и async итерированием (как поток LiteLLM)."""

    def __init__(self, chunks: list) -> None:
        self._chunks = chunks

    def __iter__(self):
        return iter(self._chunks)

    def __aiter__(self):
        async def gen():
            for chunk in self._chunks:
                yield chunk
        return gen()


# ---- события Responses (dict, как у реального бэкенда) ----

def call_item(item_id: str, call_id: str, arguments: str = "", name: str = "Bash") -> dict:
    return {"type": "function_call", "id": item_id, "call_id": call_id, "name": name,
            "arguments": arguments}


def created() -> dict:
    return {"type": "response.created", "response": {"id": "resp_1"}}


def added(idx: int, item_id: str, call_id: str) -> dict:
    return {"type": "response.output_item.added", "output_index": idx,
            "item": call_item(item_id, call_id)}


def delta(idx: int, item_id: str, text: str) -> dict:
    return {"type": "response.function_call_arguments.delta", "output_index": idx,
            "item_id": item_id, "delta": text}


def args_done(idx: int, item_id: str, arguments: str) -> dict:
    return {"type": "response.function_call_arguments.done", "output_index": idx,
            "item_id": item_id, "arguments": arguments}


def item_done(idx: int, item_id: str, call_id: str, arguments: str) -> dict:
    return {"type": "response.output_item.done", "output_index": idx,
            "item": call_item(item_id, call_id, arguments)}


def text_added(idx: int, item_id: str) -> dict:
    return {"type": "response.output_item.added", "output_index": idx,
            "item": {"type": "message", "id": item_id, "role": "assistant", "content": []}}


def text_delta(idx: int, item_id: str, text: str) -> dict:
    return {"type": "response.output_text.delta", "output_index": idx, "item_id": item_id,
            "delta": text}


def text_done(idx: int, item_id: str) -> dict:
    return {"type": "response.output_item.done", "output_index": idx,
            "item": {"type": "message", "id": item_id}}


def completed(*items: dict) -> dict:
    return {"type": "response.completed",
            "response": {"output": list(items), "usage": None, "status": "completed"}}


def full_call(idx: int, n: int, arguments: str, deltas: list[str] | None = None) -> list[dict]:
    """Полный набор событий одного вызова; deltas=None - бэкенд не шлёт .delta."""
    item_id, call_id = f"fc{n}", f"call{n}"
    return [added(idx, item_id, call_id),
            *[delta(idx, item_id, d) for d in deltas or []],
            args_done(idx, item_id, arguments),
            item_done(idx, item_id, call_id, arguments)]


# ---- прогон и проверки ----

def to_chunks(events: list, parser_cls_method: Callable | None = None) -> list:
    """Responses-события -> чанки chat через настоящий итератор моста."""
    iterator = Parser(None, False)
    parse = parser_cls_method or Parser.chunk_parser
    return [parse(iterator, event) for event in events]


def to_anthropic(chunks: list, sync: bool = False) -> list[dict]:
    wrapper = AnthropicStreamWrapper(ChunkStream(chunks), MODEL)
    if sync:
        return list(wrapper)

    async def drain() -> list[dict]:
        return [event async for event in wrapper]

    return asyncio.run(drain())


def run(events: list, sync: bool = False) -> list[dict]:
    return to_anthropic(to_chunks(events), sync)


def run_original(events: list) -> list[dict]:
    return to_anthropic(to_chunks(events, ORIGINAL_PARSER))


def tool_blocks(result: list[dict]) -> list[tuple[int, dict, str]]:
    """(индекс, content_block, склейка partial_json) для tool_use блоков."""
    found = []
    for event in result:
        if event["type"] == "content_block_start" and event["content_block"]["type"] == "tool_use":
            idx = event["index"]
            joined = "".join(
                e["delta"]["partial_json"] for e in result
                if e["type"] == "content_block_delta" and e["index"] == idx
                and e["delta"]["type"] == "input_json_delta")
            found.append((idx, event["content_block"], joined))
    return found


def normalized(result: list[dict]) -> list[dict]:
    out = json.loads(json.dumps(result))
    for event in out:
        if event["type"] == "message_start":
            event["message"]["id"] = "x"
    return out


class BridgeCase(unittest.TestCase):
    def check_invariants(self, result: list[dict], expected: list[str]) -> None:
        """Инварианты потока Anthropic и склейка аргументов по tool_use блокам."""
        self.assertEqual(result[0]["type"], "message_start")
        self.assertEqual(result[-1]["type"], "message_stop")
        starts = [e["index"] for e in result if e["type"] == "content_block_start"]
        stops = [e["index"] for e in result if e["type"] == "content_block_stop"]
        self.assertEqual(starts, list(range(len(starts))), "индексы блоков не подряд")
        self.assertEqual(sorted(stops), starts, "не по одному stop на блок")
        for idx in starts:
            pos = {k: [i for i, e in enumerate(result) if e["type"] == k and e.get("index") == idx]
                   for k in ("content_block_start", "content_block_delta", "content_block_stop")}
            self.assertEqual(len(pos["content_block_start"]), 1)
            self.assertEqual(len(pos["content_block_stop"]), 1)
            for d in pos["content_block_delta"]:
                self.assertGreater(d, pos["content_block_start"][0])
                self.assertLess(d, pos["content_block_stop"][0])
        blocks = tool_blocks(result)
        self.assertEqual([b[2] for b in blocks], expected)
        for _, _, joined in blocks:
            json.loads(joined)
        message_delta = [e for e in result if e["type"] == "message_delta"]
        self.assertEqual(len(message_delta), 1)
        self.assertEqual(message_delta[0]["delta"]["stop_reason"], "tool_use")


class BridgeScenarioTest(BridgeCase):
    def both_modes(self, events: list, expected: list[str]) -> list[dict]:
        result = run(events)
        self.check_invariants(result, expected)
        self.assertEqual(normalized(run(events, sync=True)), normalized(result))
        return result

    def test_installed(self) -> None:
        self.assertTrue(getattr(Parser.chunk_parser, fs.BRIDGE_MARKER, False))
        self.assertEqual(fs.patch_status(), {"stream_args": True, "chat_bridge": True, "token_refresh": True})

    def test_1_single_call_with_deltas_matches_original(self) -> None:
        events = [created(), *full_call(0, 1, '{"a":"Ё"}', ['{"a":', '"Ё"}']),
                  completed(call_item("fc1", "call1", '{"a":"Ё"}'))]
        result = self.both_modes(events, ['{"a":"Ё"}'])
        self.assertEqual(normalized(result), normalized(run_original(events)))

    def test_2_two_calls_sequential_without_deltas(self) -> None:
        events = [created(), *full_call(0, 1, '{"a":1}'), *full_call(1, 2, '{"b":2}'),
                  completed(call_item("fc1", "call1"), call_item("fc2", "call2"))]
        result = self.both_modes(events, ['{"a":1}', '{"b":2}'])
        self.assertEqual([b[1]["id"] for b in tool_blocks(result)], ["call1", "call2"])

    def test_3_two_calls_interleaved_without_deltas(self) -> None:
        events = [created(), added(0, "fc1", "call1"), added(1, "fc2", "call2"),
                  args_done(0, "fc1", '{"a":1}'), args_done(1, "fc2", '{"b":2}'),
                  item_done(0, "fc1", "call1", '{"a":1}'),
                  item_done(1, "fc2", "call2", '{"b":2}'),
                  completed(call_item("fc1", "call1"), call_item("fc2", "call2"))]
        result = self.both_modes(events, ['{"a":1}', '{"b":2}'])
        self.assertEqual([b[1]["id"] for b in tool_blocks(result)], ["call1", "call2"])

    def test_3b_interleaved_reverse_done_order(self) -> None:
        events = [created(), added(0, "fc1", "call1"), added(1, "fc2", "call2"),
                  args_done(1, "fc2", '{"b":2}'), args_done(0, "fc1", '{"a":1}'),
                  completed(call_item("fc1", "call1"), call_item("fc2", "call2"))]
        result = self.both_modes(events, ['{"b":2}', '{"a":1}'])
        self.assertEqual([b[1]["id"] for b in tool_blocks(result)], ["call2", "call1"])

    def test_4_two_calls_with_deltas_no_duplicates(self) -> None:
        events = [created(), added(0, "fc1", "call1"), added(1, "fc2", "call2"),
                  delta(0, "fc1", '{"a":'), delta(0, "fc1", "1}"),
                  delta(1, "fc2", '{"b":'), delta(1, "fc2", "2}"),
                  args_done(0, "fc1", '{"a":1}'), args_done(1, "fc2", '{"b":2}'),
                  item_done(0, "fc1", "call1", '{"a":1}'),
                  item_done(1, "fc2", "call2", '{"b":2}'),
                  completed(call_item("fc1", "call1"), call_item("fc2", "call2"))]
        self.both_modes(events, ['{"a":1}', '{"b":2}'])

    def test_4b_one_call_with_deltas_one_without(self) -> None:
        events = [created(), *full_call(0, 1, '{"a":1}', ['{"a":', "1}"]),
                  *full_call(1, 2, '{"b":2}'),
                  completed(call_item("fc1", "call1"), call_item("fc2", "call2"))]
        self.both_modes(events, ['{"a":1}', '{"b":2}'])

    def test_5_text_plus_two_calls(self) -> None:
        events = [created(), text_added(0, "m1"), text_delta(0, "m1", "Сейчас "),
                  text_delta(0, "m1", "сделаю"), text_done(0, "m1"),
                  *full_call(1, 1, '{"a":1}'), *full_call(2, 2, '{"b":2}'),
                  completed(call_item("fc1", "call1"), call_item("fc2", "call2"))]
        result = self.both_modes(events, ['{"a":1}', '{"b":2}'])
        text = "".join(e["delta"]["text"] for e in result
                       if e["type"] == "content_block_delta" and e["delta"]["type"] == "text_delta")
        self.assertEqual(text, "Сейчас сделаю")
        # Индексы моста последовательные, хотя output_index счётчик всех элементов.
        self.assertEqual(result[1]["content_block"]["type"], "text")

    def test_6_long_unicode_arguments(self) -> None:
        payload = {"text": "Привет, мир! 🚀🔥 " * LONG_REPEAT, "n": [1, 2]}
        arguments = json.dumps(payload, ensure_ascii=False)
        self.assertGreater(len(arguments.encode()), 10 * 1024)
        events = [created(), *full_call(0, 1, arguments), *full_call(1, 2, '{"b":2}'),
                  completed(call_item("fc1", "call1"), call_item("fc2", "call2"))]
        result = self.both_modes(events, [arguments, '{"b":2}'])
        self.assertEqual(json.loads(tool_blocks(result)[0][2]), payload)

    def test_6b_long_native_deltas(self) -> None:
        arguments = json.dumps({"t": "Ёж 🦔 " * LONG_REPEAT}, ensure_ascii=False)
        parts = [arguments[i:i + CHUNK_SIZE] for i in range(0, len(arguments), CHUNK_SIZE)]
        events = [created(), *full_call(0, 1, arguments, parts),
                  completed(call_item("fc1", "call1"))]
        result = self.both_modes(events, [arguments])
        self.assertEqual(normalized(result), normalized(run_original(events)))

    def test_7_empty_object_once(self) -> None:
        events = [created(), *full_call(0, 1, "{}"), *full_call(1, 2, "{}"),
                  completed(call_item("fc1", "call1"), call_item("fc2", "call2"))]
        result = self.both_modes(events, ["{}", "{}"])
        for idx, _, _ in tool_blocks(result):
            deltas = [e for e in result if e["type"] == "content_block_delta"
                      and e["index"] == idx]
            self.assertEqual(len(deltas), 1)

    def test_8_only_item_done_with_arguments(self) -> None:
        events = [created(),
                  added(0, "fc1", "call1"), item_done(0, "fc1", "call1", '{"a":1}'),
                  added(1, "fc2", "call2"), item_done(1, "fc2", "call2", '{"b":2}'),
                  completed(call_item("fc1", "call1"), call_item("fc2", "call2"))]
        self.both_modes(events, ['{"a":1}', '{"b":2}'])

    def test_8b_no_arguments_anywhere_call_not_lost(self) -> None:
        events = [created(), added(0, "fc1", "call1"), item_done(0, "fc1", "call1", ""),
                  completed(call_item("fc1", "call1"))]
        result = run(events)
        blocks = tool_blocks(result)
        self.assertEqual([(b[1]["id"], b[2]) for b in blocks], [("call1", "")])

    def test_9_without_patch_two_calls_break(self) -> None:
        """Мутационный: на оригинальном парсере 2 вызова без дельт теряют аргументы."""
        events = [created(), added(0, "fc1", "call1"), added(1, "fc2", "call2"),
                  args_done(0, "fc1", '{"a":1}'), args_done(1, "fc2", '{"b":2}'),
                  item_done(0, "fc1", "call1", '{"a":1}'),
                  item_done(1, "fc2", "call2", '{"b":2}'),
                  completed(call_item("fc1", "call1"), call_item("fc2", "call2"))]
        broken = [b[2] for b in tool_blocks(run_original(events))]
        self.assertNotEqual(broken, ['{"a":1}', '{"b":2}'])
        with self.assertRaises(AssertionError):
            self.check_invariants(run_original(events), ['{"a":1}', '{"b":2}'])

    def test_10_tool_call_index_map_same_as_original(self) -> None:
        events = [created(), text_added(0, "m1"), text_done(0, "m1"),
                  *full_call(1, 1, '{"a":1}'), *full_call(2, 2, '{"b":2}'),
                  completed(call_item("fc1", "call1"), call_item("fc2", "call2"))]
        patched_it, original_it = Parser(None, False), Parser(None, False)
        for event in events:
            Parser.chunk_parser(patched_it, event)
            ORIGINAL_PARSER(original_it, event)
        self.assertEqual(patched_it._tool_call_index_map, original_it._tool_call_index_map)
        self.assertEqual(patched_it._tool_call_index_map, {1: 0, 2: 1})

    def test_11_enum_type_and_model_dump_events(self) -> None:
        from litellm.types.llms import openai as oa
        from litellm.types.llms.openai import ResponsesAPIStreamEvents as E

        item_added = oa.BaseLiteLLMOpenAIResponseObject(**call_item("fc1", "call1"))
        item_final = oa.BaseLiteLLMOpenAIResponseObject(**call_item("fc1", "call1", '{"a":1}'))
        events = [
            created(),
            oa.OutputItemAddedEvent(type=E.OUTPUT_ITEM_ADDED, output_index=0,
                                    item=item_added).model_dump(),
            oa.FunctionCallArgumentsDoneEvent(type=E.FUNCTION_CALL_ARGUMENTS_DONE,
                                              item_id="fc1", output_index=0,
                                              arguments='{"a":1}').model_dump(),
            oa.OutputItemDoneEvent(type=E.OUTPUT_ITEM_DONE, output_index=0,
                                   item=item_final).model_dump(),
            completed(call_item("fc1", "call1")),
        ]
        self.assertIsInstance(events[1]["type"], E)
        self.check_invariants(run(events), ['{"a":1}'])

    def test_12_custom_tool_call(self) -> None:
        item = {"type": "custom_tool_call", "id": "ct1", "call_id": "cc1", "name": "patch",
                "input": ""}
        events = [created(),
                  {"type": "response.output_item.added", "output_index": 0, "item": item},
                  {"type": "response.custom_tool_call_input.done", "output_index": 0,
                   "item_id": "ct1", "input": "*** raw"},
                  {"type": "response.output_item.done", "output_index": 0,
                   "item": dict(item, input="*** raw")},
                  completed(item)]
        blocks = tool_blocks(run(events))
        self.assertEqual([(b[1]["name"], b[2]) for b in blocks], [("patch", "*** raw")])

    def test_13_args_done_without_output_index(self) -> None:
        """Нет output_index: вызов находится по item_id."""
        done = args_done(1, "fc2", '{"b":2}')
        del done["output_index"]
        events = [created(), added(0, "fc1", "call1"), added(1, "fc2", "call2"),
                  args_done(0, "fc1", '{"a":1}'), done,
                  completed(call_item("fc1", "call1"), call_item("fc2", "call2"))]
        self.check_invariants(run(events), ['{"a":1}', '{"b":2}'])


class BridgeFailSafeTest(BridgeCase):
    def test_14_stream_without_done_events_warns_and_keeps_first(self) -> None:
        events = [created(), added(0, "fc1", "call1"), added(1, "fc2", "call2"),
                  completed(call_item("fc1", "call1", '{"a":1}'),
                            call_item("fc2", "call2", '{"b":2}'))]
        with self.assertLogs(fs.LOGGER_NAME, level="WARNING"):
            result = run(events)
        blocks = tool_blocks(result)
        # Вызов не потерян: первый выдан вместе с completed (аргументы из response.output).
        self.assertEqual([(b[1]["id"], b[2]) for b in blocks], [("call1", '{"a":1}')])
        self.assertEqual(result[-1]["type"], "message_stop")

    def test_15_logic_failure_flushes_pending_and_falls_back(self) -> None:
        events = [created(), added(0, "fc1", "call1"), added(1, "fc2", "call2"),
                  args_done(0, "fc1", '{"a":1}'), args_done(1, "fc2", '{"b":2}'),
                  completed(call_item("fc1", "call1"), call_item("fc2", "call2"))]
        real = fs._after_original
        calls = {"n": 0}

        def flaky(state: Any, data: Any, out: Any) -> Any:
            calls["n"] += 1
            if calls["n"] == 4:  # на первом args.done логика падает (после двух added)
                raise RuntimeError("boom")
            return real(state, data, out)

        with mock.patch.object(fs, "_after_original", side_effect=flaky):
            with self.assertLogs(fs.LOGGER_NAME, level="WARNING") as logs:
                result = run(events)  # исключения наружу быть не должно
        self.assertEqual(len([r for r in logs.records if "сбой патча моста" in r.getMessage()]),
                         1)
        ids = [b[1]["id"] for b in tool_blocks(result)]
        self.assertEqual(ids, ["call1", "call2"], "вызовы не должны теряться при сбое")

    def test_16_original_exception_propagates(self) -> None:
        iterator = Parser(None, False)
        with self.assertRaises(ValueError):
            Parser.chunk_parser(iterator, {"type": "response.function_call_arguments.delta",
                                           "output_index": 0, "delta": ""})

    def test_17_unknown_events_unchanged(self) -> None:
        events = [created(), {"type": "response.in_progress"}, text_added(0, "m"),
                  text_delta(0, "m", "привет"), text_done(0, "m"),
                  completed({"type": "message"})]
        patched = run(events)
        self.assertEqual(normalized(patched), normalized(run_original(events)))


class BridgeInstallTest(unittest.TestCase):
    def test_import_error_returns_false(self) -> None:
        with mock.patch.object(fs.importlib, "import_module", side_effect=ImportError("нет")):
            with self.assertLogs(fs.LOGGER_NAME, level="WARNING"):
                self.assertFalse(fs.install_chat_bridge_patch())

    def test_missing_class_method_or_index_helper(self) -> None:
        class NoMethod:
            pass

        class NoIndex:
            def chunk_parser(self, chunk: Any) -> Any:
                return chunk

        for cls in (None, NoMethod, NoIndex):
            attrs = {} if cls is None else {fs.BRIDGE_CLASS_NAME: cls}
            module = type("M", (), attrs)
            with mock.patch.object(fs.importlib, "import_module", return_value=module):
                with self.assertLogs(fs.LOGGER_NAME, level="WARNING"):
                    self.assertFalse(fs.install_chat_bridge_patch())

    def test_idempotent_and_original_kept(self) -> None:
        class Fake:
            def chunk_parser(self, chunk: Any) -> Any:
                return chunk

            @staticmethod
            def _sequential_tool_call_index(index_map: Any, output_index: int) -> int:
                return output_index

        original = Fake.chunk_parser
        module = type("M", (), {fs.BRIDGE_CLASS_NAME: Fake})
        with mock.patch.object(fs.importlib, "import_module", return_value=module):
            with mock.patch.object(fs.importlib.metadata, "version",
                                   return_value=fs.TESTED_LITELLM_VERSION):
                self.assertTrue(fs.install_chat_bridge_patch())
                first = Fake.chunk_parser
                self.assertTrue(fs.install_chat_bridge_patch())
        self.assertIs(Fake.chunk_parser, first)
        self.assertIs(getattr(first, fs.BRIDGE_ORIGINAL_ATTR), original)

    def test_real_class_not_double_wrapped(self) -> None:
        before = Parser.chunk_parser
        self.assertTrue(fs.install_chat_bridge_patch())
        self.assertIs(Parser.chunk_parser, before)

    def test_patches_are_independent(self) -> None:
        with mock.patch.object(fs, "STREAM_MODULE_PATH", "no.such.module"):
            with self.assertLogs(fs.LOGGER_NAME, level="WARNING"):
                self.assertFalse(fs.install_stream_args_patch())
            self.assertTrue(fs.install_chat_bridge_patch())
            status = fs.patch_status()
        self.assertEqual(status, {"stream_args": False, "chat_bridge": True, "token_refresh": True})

    def test_install_patches_summary_levels(self) -> None:
        with mock.patch.object(fs, "install_stream_args_patch", return_value=True), \
                mock.patch.object(fs, "install_chat_bridge_patch", return_value=False):
            with self.assertLogs(fs.LOGGER_NAME, level="WARNING") as logs:
                result = fs.install_patches()
        self.assertEqual(result, {"stream_args": True, "chat_bridge": False, "token_refresh": True})
        self.assertEqual(len(logs.records), 1)
        self.assertEqual(logs.records[0].levelname, "WARNING")
        with mock.patch.object(fs, "install_stream_args_patch", return_value=True), \
                mock.patch.object(fs, "install_chat_bridge_patch", return_value=True):
            with self.assertLogs(fs.LOGGER_NAME, level="INFO") as logs:
                fs.install_patches()
        self.assertEqual(logs.records[0].levelname, "INFO")


if __name__ == "__main__":
    unittest.main()
