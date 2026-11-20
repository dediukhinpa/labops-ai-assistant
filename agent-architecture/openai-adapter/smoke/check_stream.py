"""Проверка потока /v1/messages (SSE) шлюза LiteLLM на уровне протокола, без Claude Code.

Шлёт stream=true напрямую в шлюз для каждого сценария мока (mock_openai.SCENARIOS) и
проверяет: склейка partial_json каждого tool_use равна ожидаемым аргументам (без дубля и без
потерь), индексы блоков 0..N-1 подряд, у блока один start и один stop, дельты лежат между
ними, stop_reason == tool_use (или end_turn для сценария без вызовов).

Запуск: python3 check_stream.py <url шлюза> <ключ> [СЦЕНАРИЙ ...]
Код выхода: 0 — все сценарии прошли, 1 — хоть один упал.
"""
import json
import os
import sys
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import mock_openai  # noqa: E402  (сценарии берём из мока: единый источник ожидаемых аргументов)

MODEL = os.environ.get("SMOKE_MODEL", "gpt-smoke")
HTTP_TIMEOUT = 60
MAX_TOKENS = 1024
TOOLS = [
    {"name": "Bash", "description": "Run a shell command",
     "input_schema": {"type": "object", "required": ["command"],
                      "properties": {"command": {"type": "string"},
                                     "description": {"type": "string"}}}},
    {"name": "get_time", "description": "Current time, no arguments",
     "input_schema": {"type": "object", "properties": {}}},
]


def fetch_events(base_url: str, key: str, prompt: str) -> list:
    """POST /v1/messages со stream=true; возвращает список разобранных SSE-событий."""
    body = json.dumps({"model": MODEL, "max_tokens": MAX_TOKENS, "stream": True, "tools": TOOLS,
                       "messages": [{"role": "user", "content": prompt}]}).encode()
    req = urllib.request.Request(
        f"{base_url}/v1/messages", data=body, method="POST",
        headers={"content-type": "application/json", "x-api-key": key,
                 "authorization": f"Bearer {key}", "anthropic-version": "2023-06-01"})
    with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
        raw = resp.read().decode("utf-8")
    events = []
    for frame in raw.split("\n\n"):
        data = [ln[5:].strip() for ln in frame.splitlines() if ln.startswith("data:")]
        if data:
            events.append(json.loads("\n".join(data)))
    return events


def analyze(events: list, scn) -> list:
    """Возвращает список найденных проблем (пустой — поток корректен)."""
    errors = []
    types = [e.get("type") for e in events]
    if "error" in types:
        return [f"в потоке событие error: {events[types.index('error')]}"]
    if not types or types[0] != "message_start" or types[-1] != "message_stop":
        errors.append(f"поток не от message_start до message_stop: {types[:2]}..{types[-2:]}")
    blocks = {}  # индекс -> {starts, stops, deltas, json, block}
    open_now = set()
    for e in events:
        t, i = e.get("type"), e.get("index")
        if t == "content_block_start":
            b = blocks.setdefault(i, {"starts": 0, "stops": 0, "deltas": 0, "json": "",
                                      "block": None})
            b["starts"] += 1
            b["block"] = e.get("content_block") or {}
            open_now.add(i)
        elif t == "content_block_delta":
            b = blocks.get(i)
            if b is None or i not in open_now:
                errors.append(f"дельта блока {i} вне start..stop")
                continue
            d = e.get("delta") or {}
            if d.get("type") == "input_json_delta":
                b["deltas"] += 1
                b["json"] += d.get("partial_json", "")
        elif t == "content_block_stop":
            b = blocks.get(i)
            if b is None or i not in open_now:
                errors.append(f"stop блока {i} без открытого start")
                continue
            b["stops"] += 1
            open_now.discard(i)
    if sorted(blocks) != list(range(len(blocks))):
        errors.append(f"индексы блоков не 0..N-1 подряд: {sorted(blocks)}")
    for i, b in sorted(blocks.items()):
        if b["starts"] != 1 or b["stops"] != 1:
            errors.append(f"блок {i}: start={b['starts']} stop={b['stops']} (нужно по одному)")
    if open_now:
        errors.append(f"не закрыты блоки: {sorted(open_now)}")
    kinds = [blocks[i]["block"].get("type") for i in sorted(blocks) if blocks[i]["block"]]
    if kinds != scn.block_kinds:
        errors.append(f"типы блоков {kinds}, ожидались {scn.block_kinds}")
    tool_blocks = [blocks[i] for i in sorted(blocks)
                   if blocks[i]["block"].get("type") == "tool_use"]
    for n, (b, (name, args, _)) in enumerate(zip(tool_blocks, scn.calls)):
        errors += check_tool(n, b, name, args, scn)
    stop = next((e["delta"].get("stop_reason") for e in events
                 if e.get("type") == "message_delta"), None)
    want_stop = "tool_use" if scn.calls else "end_turn"
    if stop != want_stop:
        errors.append(f"stop_reason={stop!r}, ожидался {want_stop!r}")
    return errors


def check_tool(n: int, b: dict, name: str, args: dict, scn) -> list:
    """Проверка одного tool_use: имя, id, склейка аргументов, отсутствие дубля."""
    errors = []
    if b["block"].get("name") != name:
        errors.append(f"вызов {n}: имя {b['block'].get('name')!r}, ожидалось {name!r}")
    if b["block"].get("id") != f"call_mock{n + 1}":
        errors.append(f"вызов {n}: id {b['block'].get('id')!r}")
    joined = b["json"]
    if not args:
        if b["deltas"] > 1:
            errors.append(f"вызов {n} (пустые аргументы): input_json_delta {b['deltas']} шт.")
        joined = joined or "{}"  # нет дельт — input из content_block_start ({})
    try:
        got = json.loads(joined)
    except ValueError as exc:
        return errors + [f"вызов {n}: склейка partial_json не JSON ({exc}): {joined[:120]!r}"]
    if got != args:
        errors.append(f"вызов {n}: аргументы {str(got)[:120]!r} != ожидаемых {str(args)[:120]!r}"
                      f" (длина склейки {len(joined)})")
    elif args and b["deltas"] == 0:
        errors.append(f"вызов {n}: нет input_json_delta, аргументы не дошли дельтой")
    return errors


def main() -> int:
    base_url, key = sys.argv[1].rstrip("/"), sys.argv[2]
    names = sys.argv[3:] or list(mock_openai.SCENARIOS)
    failed = 0
    for name in names:
        scn = mock_openai.SCENARIOS[name]
        try:
            errors = analyze(fetch_events(base_url, key, f"{name} go"), scn)
        except Exception as exc:  # noqa: BLE001  (любой сбой запроса — провал сценария)
            errors = [f"запрос не удался: {exc!r}"]
        if errors:
            failed += 1
            print(f"FAIL: поток {name}: " + "; ".join(errors))
        else:
            print(f"OK: поток {name}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
