#!/usr/bin/env python3
"""Поиск в интернете через подписку ChatGPT (шлюз LiteLLM на этом хосте).

Встроенный WebSearch Claude Code через шлюз не работает: серверный инструмент поиска
отбрасывается. Здесь тот же поиск делает сама модель OpenAI (инструмент web_search
Responses API), а скрипт возвращает ответ и список источников.

Запросы идут в шлюз напрямую (127.0.0.1), в обход маскирования данных: в запрос нельзя
включать персональные данные.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path

DEFAULT_PORT = 4000
REQUEST_TIMEOUT_SEC = 150
# Файл с ключом и портом шлюза пишет установщик адаптера (права 600, владелец - агент).
SECRETS_REL = Path(".claude-lab/shared/secrets/openai-adapter.env")
SYSTEM_PROMPT = (
    "Ты помощник по поиску. Найди актуальную информацию в интернете и ответь по существу, "
    "кратко и без выдумок. Если надёжных данных нет, так и скажи. Отвечай на языке запроса."
)


@dataclass
class SearchResult:
    """Итог поиска: текст ответа, источники и запросы, которые выполнила модель."""

    text: str = ""
    sources: list[tuple[str, str]] = field(default_factory=list)
    queries: list[str] = field(default_factory=list)
    error: str = ""


def read_env_file(path: Path) -> dict[str, str]:
    """Читает файл вида KEY=VALUE (кавычки и пробелы по краям убираются)."""
    values: dict[str, str] = {}
    if not path.is_file():
        return values
    for line in path.read_text(encoding="utf-8").splitlines():
        if "=" not in line or line.lstrip().startswith("#"):
            continue
        key, _, value = line.partition("=")
        values[key.strip()] = value.strip().strip("'\"")
    return values


def parse_sse(lines: list[str]) -> SearchResult:
    """Разбирает поток событий Responses API в ответ, источники и запросы."""
    result = SearchResult()
    seen_urls: set[str] = set()
    for raw in lines:
        if not raw.startswith("data:"):
            continue
        try:
            event = json.loads(raw[5:])
        except json.JSONDecodeError:
            continue
        kind = event.get("type", "")
        if kind == "response.output_text.delta":
            result.text += event.get("delta", "")
        elif kind == "response.output_item.done":
            item = event.get("item", {})
            if item.get("type") == "web_search_call":
                query = (item.get("action") or {}).get("query")
                if query:
                    result.queries.append(query)
            elif item.get("type") == "message":
                for part in item.get("content", []):
                    for note in part.get("annotations", []):
                        url = note.get("url", "")
                        if url and url not in seen_urls:
                            seen_urls.add(url)
                            result.sources.append((note.get("title", "") or url, url))
        elif kind in ("error", "response.failed"):
            detail = event.get("error") or (event.get("response") or {}).get("error") or event
            result.error = json.dumps(detail, ensure_ascii=False)[:300]
    return result


def gateway_model(base: str, key: str) -> str:
    """Имя модели берём у самого шлюза: так навык не отстаёт при смене модели."""
    request = urllib.request.Request(f"{base}/v1/models", headers={"Authorization": f"Bearer {key}"})
    with urllib.request.urlopen(request, timeout=20) as response:  # noqa: S310 - loopback
        data = json.load(response).get("data", [])
    if not data:
        raise RuntimeError("шлюз не вернул ни одной модели")
    return str(data[0]["id"])


def search(query: str, base: str, key: str, model: str) -> SearchResult:
    """Выполняет один поиск и возвращает разобранный результат."""
    body = {
        "model": model,
        "stream": True,
        "instructions": SYSTEM_PROMPT,
        "input": [{"role": "user", "content": [{"type": "input_text", "text": query}]}],
        "tools": [{"type": "web_search"}],
    }
    request = urllib.request.Request(
        f"{base}/v1/responses",
        data=json.dumps(body).encode("utf-8"),
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=REQUEST_TIMEOUT_SEC) as response:  # noqa: S310
        lines = response.read().decode("utf-8", errors="replace").splitlines()
    return parse_sse(lines)


def format_result(result: SearchResult) -> str:
    """Человекочитаемый вывод: ответ, затем источники."""
    parts = [result.text.strip() or "(пустой ответ)"]
    if result.sources:
        parts.append("\nИсточники:")
        parts.extend(f"- {title}: {url}" for title, url in result.sources)
    return "\n".join(parts)


def main(argv: list[str] | None = None) -> int:
    """Точка входа: python3 search.py "запрос"."""
    parser = argparse.ArgumentParser(description="Поиск в интернете через шлюз OpenAI")
    parser.add_argument("query", help="поисковый запрос без персональных данных")
    args = parser.parse_args(argv)
    env = read_env_file(Path.home() / SECRETS_REL)
    key = env.get("ANTHROPIC_AUTH_TOKEN", "")
    if not key:
        print("нет ключа шлюза в ~/.claude-lab/shared/secrets/openai-adapter.env", file=sys.stderr)
        return 2
    port = int(env.get("LABOPS_LLM_PORT", os.environ.get("LABOPS_LLM_PORT", DEFAULT_PORT)))
    base = f"http://127.0.0.1:{port}"
    try:
        result = search(args.query, base, key, gateway_model(base, key))
    except (urllib.error.URLError, RuntimeError, TimeoutError) as err:
        print(f"поиск не выполнен: {err}", file=sys.stderr)
        return 1
    if result.error:
        print(f"поиск не выполнен: {result.error}", file=sys.stderr)
        return 1
    print(format_result(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
