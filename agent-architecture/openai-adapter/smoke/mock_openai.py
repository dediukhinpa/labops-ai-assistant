"""Поддельный OpenAI Responses API (/v1/responses) для проверки цепочки Claude Code -> LiteLLM.

Только stdlib. Журнал запросов — JSONL. Логика: есть function_call_output в input — отвечает
текстом; в сообщениях пользователя есть RUN_TOOL и есть tools — просит вызвать Bash;
иначе отвечает текстом.
Сообщения с ролью system во входе отвергаются (400), как в бэкенде подписки.
"""
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT, LOG = int(sys.argv[1]), sys.argv[2]
FINAL_TEXT = "ГОТОВО: цепочка работает"
TOOL_ARGS = {"command": "echo chain-ok", "description": "mock"}


def texts(item: dict) -> str:
    c = item.get("content")
    if isinstance(c, str):
        return c
    return " ".join(p.get("text", "") for p in (c or []) if isinstance(p, dict))


def response_obj(output: list, status: str = "completed") -> dict:
    return {"id": "resp_mock", "object": "response", "created_at": int(time.time()),
            "status": status, "model": "gpt-mock", "output": output,
            "usage": {"input_tokens": 1, "output_tokens": 1, "total_tokens": 2}}


MSG_ITEM = {"type": "message", "id": "msg_1", "status": "completed", "role": "assistant",
            "content": [{"type": "output_text", "text": FINAL_TEXT, "annotations": []}]}
FC_ITEM = {"type": "function_call", "id": "fc_1", "call_id": "call_mock1", "name": "Bash",
           "arguments": json.dumps(TOOL_ARGS), "status": "completed"}


def sse(event: str, data: dict) -> bytes:
    data["type"] = event
    return f"event: {event}\ndata: {json.dumps(data, ensure_ascii=False)}\n\n".encode()


def stream_events(item: dict) -> list:
    base = response_obj([], "in_progress")
    ev = [sse("response.created", {"response": base}), sse("response.in_progress", {"response": base})]
    if item["type"] == "message":
        empty = dict(item, content=[], status="in_progress")
        part0 = {"type": "output_text", "text": "", "annotations": []}
        ev += [sse("response.output_item.added", {"output_index": 0, "item": empty}),
               sse("response.content_part.added", {"item_id": "msg_1", "output_index": 0,
                                                   "content_index": 0, "part": part0}),
               sse("response.output_text.delta", {"item_id": "msg_1", "output_index": 0,
                                                  "content_index": 0, "delta": FINAL_TEXT}),
               sse("response.output_text.done", {"item_id": "msg_1", "output_index": 0,
                                                 "content_index": 0, "text": FINAL_TEXT}),
               sse("response.content_part.done", {"item_id": "msg_1", "output_index": 0,
                                                  "content_index": 0, "part": item["content"][0]}),
               sse("response.output_item.done", {"output_index": 0, "item": item})]
    else:
        empty = dict(item, arguments="", status="in_progress")
        ev += [sse("response.output_item.added", {"output_index": 0, "item": empty}),
               sse("response.function_call_arguments.delta", {"item_id": "fc_1", "output_index": 0,
                                                              "delta": item["arguments"]}),
               sse("response.function_call_arguments.done", {"item_id": "fc_1", "output_index": 0,
                                                             "arguments": item["arguments"]}),
               sse("response.output_item.done", {"output_index": 0, "item": item})]
    ev.append(sse("response.completed", {"response": response_obj([item])}))
    return ev


class Handler(BaseHTTPRequestHandler):
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
        has_result = any(i.get("type") == "function_call_output" for i in items)
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(json.dumps({"path": self.path, "auth": self.headers.get("authorization", "")[:11],
                                "model": req.get("model"), "stream": req.get("stream"),
                                "n_tools": len(req.get("tools") or []),
                                "tool_names": [t.get("name") for t in req.get("tools") or []][:6],
                                "input_types": [i.get("type") or i.get("role") for i in items],
                                "has_instructions": bool(req.get("instructions"))},
                               ensure_ascii=False) + "\n")
        want_tool = any("RUN_TOOL" in t for t in user_texts) and not has_result \
            and any(t.get("name") == "Bash" for t in req.get("tools") or [])
        item = FC_ITEM if want_tool else MSG_ITEM
        if req.get("stream"):
            self.send_response(200)
            self.send_header("content-type", "text/event-stream")
            self.end_headers()
            for e in stream_events(item):
                self.wfile.write(e)
                self.wfile.flush()
        else:
            body = json.dumps(response_obj([item])).encode()
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"{}")


ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
