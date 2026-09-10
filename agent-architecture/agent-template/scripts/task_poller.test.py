"""Тесты долгоживущего поллера задач.

Порт прежнего task-poller.test.sh на python: логика опроса переехала из bash,
но проверять надо ровно то же самое, включая случаи, которые уже стоили нам
простоя, -- «призрак» в поле ввода, потерю токена и молчаливое переполнение
окна выдачи.

Запуск: python3 agent-template/scripts/task_poller.test.py
"""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

from task_poller import (  # noqa: E402
    TASK_NEEDLE,
    TmuxPane,
    BearerCache,
    RouterClient,
    SessionLost,
    TaskPoller,
)

ITEMS: list[dict[str, Any]] = [
    {
        "path": "decisions/2026-07-20-task-carmella-alpha.md",
        "snippet": "TASK-FOR: carmella\nSTATUS: open\n\nbuild X",
    },
    {
        "path": "decisions/2026-07-20-plain-note.md",
        "snippet": "just a regular decision about something",
    },
    {
        "path": "decisions/2026-07-20-task-silvio-beta.md",
        "snippet": "TASK-FOR: silvio\nSTATUS: open\n\ndo Y",
    },
    {
        "path": "decisions/2026-07-20-task-carmella-done.md",
        "snippet": "TASK-FOR: carmella\nSTATUS: done\n\nbuild X",
    },
]


class _FakePane:
    """Заглушка tmux: состояние задаётся полями, ввод копится в списке."""

    def __init__(self, idle: bool = True, alive: bool = True) -> None:
        self.idle = idle
        self.alive = alive
        self.sent: list[str] = []
        self.send_ok = True
        self.idle_calls = 0

    def has_session(self) -> bool:
        return self.alive

    def clean_idle(self) -> bool:
        self.idle_calls += 1
        return self.idle

    def send_line(self, text: str) -> bool:
        if not self.send_ok:
            return False
        self.sent.append(text)
        return True


class _FakeClient:
    """Заглушка memory_router: считает запросы, умеет падать по требованию."""

    def __init__(self, items: list[dict[str, Any]] | None = None) -> None:
        self.items = ITEMS if items is None else items
        self.calls = 0
        self.raise_with: Exception | None = None
        self.invalidated = 0
        self.closed = 0

    def recent_items(self) -> list[dict[str, Any]]:
        self.calls += 1
        if self.raise_with is not None:
            raise self.raise_with
        return self.items

    def invalidate(self) -> None:
        self.invalidated += 1

    def close(self) -> None:
        self.closed += 1


class _FakeBoard:
    """Доска, отдающая заданный список задач или падающая заданной ошибкой."""

    def __init__(self, reply: Any) -> None:
        self._reply = reply
        self.invalidated = 0

    def board_tasks(self, _agent: str) -> list[dict[str, Any]]:
        if isinstance(self._reply, Exception):
            raise self._reply
        return self._reply

    def invalidate(self) -> None:
        self.invalidated += 1


class PollerTest(unittest.TestCase):
    """Отбор задач, доставка, дедупликация и поведение при сбоях."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.ws = Path(self._tmp.name)
        self.seen = self.ws / ".task-seen"
        self.seen.touch()
        self.logs: list[str] = []
        self.pane = _FakePane()
        self.client = _FakeClient()
        self.slept: list[float] = []

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _poller(self, agent: str = "carmella", board: Any = None) -> TaskPoller:
        # sleep-заглушка: без неё тест сетевого сбоя честно спал бы
        # BACKOFF_SEC и растягивал прогон на секунды.
        return TaskPoller(
            agent, self.pane, self.client, self.seen, self.logs.append,
            sleep=self.slept.append, board=board,
        )

    def test_board_task_is_delivered_by_id(self) -> None:
        """Задача с доски доставляется по номеру, а не по пути заметки."""
        board = _FakeBoard([{"id": 7, "title": "почини парсер"}])
        poller = self._poller("nova", board=board)
        poller.poll_once()
        self.assertIn("#7", self.pane.sent[-1])
        self.assertIn("task_claim", self.pane.sent[-1])
        # Машина состояний запрещает progress -> done: инструкция обязана
        # вести через review, иначе агент упрётся в invalid transition.
        self.assertIn("task_review", self.pane.sent[-1])
        self.assertIn("task:7", self.seen.read_text())

    def test_board_task_is_not_delivered_twice(self) -> None:
        """Между доставкой и task_claim задача ещё «new» — второй вброс не нужен."""
        board = _FakeBoard([{"id": 7, "title": "почини парсер"}])
        poller = self._poller("nova", board=board)
        poller.poll_once()
        poller.poll_once()
        self.assertEqual(len([s for s in self.pane.sent if "#7" in s]), 1)

    def test_board_failure_does_not_break_the_note_path(self) -> None:
        """Доска легла — задачи из заметок обязаны доставляться дальше.

        Два канала живут вместе весь переходный период, и падение нового не
        должно уносить с собой работающий старый.
        """
        board = _FakeBoard(OSError("connection refused"))
        poller = self._poller("carmella", board=board)
        poller.poll_once()
        self.assertTrue(any("task-carmella-alpha" in s for s in self.pane.sent))
        self.assertTrue(any("опрос доски не удался" in m for m in self.logs))

    def test_board_task_without_id_is_skipped(self) -> None:
        """Кривая запись с доски не должна ронять долгоживущий процесс."""
        board = _FakeBoard([{"title": "без номера"}, {"id": 9, "title": "ок"}])
        poller = self._poller("nova", board=board)
        poller.poll_once()
        self.assertEqual(len([s for s in self.pane.sent if s.startswith("📥")]), 1)
        self.assertIn("#9", self.pane.sent[-1])

    def test_superseded_task_is_not_delivered(self) -> None:
        """Закрытая задача не должна доставляться повторно.

        Закрытие пишет НОВУЮ заметку, а оригинал навсегда остаётся
        `STATUS: open`. Раньше от повторной доставки спасал только локальный
        `.task-seen`: потеря воркспейса = все закрытые задачи прилетают заново.
        """
        items = [
            {"path": "decisions/task-a.md", "snippet": "TASK-FOR: nova\nSTATUS: open"},
            {
                "path": "decisions/task-a-closed.md",
                "snippet": (
                    "# task-a принято (закрыто)\n\n"
                    "Supersedes [[decisions/task-a.md]]\n\n"
                    "TASK-FOR: nova\nSTATUS: done"
                ),
            },
            {"path": "decisions/task-b.md", "snippet": "TASK-FOR: nova\nSTATUS: open"},
        ]
        poller = self._poller("nova")
        self.assertEqual(poller.open_tasks(items), ["decisions/task-b.md"])

    def test_supersede_link_is_matched_case_insensitively(self) -> None:
        """Заметки пишут агенты: регистр слова и пробелы у ссылки не гарантированы."""
        items = [
            {"path": "decisions/task-a.md", "snippet": "TASK-FOR: nova\nSTATUS: open"},
            {
                "path": "decisions/x.md",
                "snippet": "TASK-FOR: nova\nSTATUS: done\nSUPERSEDES  [[decisions/task-a.md]]",
            },
        ]
        self.assertEqual(self._poller("nova").open_tasks(items), [])

    def test_unrelated_supersede_does_not_hide_a_task(self) -> None:
        """Закрытие ЧУЖОЙ задачи не должно прятать мою."""
        items = [
            {"path": "decisions/task-a.md", "snippet": "TASK-FOR: nova\nSTATUS: open"},
            {
                "path": "decisions/y.md",
                "snippet": "TASK-FOR: nova\nSTATUS: done\nSupersedes [[decisions/other.md]]",
            },
        ]
        self.assertEqual(self._poller("nova").open_tasks(items), ["decisions/task-a.md"])

    def test_keeps_only_open_tasks_for_this_agent(self) -> None:
        """Чужая задача, обычная заметка и уже закрытая — не наши."""
        found = self._poller().open_tasks(ITEMS)
        self.assertEqual(found, ["decisions/2026-07-20-task-carmella-alpha.md"])

    def test_matching_tolerates_spacing(self) -> None:
        """Заголовок без пробела после двоеточия обязан распознаваться.

        Серверный фильтр по этой причине обрывает иглу на двоеточии: ILIKE к
        пробелам не терпим, а заметки пишут люди и агенты.
        """
        items = [{"path": "p.md", "snippet": "TASK-FOR:carmella\nSTATUS:  open"}]
        self.assertEqual(self._poller().open_tasks(items), ["p.md"])

    def test_delivers_once_and_records_seen(self) -> None:
        poller = self._poller()
        poller.poll_once()
        self.assertEqual(len(self.pane.sent), 1)
        self.assertIn("task-carmella-alpha", self.pane.sent[0])
        self.assertIn(
            "decisions/2026-07-20-task-carmella-alpha.md",
            self.seen.read_text(encoding="utf-8"),
        )

    def test_second_poll_delivers_nothing(self) -> None:
        """Дедупликация переживает и повтор в рамках одного процесса."""
        poller = self._poller()
        poller.poll_once()
        poller.poll_once()
        self.assertEqual(len(self.pane.sent), 1)

    def test_busy_session_makes_no_network_call(self) -> None:
        """Занятая сессия — главный источник экономии: сеть не трогаем."""
        self.pane.idle = False
        self._poller().poll_once()
        self.assertEqual(self.client.calls, 0)
        self.assertEqual(self.pane.sent, [])
        self.assertEqual(self.seen.read_text(encoding="utf-8"), "")

    def test_session_busy_after_fetch_defers_delivery(self) -> None:
        """Сессия могла занять себя, пока мы ходили в сеть."""

        class _BusyAfterFetch(_FakePane):
            def clean_idle(self) -> bool:
                self.idle_calls += 1
                return self.idle_calls == 1

        self.pane = _BusyAfterFetch()
        poller = self._poller()
        poller.poll_once()
        self.assertEqual(self.pane.sent, [])
        self.assertEqual(self.seen.read_text(encoding="utf-8"), "")

    def test_failed_send_is_not_marked_seen(self) -> None:
        """Неудачная доставка обязана повториться на следующем цикле."""
        self.pane.send_ok = False
        self._poller().poll_once()
        self.assertEqual(self.seen.read_text(encoding="utf-8"), "")
        self.assertTrue(any("deliver failed" in m for m in self.logs))

    def test_lost_session_invalidates_and_survives(self) -> None:
        """Рестарт сервера не должен ронять поллер: рукопожатие заново."""
        self.client.raise_with = SessionLost("HTTP 404")
        self._poller().poll_once()
        self.assertEqual(self.client.invalidated, 1)
        self.assertTrue(any("сессия MCP потеряна" in m for m in self.logs))

    def test_network_error_is_survivable(self) -> None:
        """Недоступный сервер — не повод завершать долгоживущий процесс."""
        self.client.raise_with = OSError("connection refused")
        self._poller().poll_once()
        self.assertEqual(self.pane.sent, [])
        self.assertTrue(any("опрос не удался" in m for m in self.logs))

    def test_run_exits_when_session_gone(self) -> None:
        """Исчезнувшая сессия завершает поллер кодом 0 — и закрывает MCP."""
        self.pane.alive = False
        poller = TaskPoller(
            "carmella", self.pane, self.client, self.seen, self.logs.append,
            interval=0.0, gone_limit=2, sleep=self.slept.append,
        )
        self.assertEqual(poller.run(), 0)
        self.assertEqual(self.client.closed, 1)
        self.assertTrue(any("session gone" in m for m in self.logs))


class BearerCacheTest(unittest.TestCase):
    """Чтение и кэширование токена агента."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.path = Path(self._tmp.name) / ".mcp.json"

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _write(self, token: str, pretty: bool = True) -> None:
        cfg = {
            "mcpServers": {
                "second_brain-memory": {
                    "headers": {"Authorization": "Bearer wrong-one"}
                },
                "second_brain-memory_router": {
                    "type": "http",
                    "url": "http://127.0.0.1:5002/mcp",
                    "headers": {"Authorization": f"Bearer {token}"},
                },
            }
        }
        self.path.write_text(
            json.dumps(cfg, indent=2 if pretty else None), encoding="utf-8"
        )

    def test_reads_router_token_from_pretty_json(self) -> None:
        """Регрессия: разбор грепом ломался на pretty-print и терял токен."""
        self._write("router-token-42")
        self.assertEqual(BearerCache(self.path).get(), "router-token-42")

    def test_reads_router_token_from_one_line_json(self) -> None:
        self._write("oneline-token", pretty=False)
        self.assertEqual(BearerCache(self.path).get(), "oneline-token")

    def test_env_token_wins_and_skips_the_file(self) -> None:
        cache = BearerCache(self.path, env_token="from-env")
        self.assertEqual(cache.get(), "from-env")

    def test_missing_file_yields_empty(self) -> None:
        self.assertEqual(BearerCache(self.path).get(), "")

    def test_file_is_parsed_once_until_touched(self) -> None:
        """Разбор стоил пятую часть цикла ради неизменного значения."""
        self._write("t1")
        cache = BearerCache(self.path)
        parses = []
        original = cache._parse

        def counting_parse() -> str:
            parses.append(1)
            return original()

        cache._parse = counting_parse  # type: ignore[method-assign]
        cache.get()
        cache.get()
        cache.get()
        self.assertEqual(len(parses), 1)

        # Файл тронули — кэш обязан протухнуть, иначе смена токена не дойдёт.
        self._write("t2")
        import os

        stat = self.path.stat()
        os.utime(self.path, (stat.st_atime + 10, stat.st_mtime + 10))
        self.assertEqual(cache.get(), "t2")
        self.assertEqual(len(parses), 2)


class RouterClientTest(unittest.TestCase):
    """Разбор ответов и поведение при старом сервере."""

    def test_decodes_sse_frame(self) -> None:
        """memory_router отвечает кадрами SSE, а не голым JSON."""
        payload = 'event: message\ndata: {"jsonrpc":"2.0","id":2,"result":{"ok":1}}'
        self.assertEqual(
            RouterClient._decode(payload),
            {"jsonrpc": "2.0", "id": 2, "result": {"ok": 1}},
        )

    def test_decodes_plain_json(self) -> None:
        self.assertEqual(RouterClient._decode('{"a":1}'), {"a": 1})

    def test_decode_survives_garbage(self) -> None:
        """Мусор в ответе не должен ронять долгоживущий процесс."""
        self.assertEqual(RouterClient._decode("<html>502</html>"), {})

    def test_extracts_items_from_tool_result(self) -> None:
        items = [{"path": "a.md", "snippet": "x"}]
        resp = {"result": {"content": [{"type": "text", "text": json.dumps(items)}]}}
        self.assertEqual(RouterClient._extract_items(resp), items)

    def test_extract_items_tolerates_error_response(self) -> None:
        self.assertEqual(RouterClient._extract_items({"error": {"code": -32602}}), [])

    def test_falls_back_when_server_rejects_the_filter(self) -> None:
        """Сервер старее правки не должен оставлять агента без доставки."""
        sent: list[dict[str, Any]] = []
        client = RouterClient("http://127.0.0.1:5002/mcp", lambda: "t")
        client._session_id = "sid"

        def fake_rpc(payload: dict[str, Any]) -> dict[str, Any]:
            sent.append(payload)
            args = payload["params"]["arguments"]
            if "body_contains" in args:
                return {"error": {"code": -32602, "message": "unexpected keyword"}}
            items = [{"path": "a.md", "snippet": "TASK-FOR: nova\nSTATUS: open"}]
            return {"result": {"content": [{"text": json.dumps(items)}]}}

        client._rpc = fake_rpc  # type: ignore[method-assign]
        first = client.recent_items()
        self.assertEqual(len(first), 1)
        self.assertIn("body_contains", sent[0]["params"]["arguments"])
        self.assertNotIn("body_contains", sent[1]["params"]["arguments"])

        # Второй заход уже не должен пробовать фильтр повторно.
        sent.clear()
        client.recent_items()
        self.assertEqual(len(sent), 1)
        self.assertNotIn("body_contains", sent[0]["params"]["arguments"])

    def test_filter_needle_stops_at_the_colon(self) -> None:
        """Игла с именем агента молча теряла бы заметки без пробела."""
        self.assertEqual(TASK_NEEDLE, "TASK-FOR:")

    def _client_with_conns(self, fails: list[bool]) -> tuple[RouterClient, list[str]]:
        """Клиент, чьи соединения падают по заданному списку (одно на попытку)."""
        events: list[str] = []
        client = RouterClient("http://127.0.0.1:5002/mcp", lambda: "t")

        class _Conn:
            def __init__(self, fail: bool) -> None:
                self._fail = fail

            def request(self, *_a: Any, **_kw: Any) -> None:
                if self._fail:
                    events.append("broken")
                    raise BrokenPipeError(32, "Broken pipe")
                events.append("sent")

            def getresponse(self) -> Any:
                class _Resp:
                    status = 200
                    headers = {"mcp-session-id": "sid"}

                    def read(self) -> bytes:
                        return b'{"jsonrpc":"2.0","id":1,"result":{}}'

                return _Resp()

            def close(self) -> None:
                events.append("closed")

        queue = list(fails)

        def _connect() -> tuple[Any, bool]:
            if client._conn is None:
                events.append("connect")
                client._conn = _Conn(queue.pop(0) if queue else False)
                return client._conn, True
            return client._conn, False

        client._connect = _connect  # type: ignore[method-assign]
        return client, events

    def test_reused_connection_break_is_retried_once(self) -> None:
        """Сервер рвёт keep-alive за 5 с — ровно шаг опроса.

        Регрессия 2026-09-02: после выкатки поллер писал «Broken pipe» на КАЖДОМ
        цикле и не доставил ни одной задачи. Дымовой прогон это пропустил, потому
        что бил вызовы подряд и пятисекундный порог не переходил.
        """
        client, events = self._client_with_conns([False])
        client._request("POST", b"{}", {})           # поднимаем соединение
        client._conn._fail = True                    # сервер закрыл его за кадром
        status, _, _ = client._request("POST", b"{}", {})
        self.assertEqual(status, 200)
        self.assertEqual(events[-4:], ["broken", "closed", "connect", "sent"])

    def test_break_on_a_fresh_connection_propagates(self) -> None:
        """Свежее соединение упало — это настоящая ошибка, а не протухший карман."""
        client, _ = self._client_with_conns([True])
        with self.assertRaises(OSError):
            client._request("POST", b"{}", {})



class TmuxPaneTest(unittest.TestCase):
    """Распознавание чистого промпта — на тех же панелях, что и в bash-тестах."""

    IDLE = "some earlier output\n❯ "
    HINT = 'output\n❯ Try"fix lint errors"'
    BUSY = "esc to interrupt\ndoing tool work"
    TYPED = "output\n❯ починить парсер"

    def _pane(self, tail: str, cursor: str = "2", rc: int = 0) -> TmuxPane:
        """Панель с подменённым вызовом tmux."""

        class _Pane(TmuxPane):
            def _tmux(self, *args: str) -> tuple[int, str]:
                if args[0] == "capture-pane":
                    return rc, tail
                if args[0] == "display":
                    return 0, cursor
                if args[0] == "has-session":
                    return 0, ""
                return 0, ""

        return _Pane("labops-test")

    def test_tmux_targets_are_exact(self) -> None:
        """Сессия — «=имя», панель — «=имя:^.{top-left}».

        Без «=» tmux ищет по началу имени: 10.09.2026 сессии labops-app не
        было, и обращения к ней уходили в labops-app-124546645 — поллер печатал
        бы задачи чужому агенту. «=имя:» — текущее окно сессии: открой оператор
        второе окно, задача ушла бы в его bash, поэтому панель — первое окно.
        """
        calls: list[tuple[str, ...]] = []

        class _Pane(TmuxPane):
            def _tmux(self, *args: str) -> tuple[int, str]:
                calls.append(args)
                return 0, "❯ x" if args[0] == "capture-pane" else "2"

        pane = _Pane("labops-app")
        pane.has_session()
        pane.clean_idle()
        pane.send_line("задача")
        targets: dict[str, set[str]] = {}
        for args in calls:
            flag = "-t" if "-t" in args else "-pt"
            targets.setdefault(args[0], set()).add(args[args.index(flag) + 1])
        self.assertEqual(targets["has-session"], {"=labops-app"})
        for command in ("capture-pane", "display", "send-keys"):
            self.assertEqual(targets[command], {"=labops-app:^.{top-left}"}, command)

    def test_clean_idle_prompt(self) -> None:
        """Пустое поле после неразрывного пробела — это простой.

        Claude Code ставит U+00A0 сразу за «❯». Если его не срезать, поле
        выглядит занятым всегда и задачи не доставляются вообще.
        """
        self.assertTrue(self._pane(self.IDLE).clean_idle())

    def test_rotating_hint_is_not_typed_input(self) -> None:
        """Подсказка Try"..." — не набранный текст."""
        self.assertTrue(self._pane(self.HINT).clean_idle())

    def test_active_turn_is_busy(self) -> None:
        self.assertFalse(self._pane(self.BUSY).clean_idle())

    def test_ghost_text_with_cursor_at_start_is_idle(self) -> None:
        """Призрак отрисовки: текст нарисован, но буфер пуст — курсор в начале."""
        self.assertTrue(self._pane(self.TYPED, cursor="2").clean_idle())

    def test_really_typed_input_is_busy(self) -> None:
        """Тот же текст, но курсор уехал — значит его действительно набрали."""
        self.assertFalse(self._pane(self.TYPED, cursor="30").clean_idle())

    def test_no_prompt_is_not_idle(self) -> None:
        self.assertFalse(self._pane("just output, no prompt").clean_idle())

    def test_tmux_failure_is_not_idle(self) -> None:
        """Не смогли прочитать панель — считаем занятой, печатать вслепую нельзя."""
        self.assertFalse(self._pane(self.IDLE, rc=1).clean_idle())

    def test_unreadable_cursor_is_not_idle(self) -> None:
        self.assertFalse(self._pane(self.TYPED, cursor="").clean_idle())

if __name__ == "__main__":
    unittest.main(verbosity=2)
