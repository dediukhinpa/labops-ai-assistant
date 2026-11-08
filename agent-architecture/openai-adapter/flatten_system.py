"""Хуки LiteLLM для шлюза Claude Code -> ChatGPT (Responses API).

Модуль подключается в config.yaml как `callbacks: flatten_system.flatten_system` и
импортируется внутри процесса LiteLLM. Хук делает две вещи.

1. Система: system-промпт Claude Code (список блоков) превращается в строку. Бэкенд
   подписки ChatGPT отвечает «System messages are not allowed», если LiteLLM кладёт
   system-блоки во вход Responses API как сообщения. Строка уходит в `instructions`, и
   запрос проходит.

2. Стрим аргументов инструментов: когда за ход идёт 2+ вызова инструментов, бэкенд не шлёт
   `response.function_call_arguments.delta`, а отдаёт аргументы целиком только в
   `response.function_call_arguments.done` и `response.output_item.done`. LiteLLM берёт
   аргументы лишь из `.delta`, поэтому клиент получал tool_use с пустым input. Для провайдера
   chatgpt/ запрос идёт по цепочке «адаптер Anthropic -> мост Responses->chat», поэтому
   патчей два, при импорте ставятся оба (install_patches):

   - install_stream_args_patch: AnthropicResponsesStreamWrapper._process_event (маршрут
     напрямую через Responses; запасной, если маршрут переключится);
   - install_chat_bridge_patch: OpenAiResponsesToChatCompletionStreamIterator.chunk_parser
     (маршрут chatgpt/). Адаптер Anthropic последователен: tool_call-чанк с именем открывает
     новый блок, а аргументы идут в ТЕКУЩИЙ блок независимо от index. Поэтому вызов
     выдаётся атомарно: чанк output_item.added откладывается и уходит одним tool_call
     (id + имя + аргументы), когда аргументы известны.

   Non-stream путь, текстовые блоки и reasoning не затрагиваются.

3. Токен подписки: сервер ChatGPT перестаёт принимать access_token раньше, чем срок `exp`
   внутри него (на практике через ~2 суток при `exp` в 10 суток), а LiteLLM обновляет токен
   только по `exp` и на 401 не реагирует. Поэтому get_access_token оборачивается
   (install_token_refresh_patch): токен старше MAX_TOKEN_AGE_H часов (по `iat`) обновляется
   по refresh_token заранее, а при 401 token_expired хук async_post_call_failure_hook
   принудительно обновляет его, чтобы повтор запроса клиентом прошёл. Обновления идут
   под одной блокировкой с перечиткой auth.json: refresh_token одноразовый, два
   параллельных обмена сломали бы друг другу вход.

   patch_status() показывает, какие патчи стоят.
"""
import asyncio
import base64
import copy
import functools
import importlib
import importlib.metadata
import json
import logging
import os
import threading
import time
from collections.abc import Callable, Mapping
from typing import Any

from litellm.integrations.custom_logger import CustomLogger
from litellm.types.utils import Delta

# Дочерний логгер LiteLLM: наследует его обработчики и уровень (LITELLM_LOG), поэтому
# сообщения хука попадают в тот же журнал, что и логи прокси.
LOGGER_NAME = "LiteLLM.flatten_system"
logger = logging.getLogger(LOGGER_NAME)

# Версия LiteLLM, на которой патч проверен.
TESTED_LITELLM_VERSION = "1.106.3"
# Куда патчим.
STREAM_MODULE_PATH = (
    "litellm.llms.anthropic.pass_through.responses_adapters.streaming_iterator"
)
STREAM_CLASS_NAME = "AnthropicResponsesStreamWrapper"
STREAM_METHOD_NAME = "_process_event"

# Маркер на обёртке: повторная установка не оборачивает метод дважды.
PATCH_MARKER = "_flatten_system_args_patch"
# Ссылка на исходный метод (для тестов и отката).
ORIGINAL_ATTR = "_flatten_system_original"
# Состояние на экземпляре обёртки потока; префикс уникальный, чтобы не пересечься с LiteLLM.
STATE_ATTR = "_flatten_system_args_state"

# Мост Responses->chat (маршрут chatgpt/).
BRIDGE_MODULE_PATH = "litellm.completion_extras.litellm_responses_transformation.transformation"
BRIDGE_CLASS_NAME = "OpenAiResponsesToChatCompletionStreamIterator"
BRIDGE_METHOD_NAME = "chunk_parser"
BRIDGE_INDEX_METHOD = "_sequential_tool_call_index"
# Маркер/оригинал/состояние второго патча (независимы от первого).
BRIDGE_MARKER = "_flatten_system_bridge_patch"
BRIDGE_ORIGINAL_ATTR = "_flatten_system_bridge_original"
BRIDGE_STATE_ATTR = "_flatten_system_bridge_state"

# Типы событий Responses API.
EVENT_ARGS_DELTA = "response.function_call_arguments.delta"
EVENT_ARGS_DONE = "response.function_call_arguments.done"
EVENT_ITEM_DONE = "response.output_item.done"
ITEM_FUNCTION_CALL = "function_call"
ITEM_CUSTOM_TOOL_CALL = "custom_tool_call"
TOOL_ITEM_TYPES = (ITEM_FUNCTION_CALL, ITEM_CUSTOM_TOOL_CALL)
EVENT_ITEM_ADDED = "response.output_item.added"
EVENT_CUSTOM_DELTA = "response.custom_tool_call_input.delta"
EVENT_CUSTOM_DONE = "response.custom_tool_call_input.done"
EVENTS_TERMINAL = ("response.completed", "response.incomplete")
# Поле с аргументами: у обычного вызова arguments, у custom_tool_call input.
ARGUMENT_FIELDS = ("arguments", "input")


def _flatten(blocks: list[Any]) -> str:
    """Склеивает текстовые блоки в одну строку."""
    parts = [b.get("text", "") for b in blocks if isinstance(b, dict) and b.get("type") == "text"]
    return "\n\n".join(p for p in parts if p)


class FlattenSystem(CustomLogger):
    """Приводит system к строке до перевода запроса в формат OpenAI."""

    async def async_pre_call_hook(self, user_api_key_dict, cache, data, call_type):
        system = data.get("system")
        if isinstance(system, list):
            data["system"] = _flatten(system)
        for msg in data.get("messages") or []:
            if (isinstance(msg, dict) and msg.get("role") == "system"
                    and isinstance(msg.get("content"), list)):
                msg["content"] = _flatten(msg["content"])
        return data

    async def async_post_call_failure_hook(
        self, request_data, original_exception, user_api_key_dict, traceback_str=None
    ):
        """401 token_expired от ChatGPT: обновляет токен, чтобы повтор клиента прошёл."""
        if _is_token_expired_error(original_exception):
            await asyncio.to_thread(force_token_refresh)
        return None


flatten_system = FlattenSystem()


# --------------------------------------------------------------------------------------
# Патч стрима: аргументы инструментов из .done-событий
# --------------------------------------------------------------------------------------

class _ArgsState:
    """Состояние дозаписи аргументов на одном экземпляре обёртки потока.

    Attributes:
        delta_blocks: Индексы блоков, по которым уже ушёл непустой родной input_json_delta.
        injected_blocks: Индексы блоков, куда аргументы вставили мы.
        closed_blocks: Индексы function_call-блоков, закрытых по output_item.done.
        failed: Логика патча уже падала на этом потоке; дальше только оригинал.
    """

    def __init__(self) -> None:
        self.delta_blocks: set[int] = set()
        self.injected_blocks: set[int] = set()
        self.closed_blocks: set[int] = set()
        self.failed: bool = False


def _get(source: object, name: str) -> object:
    """Читает поле и из dict-события, и из объекта с атрибутами."""
    if isinstance(source, Mapping):
        return source.get(name)
    return getattr(source, name, None)


def _event_type(event: object) -> object:
    """Тип события так же, как это делает оригинал: сначала атрибут, затем ключ dict."""
    event_type = getattr(event, "type", None)
    if event_type is None and isinstance(event, dict):
        event_type = event.get("type")
    return event_type


def _get_state(wrapper: Any) -> _ArgsState:
    """Возвращает (лениво создавая) состояние патча на экземпляре обёртки."""
    state = wrapper.__dict__.get(STATE_ATTR)
    if state is None:
        state = _ArgsState()
        setattr(wrapper, STATE_ATTR, state)
    return state


def _structures_ok(wrapper: Any) -> bool:
    """Проверяет, что у экземпляра есть структуры LiteLLM нужного типа."""
    queue = getattr(wrapper, "_chunk_queue", None)
    return (
        callable(getattr(queue, "append", None))
        and isinstance(getattr(wrapper, "_item_id_to_block_index", None), dict)
        and isinstance(getattr(wrapper, "_pending_tool_ids", None), dict)
    )


def _open_tool_block(wrapper: Any, item_id: object) -> int | None:
    """Индекс блока открытого function_call по item_id или None."""
    if not isinstance(item_id, str) or not item_id:
        return None
    if item_id not in wrapper._pending_tool_ids:
        return None
    index = wrapper._item_id_to_block_index.get(item_id)
    return index if isinstance(index, int) and index >= 0 else None


def _native_delta_block(wrapper: Any, event: object) -> int:
    """Индекс блока для .delta ровно так же, как считает оригинал."""
    item_id = _get(event, "item_id")
    if item_id:
        return wrapper._item_id_to_block_index.get(item_id, wrapper._current_block_index)
    return wrapper._current_block_index


def _inject_arguments(wrapper: Any, state: _ArgsState, index: int, arguments: object) -> None:
    """Ставит в очередь один input_json_delta с полными аргументами, если это уместно.

    Не вставляем, если: по блоку уже шли родные дельты, мы уже вставляли, блок закрыт,
    а также если arguments не строка или пустая строка. Строку "{}" вставляем: клиент
    получает полный и валидный JSON-поток, это безвредно, а единственная вставка на
    блок гарантируется множеством injected_blocks.
    """
    if not isinstance(arguments, str) or not arguments:
        return
    if (index in state.delta_blocks or index in state.injected_blocks
            or index in state.closed_blocks):
        return
    wrapper._chunk_queue.append(
        {
            "type": "content_block_delta",
            "index": index,
            "delta": {"type": "input_json_delta", "partial_json": arguments},
        }
    )
    state.injected_blocks.add(index)


def _before_original(wrapper: Any, event: object, state: _ArgsState) -> None:
    """Действия патча, которые должны пройти ДО вызова оригинального обработчика."""
    event_type = _event_type(event)
    if event_type == EVENT_ARGS_DELTA:
        delta = _get(event, "delta")
        if isinstance(delta, str) and delta:
            state.delta_blocks.add(_native_delta_block(wrapper, event))
    elif event_type == EVENT_ARGS_DONE:
        item_id = _get(event, "item_id")
        index = _open_tool_block(wrapper, item_id)
        if index is not None:
            _inject_arguments(wrapper, state, index, _get(event, "arguments"))
    elif event_type == EVENT_ITEM_DONE:
        item = _get(event, "item")
        if item is None or _get(item, "type") != ITEM_FUNCTION_CALL:
            return
        index = _open_tool_block(wrapper, _get(item, "id"))
        if index is not None:
            _inject_arguments(wrapper, state, index, _get(item, "arguments"))
            # Оригинал сейчас положит content_block_stop: после него вставлять поздно.
            state.closed_blocks.add(index)


def _make_patched(original: Callable[[Any, object], None]) -> Callable[[Any, object], None]:
    """Строит обёртку над оригинальным _process_event."""

    @functools.wraps(original)
    def patched_process_event(self: Any, event: object) -> None:
        # Оригинал вызывается ровно один раз и вне try: сбой патча не должен ломать стрим,
        # а ошибки самого оригинала не должны маскироваться.
        try:
            state = _get_state(self)
            if not state.failed:
                if _structures_ok(self):
                    _before_original(self, event, state)
                else:
                    state.failed = True
                    logger.warning(
                        "flatten_system: у %s нет ожидаемых структур, патч аргументов "
                        "отключён для этого потока", type(self).__name__,
                    )
        except Exception:  # noqa: BLE001 - патч не должен ронять стрим
            logger.warning(
                "flatten_system: сбой патча аргументов инструментов, "
                "дальше работает оригинал", exc_info=True,
            )
            try:
                self.__dict__.setdefault(STATE_ATTR, _ArgsState()).failed = True
            except Exception:  # noqa: BLE001
                pass
        return original(self, event)

    setattr(patched_process_event, PATCH_MARKER, True)
    setattr(patched_process_event, ORIGINAL_ATTR, original)
    return patched_process_event


def install_stream_args_patch() -> bool:
    """Оборачивает AnthropicResponsesStreamWrapper._process_event.

    Идемпотентна: повторный вызов не оборачивает метод второй раз. Если модуль, класс
    или метод не найдены, пишет warning и возвращает False (хук system при этом работает).
    Версия LiteLLM, отличная от проверенной, даёт warning, но патч ставится.

    Returns:
        True, если патч установлен (или уже стоял), иначе False.
    """
    try:
        module = importlib.import_module(STREAM_MODULE_PATH)
        cls = getattr(module, STREAM_CLASS_NAME, None)
        method = getattr(cls, STREAM_METHOD_NAME, None) if cls is not None else None
    except Exception:  # noqa: BLE001 - любая причина = патч не ставим
        logger.warning(
            "flatten_system: не удалось импортировать %s, патч не установлен",
            STREAM_MODULE_PATH, exc_info=True,
        )
        return False
    if cls is None or not callable(method):
        logger.warning(
            "flatten_system: нет %s.%s в %s, патч не установлен",
            STREAM_CLASS_NAME, STREAM_METHOD_NAME, STREAM_MODULE_PATH,
        )
        return False
    if getattr(method, PATCH_MARKER, False):
        logger.debug("flatten_system: патч стрима уже установлен")
        return True

    try:
        version = importlib.metadata.version("litellm")
    except Exception:  # noqa: BLE001
        version = "неизвестна"
    if version != TESTED_LITELLM_VERSION:
        logger.warning(
            "flatten_system: версия litellm %s, патч проверен на %s",
            version, TESTED_LITELLM_VERSION,
        )

    setattr(cls, STREAM_METHOD_NAME, _make_patched(method))
    logger.debug("flatten_system: патч потока Responses установлен (litellm %s)", version)
    return True


# --------------------------------------------------------------------------------------
# Патч моста Responses->chat: отложенная атомарная выдача вызова инструмента
# --------------------------------------------------------------------------------------

class _Deferred:
    """Отложенный чанк output_item.added, ждущий аргументов.

    Attributes:
        chunk: Чанк, который оригинал выдал бы на output_item.added (id, имя, индекс).
        item_id: id элемента Responses API (для поиска аргументов в response.completed).
    """

    def __init__(self, chunk: Any, item_id: object) -> None:
        self.chunk = chunk
        self.item_id = item_id


class _BridgeState:
    """Состояние моста на одном экземпляре итератора потока.

    Attributes:
        pending: output_index -> отложенный вызов, ещё не выданный клиенту.
        emitted: output_index вызовов, уже выданных (в том числе без отсрочки).
        item_to_index: id элемента -> output_index (события .done могут идти по item_id).
        failed: логика патча уже падала на этом потоке; дальше оригинал + выдача отложенного.
    """

    def __init__(self) -> None:
        self.pending: dict[int, _Deferred] = {}
        self.emitted: set[int] = set()
        self.item_to_index: dict[str, int] = {}
        self.failed: bool = False


def _bridge_state(parser: Any) -> _BridgeState:
    """Возвращает (лениво создавая) состояние моста на экземпляре итератора."""
    state = parser.__dict__.get(BRIDGE_STATE_ATTR)
    if state is None:
        state = _BridgeState()
        setattr(parser, BRIDGE_STATE_ATTR, state)
    return state


def _event_dict(chunk: object) -> dict | None:
    """Событие Responses как dict: оригинал принимает и dict, и pydantic-модель."""
    if isinstance(chunk, dict):
        return chunk
    dump = getattr(chunk, "model_dump", None)
    if callable(dump):
        result = dump()
        return result if isinstance(result, dict) else None
    return None


def _type_value(event_type: object) -> object:
    """Тип события строкой: он может прийти enum-ом ResponsesAPIStreamEvents."""
    return getattr(event_type, "value", event_type)


def _chunk_tool_calls(chunk: Any) -> list | None:
    """tool_calls первого choice чанка или None."""
    choices = getattr(chunk, "choices", None)
    if not choices:
        return None
    tool_calls = getattr(getattr(choices[0], "delta", None), "tool_calls", None)
    return list(tool_calls) if tool_calls else None


def _chunk_arguments(chunk: Any) -> str:
    """Строка аргументов первого tool_call чанка (пустая, если их нет)."""
    tool_calls = _chunk_tool_calls(chunk)
    if not tool_calls:
        return ""
    function = getattr(tool_calls[0], "function", None)
    arguments = getattr(function, "arguments", None)
    return arguments if isinstance(arguments, str) else ""


def _neutral_chunk(chunk: Any) -> Any:
    """Нейтральный чанк: как оригинал на output_item.done (пустой Delta, без finish_reason).

    Берём копию отложенного чанка, чтобы сохранить id потока и service_tier.
    """
    neutral = copy.deepcopy(chunk)
    neutral.choices[0].delta = Delta()
    return neutral


def _resolve_index(state: _BridgeState, data: Mapping, item_id: object) -> int | None:
    """output_index вызова: по item_id, иначе по полю output_index (по умолчанию 0)."""
    if isinstance(item_id, str) and item_id in state.item_to_index:
        return state.item_to_index[item_id]
    index = data.get("output_index", 0)
    return index if isinstance(index, int) else None


def _emit_deferred(state: _BridgeState, index: int, arguments: str) -> Any:
    """Достаёт отложенный вызов, подставляет аргументы и отдаёт его как чанк.

    Пустую строку аргументов оставляем как есть: так поступил бы оригинал на added.
    """
    deferred = state.pending[index]
    if arguments:
        deferred.chunk.choices[0].delta.tool_calls[0].function.arguments = arguments
    # Убираем из pending только после успешной подстановки: при сбое вызов не потеряется.
    del state.pending[index]
    state.emitted.add(index)
    return deferred.chunk


def _terminal_arguments(data: Mapping, item_id: object) -> str:
    """Аргументы вызова из response.output в completed/incomplete (если они там есть)."""
    response = data.get("response")
    output = response.get("output") if isinstance(response, Mapping) else None
    for item in output if isinstance(output, list) else ():
        if isinstance(item, Mapping) and item.get("id") == item_id:
            for field in ARGUMENT_FIELDS:
                value = item.get(field)
                if isinstance(value, str) and value:
                    return value
    return ""


def _flush_on_terminal(state: _BridgeState, data: Mapping, out: Any) -> Any:
    """Невыданные вызовы к концу потока: warning и выдача первого вместе с completed.

    Нормальные потоки сюда не попадают. Чанк completed несёт finish_reason, адаптер
    Anthropic разделяет такой чанк на «содержимое» и «конец», поэтому tool_call в нём
    не теряется. Несколько вызовов в одном чанке не уместить: остальные только в warning.
    """
    pending = state.pending
    logger.warning(
        "flatten_system: к концу потока остались вызовы без аргументов: %d", len(pending)
    )
    index = min(pending)
    deferred = pending[index]
    arguments = _terminal_arguments(data, deferred.item_id)
    emitted = _emit_deferred(state, index, arguments)
    pending.clear()
    if _chunk_tool_calls(out) is None:
        out.choices[0].delta.tool_calls = _chunk_tool_calls(emitted)
    return out


def _after_original(state: _BridgeState, data: Mapping, out: Any) -> Any:
    """Подменяет результат оригинального chunk_parser для событий вызовов инструментов."""
    event_type = _type_value(data.get("type"))
    if event_type == EVENT_ITEM_ADDED:
        item = data.get("item")
        if not isinstance(item, Mapping) or item.get("type") not in TOOL_ITEM_TYPES:
            return out
        index = data.get("output_index", 0)
        if not isinstance(index, int) or not _chunk_tool_calls(out):
            return out
        item_id = item.get("id")
        if isinstance(item_id, str):
            state.item_to_index[item_id] = index
        if _chunk_arguments(out):
            # Аргументы уже в added: откладывать нечего.
            state.emitted.add(index)
            return out
        neutral = _neutral_chunk(out)
        state.pending[index] = _Deferred(out, item_id)
        return neutral
    if event_type in (EVENT_ARGS_DELTA, EVENT_CUSTOM_DELTA):
        index = _resolve_index(state, data, data.get("item_id"))
        arguments = _chunk_arguments(out)
        if index in state.pending and arguments:
            # Первая непустая дельта: id + имя + начало аргументов одним tool_call.
            return _emit_deferred(state, index, arguments)
        return out
    if event_type in (EVENT_ARGS_DONE, EVENT_CUSTOM_DONE):
        index = _resolve_index(state, data, data.get("item_id"))
        arguments = data.get("arguments") or data.get("input")
        if index in state.pending and isinstance(arguments, str) and arguments:
            return _emit_deferred(state, index, arguments)
        return out
    if event_type == EVENT_ITEM_DONE:
        item = data.get("item")
        if not isinstance(item, Mapping) or item.get("type") not in TOOL_ITEM_TYPES:
            return out
        index = _resolve_index(state, data, item.get("id"))
        if index in state.pending:
            # Последний шанс: без выдачи на added вызов пропал бы целиком.
            arguments = next((item[f] for f in ARGUMENT_FIELDS
                              if isinstance(item.get(f), str) and item[f]), "")
            return _emit_deferred(state, index, arguments)
        return out
    if event_type in EVENTS_TERMINAL and state.pending:
        return _flush_on_terminal(state, data, out)
    return out


def _drain_one(state: _BridgeState, out: Any) -> Any:
    """После сбоя логики: отдаёт один отложенный вызов вместо нейтрального чанка.

    Чанки с содержимым или finish_reason не трогаем, чтобы не испортить поток.
    """
    if not state.pending:
        return out
    choices = getattr(out, "choices", None)
    if not choices or _chunk_tool_calls(out) or choices[0].finish_reason is not None:
        return out
    index = min(state.pending)
    return _emit_deferred(state, index, "")


def _make_patched_chunk_parser(original: Callable[[Any, Any], Any]) -> Callable[[Any, Any], Any]:
    """Строит обёртку над оригинальным chunk_parser."""

    @functools.wraps(original)
    def patched_chunk_parser(self: Any, chunk: Any) -> Any:
        # Оригинал зовётся первым и ровно один раз: порядок назначения индексов
        # (_tool_call_index_map) совпадает с оригинальным, его ошибки идут наружу как есть.
        out = original(self, chunk)
        try:
            state = _bridge_state(self)
            if state.failed:
                return _drain_one(state, out)
            data = _event_dict(chunk)
            if data is None:
                return out
            return _after_original(state, data, out)
        except Exception:  # noqa: BLE001 - патч не должен ронять стрим
            logger.warning(
                "flatten_system: сбой патча моста, дальше работает оригинал", exc_info=True
            )
            try:
                state = _bridge_state(self)
                state.failed = True
                return _drain_one(state, out)
            except Exception:  # noqa: BLE001
                return out

    setattr(patched_chunk_parser, BRIDGE_MARKER, True)
    setattr(patched_chunk_parser, BRIDGE_ORIGINAL_ATTR, original)
    return patched_chunk_parser


def install_chat_bridge_patch() -> bool:
    """Оборачивает OpenAiResponsesToChatCompletionStreamIterator.chunk_parser.

    Независима от install_stream_args_patch и идемпотентна. Если модуль, класс, метод
    chunk_parser или _sequential_tool_call_index не найдены, пишет warning и возвращает
    False. Версия LiteLLM, отличная от проверенной, даёт warning, но патч ставится.

    Returns:
        True, если патч установлен (или уже стоял), иначе False.
    """
    try:
        module = importlib.import_module(BRIDGE_MODULE_PATH)
        cls = getattr(module, BRIDGE_CLASS_NAME, None)
        method = getattr(cls, BRIDGE_METHOD_NAME, None) if cls is not None else None
        index_method = getattr(cls, BRIDGE_INDEX_METHOD, None) if cls is not None else None
    except Exception:  # noqa: BLE001 - любая причина = патч не ставим
        logger.warning(
            "flatten_system: не удалось импортировать %s, патч моста не установлен",
            BRIDGE_MODULE_PATH, exc_info=True,
        )
        return False
    if cls is None or not callable(method) or not callable(index_method):
        logger.warning(
            "flatten_system: нет %s.%s или %s в %s, патч моста не установлен",
            BRIDGE_CLASS_NAME, BRIDGE_METHOD_NAME, BRIDGE_INDEX_METHOD, BRIDGE_MODULE_PATH,
        )
        return False
    if getattr(method, BRIDGE_MARKER, False):
        logger.debug("flatten_system: патч моста уже установлен")
        return True

    try:
        version = importlib.metadata.version("litellm")
    except Exception:  # noqa: BLE001
        version = "неизвестна"
    if version != TESTED_LITELLM_VERSION:
        logger.warning(
            "flatten_system: версия litellm %s, патч проверен на %s",
            version, TESTED_LITELLM_VERSION,
        )

    setattr(cls, BRIDGE_METHOD_NAME, _make_patched_chunk_parser(method))
    logger.debug("flatten_system: патч моста Responses->chat установлен (litellm %s)", version)
    return True


# --------------------------------------------------------------------------------------
# Токен подписки: обновление по возрасту и после 401
# --------------------------------------------------------------------------------------

AUTH_MODULE_PATH = "litellm.llms.chatgpt.authenticator"
AUTH_CLASS_NAME = "Authenticator"
AUTH_METHOD_NAME = "get_access_token"
AUTH_REFRESH_METHOD = "_refresh_tokens"
AUTH_READ_METHOD = "_read_auth_file"
AUTH_MARKER = "_flatten_system_token_patch"
AUTH_ORIGINAL_ATTR = "_flatten_system_token_original"

# Переменная окружения с предельным возрастом токена (часы) и значение по умолчанию.
# Сервер отвергал токен через ~53 ч после выпуска; 12 ч дают большой запас.
MAX_TOKEN_AGE_ENV = "LABOPS_CHATGPT_MAX_TOKEN_AGE_H"
DEFAULT_MAX_TOKEN_AGE_H = 12.0
SECONDS_PER_HOUR = 3600
# Не чаще одного принудительного обновления за это время: пачка запросов с 401 даёт
# один обмен refresh_token, а не десяток.
FORCE_COOLDOWN_SECONDS = 30
# Коды ответа OAuth, при которых refresh_token уже не поможет.
RELOGIN_STATUS_CODES = (400, 401, 403)
HTTP_UNAUTHORIZED = 401
TOKEN_EXPIRED_MARKER = "token_expired"

# Одна блокировка на процесс: перечитывание файла и обмен refresh_token идут вместе.
_refresh_lock = threading.Lock()
_last_refresh_at = 0.0


def _max_token_age_seconds() -> float:
    """Предельный возраст токена в секундах (из окружения, иначе по умолчанию)."""
    raw = os.environ.get(MAX_TOKEN_AGE_ENV, "")
    try:
        hours = float(raw) if raw else DEFAULT_MAX_TOKEN_AGE_H
    except ValueError:
        logger.warning("flatten_system: %s=%r не число, беру %s ч",
                       MAX_TOKEN_AGE_ENV, raw, DEFAULT_MAX_TOKEN_AGE_H)
        hours = DEFAULT_MAX_TOKEN_AGE_H
    return max(hours, 0.0) * SECONDS_PER_HOUR


def _token_issued_at(access_token: object) -> float | None:
    """Момент выпуска токена (`iat` из JWT) или None, если разобрать не удалось."""
    if not isinstance(access_token, str):
        return None
    try:
        payload = access_token.split(".")[1]
        claims = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
        iat = claims.get("iat")
        return float(iat) if isinstance(iat, (int, float)) else None
    except Exception:  # noqa: BLE001 - не JWT = возраст неизвестен
        return None


def _is_token_expired_error(exc: object) -> bool:
    """Это отказ ChatGPT «токен истёк» (HTTP 401 или код token_expired в тексте)?"""
    if getattr(exc, "status_code", None) == HTTP_UNAUTHORIZED:
        return True
    return TOKEN_EXPIRED_MARKER in str(exc)


def _refresh_locked(authenticator: Any, force: bool) -> None:
    """Обновляет токен, если он стар (или force). Вызывать только под _refresh_lock.

    Файл перечитывается уже под блокировкой: если токены обновил другой поток, возраст
    свежий и обмен не нужен. Ошибки не пробрасываются, чтобы запрос шёл по исходной
    логике LiteLLM (она сама напишет понятную ошибку входа).
    """
    global _last_refresh_at
    read = getattr(authenticator, AUTH_READ_METHOD)
    auth = read()
    if not isinstance(auth, dict):
        return
    refresh_token = auth.get("refresh_token")
    if not isinstance(refresh_token, str) or not refresh_token:
        return
    now = time.time()
    if force:
        if now - _last_refresh_at < FORCE_COOLDOWN_SECONDS:
            return
    else:
        issued = _token_issued_at(auth.get("access_token"))
        if issued is None or now - issued <= _max_token_age_seconds():
            return
    try:
        getattr(authenticator, AUTH_REFRESH_METHOD)(refresh_token)
    except Exception as exc:  # noqa: BLE001
        status = getattr(exc, "status_code", None)
        if status in RELOGIN_STATUS_CODES:
            logger.warning(
                "flatten_system: refresh_token отклонён (HTTP %s): нужен повторный вход по коду "
                "(install.sh --openai-adapter). %s", status, exc,
            )
        else:
            logger.warning("flatten_system: токен подписки не обновился: %s", exc)
        return
    _last_refresh_at = time.time()
    logger.info("flatten_system: токен подписки обновлён (%s)",
                "после 401" if force else "по возрасту")


def force_token_refresh() -> None:
    """Принудительное обновление после 401 (синхронно; зовите через asyncio.to_thread)."""
    try:
        module = importlib.import_module(AUTH_MODULE_PATH)
        authenticator = getattr(module, AUTH_CLASS_NAME)()
    except Exception:  # noqa: BLE001
        logger.warning("flatten_system: нет %s, обновить токен нельзя", AUTH_MODULE_PATH,
                       exc_info=True)
        return
    with _refresh_lock:
        _refresh_locked(authenticator, force=True)


def _make_patched_get_access_token(
    original: Callable[[Any], str],
) -> Callable[[Any], str]:
    """Обёртка get_access_token: сначала обновление по возрасту, затем исходная логика."""

    @functools.wraps(original)
    def patched(self: Any) -> str:
        with _refresh_lock:
            try:
                _refresh_locked(self, force=False)
            except Exception:  # noqa: BLE001 - обновление не должно ронять запрос
                logger.warning("flatten_system: сбой проверки возраста токена", exc_info=True)
        return original(self)

    setattr(patched, AUTH_MARKER, True)
    setattr(patched, AUTH_ORIGINAL_ATTR, original)
    return patched


def install_token_refresh_patch() -> bool:
    """Оборачивает Authenticator.get_access_token (идемпотентно).

    Returns:
        True, если патч установлен (или уже стоял); False, если в LiteLLM нет нужных имён.
    """
    try:
        cls = getattr(importlib.import_module(AUTH_MODULE_PATH), AUTH_CLASS_NAME, None)
    except Exception:  # noqa: BLE001
        logger.warning("flatten_system: не удалось импортировать %s, патч токена не установлен",
                       AUTH_MODULE_PATH, exc_info=True)
        return False
    method = getattr(cls, AUTH_METHOD_NAME, None) if cls is not None else None
    if (cls is None or not callable(method)
            or not callable(getattr(cls, AUTH_REFRESH_METHOD, None))
            or not callable(getattr(cls, AUTH_READ_METHOD, None))):
        logger.warning("flatten_system: нет %s.%s/%s/%s в %s, патч токена не установлен",
                       AUTH_CLASS_NAME, AUTH_METHOD_NAME, AUTH_REFRESH_METHOD,
                       AUTH_READ_METHOD, AUTH_MODULE_PATH)
        return False
    if getattr(method, AUTH_MARKER, False):
        return True
    setattr(cls, AUTH_METHOD_NAME, _make_patched_get_access_token(method))
    return True


def patch_status() -> dict[str, bool]:
    """Какие патчи стоят сейчас (живая проверка по классам LiteLLM).

    Для проверки после выкатки: python -c "import flatten_system as f; print(f.patch_status())"
    (запускать из каталога с хуком, интерпретатором из venv шлюза).

    Returns:
        Словарь «имя патча -> стоит ли он».
    """
    def installed(module_path: str, class_name: str, method_name: str, marker: str) -> bool:
        try:
            cls = getattr(importlib.import_module(module_path), class_name, None)
            return bool(getattr(getattr(cls, method_name, None), marker, False))
        except Exception:  # noqa: BLE001
            return False

    return {
        "stream_args": installed(
            STREAM_MODULE_PATH, STREAM_CLASS_NAME, STREAM_METHOD_NAME, PATCH_MARKER
        ),
        "chat_bridge": installed(
            BRIDGE_MODULE_PATH, BRIDGE_CLASS_NAME, BRIDGE_METHOD_NAME, BRIDGE_MARKER
        ),
        "token_refresh": installed(
            AUTH_MODULE_PATH, AUTH_CLASS_NAME, AUTH_METHOD_NAME, AUTH_MARKER
        ),
    }


def install_patches() -> dict[str, bool]:
    """Ставит все патчи и пишет одну итоговую строку.

    Уровень info при успехе (в журнале юнита он не виден без LITELLM_LOG), warning, если
    что-то не встало.

    Returns:
        Результат install_stream_args_patch, install_chat_bridge_patch и install_token_refresh_patch по именам.
    """
    result = {
        "stream_args": install_stream_args_patch(),
        "chat_bridge": install_chat_bridge_patch(),
        "token_refresh": install_token_refresh_patch(),
    }
    if all(result.values()):
        logger.info("flatten_system: патчи стрима установлены: %s", result)
    else:
        logger.warning("flatten_system: НЕ все патчи стрима установлены: %s", result)
    return result


install_patches()
