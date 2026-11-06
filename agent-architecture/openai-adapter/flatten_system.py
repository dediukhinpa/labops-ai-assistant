"""Хук LiteLLM: system-промпт Claude Code (список блоков) превращается в строку.

Бэкенд подписки ChatGPT отвечает «System messages are not allowed», если LiteLLM кладёт
system-блоки во вход Responses API как сообщения. Строка уходит в `instructions`, и
запрос проходит.
"""
from typing import Any

from litellm.integrations.custom_logger import CustomLogger


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


flatten_system = FlattenSystem()
