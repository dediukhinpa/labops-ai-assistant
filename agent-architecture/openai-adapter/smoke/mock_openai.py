"""Поддельный OpenAI Responses API (/v1/responses) для проверки цепочки Claude Code -> LiteLLM.

Только stdlib. Журнал запросов — JSONL. Сценарий выбирается ключевым словом в тексте
пользователя (один процесс мока обслуживает все сценарии, см. SCENARIOS):
  RUN_TOOL             один вызов Bash, аргументы приходят дельтами;
  PARALLEL_NODELTA     два вызова Bash БЕЗ дельт: аргументы только в arguments.done и
                       output_item.done (так отвечает настоящий бэкенд при параллельных вызовах);
  PARALLEL_INTERLEAVED то же, но оба output_item.added идут до обоих arguments.done;
  PARALLEL_DELTA       два вызова Bash с дельтами (аргументы разбиты на куски);
  MIXED                текстовое сообщение и два вызова Bash без дельт;
  LONG                 два вызова Bash без дельт, аргументы > 10 КБ (кириллица, эмодзи);
  EMPTY                вызов инструмента get_time с пустыми аргументами {} без дельт.
Если во входе есть function_call_output — мок отвечает текстом, а выходы инструментов
пишет в журнал (поле outputs). Сообщения с ролью system во входе отвергаются (400).

Запуск:   python3 mock_openai.py <порт> <файл журнала>
Справка:  python3 mock_openai.py --markers <СЦЕНАРИЙ>  — ожидаемые строки в выходах Bash.
"""
import json
import os
import re
import sys
import time
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

FINAL_TEXT = "ГОТОВО: цепочка работает"
MIN_LONG_BYTES = 12000  # длиннее 10 КБ: проверка склейки больших аргументов
MAX_OUT_LOG = 300  # сколько символов выхода инструмента писать в журнал
DELTA_PARTS = 3  # на сколько кусков бить аргументы в сценариях с дельтами
DEFAULT_TOOL = "Bash"
# MOCK_DEBUG=1: в журнал пишется поле request — что реально дошло до бэкенда.
DEBUG_PARAMS = ("reasoning", "max_output_tokens", "temperature", "top_p", "tool_choice",
                "parallel_tool_calls", "store", "include", "text", "stream")


@dataclass
class Scenario:
    """Описание сценария: что вернёт мок и что должен увидеть клиент."""

    name: str
    calls: list  # [(имя инструмента, dict аргументов, ensure_ascii)]
    deltas: bool = False  # слать ли function_call_arguments.delta
    interleaved: bool = False  # все added, затем все done
    text_first: bool = False  # перед вызовами идёт текстовое сообщение
    delta_parts: int = DELTA_PARTS
    markers: list = field(default_factory=list)  # строки, которые должны вернуться из Bash

    @property
    def expected_args(self) -> list:
        """Ожидаемые аргументы каждого вызова, по порядку."""
        return [args for _, args, _ in self.calls]

    @property
    def block_kinds(self) -> list:
        """Ожидаемые типы блоков ответа Anthropic по порядку."""
        return (["text"] if self.text_first else []) + ["tool_use"] * len(self.calls)


def bash(command: str, ascii_json: bool = True) -> tuple:
    return (DEFAULT_TOOL, {"command": command, "description": "mock"}, ascii_json)


def long_payload(unit: str) -> str:
    """Строка из повторов unit длиннее MIN_LONG_BYTES байт (без одинарных кавычек)."""
    n = MIN_LONG_BYTES // len(unit.encode()) + 1
    return unit * n


def long_call(unit: str, marker: str, ascii_json: bool) -> tuple:
    """Команда, печатающая число байт полезной нагрузки с маркером: байты ушли целыми."""
    payload = long_payload(unit)
    cmd = f"printf '%s' '{payload}' | wc -c | sed 's/^/{marker} bytes=/'"
    return bash(cmd, ascii_json), f"{marker} bytes={len(payload.encode())}"


_LONG1 = long_call("Привет, мир 🚀 ёж — тест; ", "long-one-OK", False)
_LONG2 = long_call("日本語 🎉 Ünïcödé 🇷🇺 ", "long-two-OK", True)
PAR_CALLS = [bash("echo par-one-OK"), bash("echo par-two-OK")]
PAR_MARKERS = ["par-one-OK", "par-two-OK"]

SCENARIOS = {s.name: s for s in [
    Scenario("RUN_TOOL", [bash("echo chain-ok")], deltas=True, delta_parts=1,
             markers=["chain-ok"]),
    Scenario("PARALLEL_NODELTA", PAR_CALLS, markers=PAR_MARKERS),
    Scenario("PARALLEL_INTERLEAVED", PAR_CALLS, interleaved=True, markers=PAR_MARKERS),
    Scenario("PARALLEL_DELTA", PAR_CALLS, deltas=True, markers=PAR_MARKERS),
    Scenario("MIXED", PAR_CALLS, text_first=True, markers=PAR_MARKERS),
    Scenario("LONG", [_LONG1[0], _LONG2[0]], markers=[_LONG1[1], _LONG2[1]]),
    Scenario("EMPTY", [("get_time", {}, True)]),
]}
# Порядок проверки ключевых слов: имена, содержащие другие имена, идут раньше.
KEYWORDS = sorted(SCENARIOS, key=len, reverse=True)


def pick_scenario(user_texts: list):
    """Сценарий по ключевому слову в тексте пользователя или None."""
    joined = "\n".join(user_texts)
    for name in KEYWORDS:
        if re.search(rf"\b{name}\b", joined):
            return SCENARIOS[name]
    return None


def texts(item: dict) -> str:
    c = item.get("content")
    if isinstance(c, str):
        return c
    return " ".join(p.get("text", "") for p in (c or []) if isinstance(p, dict))


def response_obj(output: list, status: str = "completed") -> dict:
    return {"id": "resp_mock", "object": "response", "created_at": int(time.time()),
            "status": status, "model": "gpt-mock", "output": output,
            "usage": {"input_tokens": 1, "output_tokens": 1, "total_tokens": 2}}


def msg_item() -> dict:
    return {"type": "message", "id": "msg_1", "status": "completed", "role": "assistant",
            "content": [{"type": "output_text", "text": FINAL_TEXT, "annotations": []}]}


def build_output(scn) -> list:
    """Элементы output ответа: итоговый текст (нет сценария) или [текст] + вызовы."""
    if scn is None:
        return [msg_item()]
    items = [msg_item()] if scn.text_first else []
    for n, (name, args, ascii_json) in enumerate(scn.calls, 1):
        items.append({"type": "function_call", "id": f"fc_{n}", "call_id": f"call_mock{n}",
                      "name": name, "arguments": json.dumps(args, ensure_ascii=ascii_json),
                      "status": "completed"})
    return items


def sse(event: str, data: dict) -> bytes:
    data["type"] = event
    return f"event: {event}\ndata: {json.dumps(data, ensure_ascii=False)}\n\n".encode()


def split_parts(s: str, n: int) -> list:
    """Делит строку на n кусков (последний может быть короче); пустую не режет."""
    size = max(1, -(-len(s) // n))
    return [s[i:i + size] for i in range(0, len(s), size)] or [""]


def message_phases(item: dict, idx: int) -> tuple:
    """Фазы (начало, тело, конец) текстового сообщения."""
    iid = item["id"]
    empty = dict(item, content=[], status="in_progress")
    part0 = {"type": "output_text", "text": "", "annotations": []}
    return (
        [sse("response.output_item.added", {"output_index": idx, "item": empty}),
         sse("response.content_part.added", {"item_id": iid, "output_index": idx,
                                             "content_index": 0, "part": part0})],
        [sse("response.output_text.delta", {"item_id": iid, "output_index": idx,
                                            "content_index": 0, "delta": FINAL_TEXT}),
         sse("response.output_text.done", {"item_id": iid, "output_index": idx,
                                           "content_index": 0, "text": FINAL_TEXT}),
         sse("response.content_part.done", {"item_id": iid, "output_index": idx,
                                            "content_index": 0, "part": item["content"][0]})],
        [sse("response.output_item.done", {"output_index": idx, "item": item})])


def call_phases(item: dict, idx: int, scn) -> tuple:
    """Фазы вызова функции. Без дельт тело — только arguments.done (как у бэкенда)."""
    iid = item["id"]
    start = [sse("response.output_item.added",
                 {"output_index": idx, "item": dict(item, arguments="", status="in_progress")})]
    body = []
    if scn.deltas:
        body += [sse("response.function_call_arguments.delta",
                     {"item_id": iid, "output_index": idx, "delta": part})
                 for part in split_parts(item["arguments"], scn.delta_parts)]
    body.append(sse("response.function_call_arguments.done",
                    {"item_id": iid, "output_index": idx, "arguments": item["arguments"]}))
    return start, body, [sse("response.output_item.done", {"output_index": idx, "item": item})]


def stream_events(scn) -> list:
    output = build_output(scn)
    base = response_obj([], "in_progress")
    ev = [sse("response.created", {"response": base}),
          sse("response.in_progress", {"response": base})]
    phases = [message_phases(it, i) if it["type"] == "message" else call_phases(it, i, scn)
              for i, it in enumerate(output)]
    if scn is not None and scn.interleaved:
        for k in range(3):  # все начала, потом все тела, потом все концы
            for ph in phases:
                ev += ph[k]
    else:
        for ph in phases:
            ev += ph[0] + ph[1] + ph[2]
    ev.append(sse("response.completed", {"response": response_obj(output)}))
    return ev


def output_text(item: dict) -> str:
    out = item.get("output")
    if isinstance(out, str):
        return out
    return json.dumps(out, ensure_ascii=False)


def debug_request(req: dict) -> dict:
    """Полный набор ключей запроса, значения важных параметров и вид tools."""
    return {"keys": sorted(req),
            "params": {k: req[k] for k in DEBUG_PARAMS if k in req},
            "tools": [t if t.get("type") != "function"
                      else {"type": "function", "name": t.get("name")}
                      for t in req.get("tools") or []]}


class Handler(BaseHTTPRequestHandler):
    log_path = ""

    def log_message(self, *a):
        pass

    def do_POST(self):
        req = json.loads(self.rfile.read(int(self.headers.get("content-length", 0))) or b"{}")
        items = req.get("input") if isinstance(req.get("input"), list) else []
        if any(i.get("role") == "system" for i in items):
            # Как настоящий бэкенд подписки: system во входе недопустим (нужен instructions).
            body = b'{"detail":"System messages are not allowed"}'
            self.send_response(400)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        user_texts = [texts(i) for i in items if i.get("role") == "user"]
        results = [i for i in items if i.get("type") == "function_call_output"]
        scn = pick_scenario(user_texts)
        tool_names = [t.get("name") for t in req.get("tools") or []]
        want_tool = scn is not None and not results \
            and all(name in tool_names for name, _, _ in scn.calls)
        with open(self.log_path, "a", encoding="utf-8") as f:
            f.write(json.dumps({"path": self.path,
                                "auth": self.headers.get("authorization", "")[:11],
                                "model": req.get("model"), "stream": req.get("stream"),
                                "scenario": scn.name if scn else None,
                                "n_tools": len(tool_names), "tool_names": tool_names[:6],
                                "input_types": [i.get("type") or i.get("role") for i in items],
                                "has_instructions": bool(req.get("instructions")),
                                "outputs": [output_text(r)[:MAX_OUT_LOG] for r in results],
                                **({"request": debug_request(req)}
                                   if os.environ.get("MOCK_DEBUG") else {})},
                               ensure_ascii=False) + "\n")
        use = scn if want_tool else None
        if req.get("stream"):
            self.send_response(200)
            self.send_header("content-type", "text/event-stream")
            self.end_headers()
            for e in stream_events(use):
                self.wfile.write(e)
                self.wfile.flush()
        else:
            body = json.dumps(response_obj(build_output(use))).encode()
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"{}")


def main() -> None:
    if sys.argv[1] == "--markers":
        print("\n".join(SCENARIOS[sys.argv[2]].markers))
        return
    Handler.log_path = sys.argv[2]
    ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()


if __name__ == "__main__":
    main()
