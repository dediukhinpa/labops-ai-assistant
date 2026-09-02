"""Долгоживущий поллер межагентных задач (L4 -> живая сессия агента).

ЗАЧЕМ ОТДЕЛЬНЫЙ ПРОЦЕСС, А НЕ ЦИКЛ НА BASH
------------------------------------------
Прежний `task-poller.sh` на каждом цикле поднимал python3 дважды (запрос и
фильтр) и заново открывал MCP-сессию: initialize, notifications/initialized,
tools/call, DELETE -- четыре обращения и полное рукопожатие раз в пять секунд.
Замер 2026-09-02 на живом хосте: 254 мс на цикл, то есть 5.5% ядра на агента
и 11.2% на двоих, круглосуточно и вхолостую. Разбор по частям:

    python3 -c pass (голый старт)   33.7 мс
    разбор .mcp.json                51.2 мс
    запрос + фильтр                203.2 мс
    проверка простоя (2x tmux)      16.1 мс

Здесь интерпретатор стартует ОДИН раз за всё время жизни поллера, HTTP-соеди-
нение и MCP-сессия держатся открытыми, а на цикл остаются только два вызова
tmux. Ожидаемая стоимость -- десятые доли процента ядра.

Скрипт запускается обёрткой `task-poller.sh`: она остаётся живым bash-процессом,
потому что надзор (`orchestration/lib/task-poller-launch.sh`) считает поллеры
по `comm=bash` и пути скрипта в cmdline.

Переменные окружения:
    AGENT_WORKSPACE   каталог .claude агента (обязательна)
    AGENT_ID          имя агента (обязательна)
    TASK_POLL_INTERVAL       секунды между опросами (по умолчанию 5)
    SECOND_BRAIN_MEMORY_ROUTER_URL  адрес memory_router
    AGENT_BEARER      токен; иначе берётся из .mcp.json воркспейса
    TASK_POLLER_GONE_LIMIT   сколько промахов подряд по сессии tmux до выхода
    PANE_INPUT_COL0   колонка курсора на пустом поле ввода
"""

from __future__ import annotations

import json
import os
import re
import signal
import subprocess
import sys
import time
import urllib.parse
from collections.abc import Callable
from datetime import datetime, timezone
from http.client import HTTPConnection, HTTPSConnection
from pathlib import Path
from typing import Any

DEFAULT_INTERVAL_SEC = 5.0
DEFAULT_GONE_LIMIT = 3
DEFAULT_INPUT_COL0 = 2
DEFAULT_ROUTER_URL = "http://localhost:5002/mcp"
MCP_PROTOCOL_VERSION = "2024-11-05"
PANE_TAIL_LINES = 8
RECENT_SCOPE = "decisions"
RECENT_LIMIT = 30
# Игла обрывается на двоеточии намеренно: имя агента и STATUS доматчивает
# регулярка ниже, она терпима к пробелам, а ILIKE на стороне БД -- нет.
TASK_NEEDLE = "TASK-FOR:"
HTTP_TIMEOUT_SEC = 10.0
# Пауза после сбоя сети: не долбить сервер, который перезапускается.
BACKOFF_SEC = 2.0

DELIVERY_TEMPLATE = (
    "📥 Новая межагентная задача: {path}. Забери её (memory_router.get), "
    "выполни ФОНОВЫМ субагентом, по завершении supersede_decision → "
    "STATUS: done, затем продолжай текущую работу. См. AGENT_ROUTER.md."
)


def utc_stamp() -> str:
    """Метка времени в том же формате, что писал bash-поллер."""
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class BearerCache:
    """Токен агента, перечитываемый только при изменении файла.

    Разбор `.mcp.json` стоит около 50 мс -- пятая часть цикла ради значения,
    которое не меняется неделями. Но перечитывать всё же надо: агент способен
    переписать себе `.mcp.json`, и на этом уже обжигались (поллер 791 цикл
    подряд писал «no bearer», потому что читал файл грепом по строкам).
    """

    def __init__(self, mcp_path: Path, env_token: str = "") -> None:
        """Args:
            mcp_path: Путь к `.mcp.json` воркспейса агента.
            env_token: Токен из окружения; если задан, файл не читается.
        """
        self._path = mcp_path
        self._env_token = env_token
        self._token = ""
        self._mtime: float | None = None

    def get(self) -> str:
        """Вернуть токен, перечитав файл только если его тронули."""
        if self._env_token:
            return self._env_token
        try:
            mtime = self._path.stat().st_mtime
        except OSError:
            return ""
        if self._mtime == mtime and self._token:
            return self._token
        self._token = self._parse()
        self._mtime = mtime
        return self._token

    def _parse(self) -> str:
        """Достать Bearer сервера memory_router из `.mcp.json`."""
        try:
            cfg = json.loads(self._path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return ""
        servers = cfg.get("mcpServers") or {}
        for name, srv in servers.items():
            if "memory_router" not in name:
                continue
            headers = ((srv or {}).get("headers") or {})
            auth = str(headers.get("Authorization") or "")
            if auth.startswith("Bearer "):
                return auth[len("Bearer "):]
            return ""
        return ""


class TmuxPane:
    """Тонкая обёртка над tmux: существование сессии, простой, ввод строки."""

    def __init__(self, session: str, input_col0: int = DEFAULT_INPUT_COL0) -> None:
        """Args:
            session: Имя tmux-сессии агента.
            input_col0: Колонка курсора на пустом поле ввода.
        """
        self._session = session
        self._input_col0 = input_col0

    def _tmux(self, *args: str) -> tuple[int, str]:
        """Выполнить tmux и вернуть (код возврата, stdout)."""
        try:
            proc = subprocess.run(
                ["tmux", *args], capture_output=True, text=True, timeout=HTTP_TIMEOUT_SEC
            )
        except (OSError, subprocess.SubprocessError):
            return 1, ""
        return proc.returncode, proc.stdout

    def has_session(self) -> bool:
        """Жива ли сессия агента."""
        rc, _ = self._tmux("has-session", "-t", self._session)
        return rc == 0

    def clean_idle(self) -> bool:
        """Стоит ли сессия на ЧИСТОМ промпте и можно ли в неё печатать.

        Повторяет проверку watchdog: есть промпт, нет активного хода, поле
        ввода пустое. Отдельная тонкость -- «призрак»: Claude Code рисует
        подсказку следующего промпта, буфер при этом пуст. По тексту это
        неотличимо от занятого поля, поэтому решает позиция курсора.
        """
        rc, tail = self._tmux("capture-pane", "-pt", self._session, "-S", f"-{PANE_TAIL_LINES}")
        if rc != 0 or not tail:
            return False
        if "❯" not in tail:
            return False
        if "esc to interrupt" in tail:
            return False
        prompt_lines = [ln for ln in tail.splitlines() if "❯" in ln]
        if not prompt_lines:
            return False
        # Срезаем ВСЕ пробельные символы, включая неразрывный U+00A0: bash-
        # версия делала это глобально (`s/[[:space:]]//g`), и поведение
        # должно совпасть -- иначе таб или NBSP в поле сделали бы сессию
        # вечно занятой, а задачи не доставлялись бы вовсе.
        typed = re.sub(r"[\s\u00a0]", "", prompt_lines[-1].split("❯", 1)[1])
        if not typed:
            return True
        if re.fullmatch(r'Try".*"', typed):
            return True
        rc, cursor = self._tmux("display", "-pt", self._session, "#{cursor_x}")
        if rc != 0 or not cursor.strip().isdigit():
            return False
        return int(cursor.strip()) <= self._input_col0

    def send_line(self, text: str) -> bool:
        """Напечатать строку в сессию и отправить её."""
        rc, _ = self._tmux("send-keys", "-t", self._session, "-l", text)
        if rc != 0:
            return False
        rc, _ = self._tmux("send-keys", "-t", self._session, "Enter")
        return rc == 0


class SessionLost(Exception):
    """MCP-сессия больше не действительна -- нужно рукопожатие заново."""


class RouterClient:
    """Одно HTTP-соединение и одна MCP-сессия на весь срок жизни процесса.

    FastMCP требует рукопожатия: initialize отдаёт `mcp-session-id`, и только
    с этим заголовком проходят вызовы. Прежний поллер делал это КАЖДЫЕ пять
    секунд и тут же закрывал сессию. Здесь сессия живёт, пока сервер её
    принимает; на 404 (рестарт сервера, протухание) она поднимается заново.
    """

    def __init__(
        self,
        url: str,
        token_provider: Callable[[], str],
        timeout: float = HTTP_TIMEOUT_SEC,
    ) -> None:
        """Args:
            url: Полный адрес эндпоинта MCP.
            token_provider: Функция, отдающая актуальный Bearer.
            timeout: Таймаут HTTP в секундах.
        """
        parsed = urllib.parse.urlsplit(url)
        self._secure = parsed.scheme == "https"
        self._host = parsed.hostname or "localhost"
        self._port = parsed.port or (443 if self._secure else 80)
        self._path = parsed.path or "/mcp"
        self._token_provider = token_provider
        self._timeout = timeout
        self._conn: HTTPConnection | HTTPSConnection | None = None
        self._session_id: str | None = None
        # Сервер может не знать про body_contains, если он старее правки:
        # тогда переходим на выборку без фильтра и больше не пробуем.
        self._server_filters = True

    def _connect(self) -> HTTPConnection | HTTPSConnection:
        """Вернуть живое соединение, подняв его при необходимости."""
        if self._conn is None:
            factory = HTTPSConnection if self._secure else HTTPConnection
            self._conn = factory(self._host, self._port, timeout=self._timeout)
        return self._conn

    def _drop_connection(self) -> None:
        """Закрыть соединение: следующий вызов поднимет новое."""
        if self._conn is not None:
            try:
                self._conn.close()
            except OSError:
                pass
        self._conn = None

    def _request(self, method: str, body: bytes | None, headers: dict[str, str]) -> tuple[int, str, str | None]:
        """Один HTTP-запрос по живому соединению.

        Returns:
            Кортеж (статус, тело, значение заголовка mcp-session-id).
        """
        conn = self._connect()
        try:
            conn.request(method, self._path, body=body, headers=headers)
            resp = conn.getresponse()
            payload = resp.read().decode("utf-8", "replace")
            return resp.status, payload, resp.headers.get("mcp-session-id")
        except (OSError, ValueError):
            # Соединение могло быть закрыто сервером -- следующий раз с нуля.
            self._drop_connection()
            raise

    def _headers(self, extra: dict[str, str] | None = None) -> dict[str, str]:
        """Заголовки MCP-запроса с актуальным токеном."""
        headers = {
            "Authorization": f"Bearer {self._token_provider()}",
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        }
        if self._session_id:
            headers["mcp-session-id"] = self._session_id
        headers.update(extra or {})
        return headers

    @staticmethod
    def _decode(payload: str) -> dict[str, Any]:
        """Разобрать ответ: обычный JSON или последний кадр SSE."""
        text = payload
        if "data:" in text:
            for line in text.splitlines():
                if line.startswith("data:"):
                    text = line[len("data:"):].strip()
        try:
            parsed = json.loads(text)
        except ValueError:
            return {}
        return parsed if isinstance(parsed, dict) else {}

    def _rpc(self, payload: dict[str, Any]) -> dict[str, Any]:
        """Отправить JSON-RPC и вернуть разобранный ответ."""
        status, body, _ = self._request(
            "POST", json.dumps(payload).encode("utf-8"), self._headers()
        )
        if status == 404:
            raise SessionLost(f"сервер не знает сессию: HTTP {status}")
        return self._decode(body)

    def ensure_session(self) -> None:
        """Поднять MCP-сессию, если её ещё нет."""
        if self._session_id:
            return
        init = {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": MCP_PROTOCOL_VERSION,
                "capabilities": {},
                "clientInfo": {"name": "task-poller", "version": "1"},
            },
        }
        status, body, sid = self._request(
            "POST", json.dumps(init).encode("utf-8"), self._headers()
        )
        if status >= 400 or not sid:
            raise SessionLost(f"рукопожатие не удалось: HTTP {status}")
        self._session_id = sid
        self._request(
            "POST",
            json.dumps(
                {"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}}
            ).encode("utf-8"),
            self._headers(),
        )

    def recent_items(self) -> list[dict[str, Any]]:
        """Вернуть заметки задач из scope `decisions`.

        Фильтр `body_contains` применяется на стороне БД ДО `limit`: scope
        общий, и без него тридцать посторонних заметок вытесняли задачу из
        окна навсегда, причём молча.
        """
        self.ensure_session()
        args: dict[str, Any] = {"scope": RECENT_SCOPE, "limit": RECENT_LIMIT}
        if self._server_filters:
            args["body_contains"] = [TASK_NEEDLE]
        resp = self._rpc(
            {
                "jsonrpc": "2.0",
                "id": 2,
                "method": "tools/call",
                "params": {"name": "recent", "arguments": args},
            }
        )
        if self._server_filters and ("error" in resp or "result" not in resp):
            # Сервер старее правки -- дальше работаем без серверного фильтра.
            # Новый словарь, а не pop из прежнего: тот уже ушёл вызванной
            # стороне, и правка на месте меняла бы отправленный запрос задним
            # числом.
            self._server_filters = False
            resp = self._rpc(
                {
                    "jsonrpc": "2.0",
                    "id": 3,
                    "method": "tools/call",
                    "params": {
                        "name": "recent",
                        "arguments": {"scope": RECENT_SCOPE, "limit": RECENT_LIMIT},
                    },
                }
            )
        return self._extract_items(resp)

    @staticmethod
    def _extract_items(resp: dict[str, Any]) -> list[dict[str, Any]]:
        """Достать список заметок из ответа tools/call."""
        try:
            text = resp["result"]["content"][0]["text"]
            items = json.loads(text)
        except (KeyError, IndexError, TypeError, ValueError):
            return []
        return items if isinstance(items, list) else []

    def invalidate(self) -> None:
        """Забыть сессию: следующий вызов сделает рукопожатие заново."""
        self._session_id = None

    def close(self) -> None:
        """Закрыть MCP-сессию и HTTP-соединение.

        Сервер держит состояние сессии, пока клиент её не закроет. С 02.09.2026
        он вычищает и закрытые, и брошенные, но правильно закрыть за собой
        дешевле, чем полагаться на предохранитель.
        """
        if self._session_id:
            try:
                self._request("DELETE", None, self._headers())
            except (OSError, SessionLost):
                pass
            self._session_id = None
        self._drop_connection()


class TaskPoller:
    """Цикл опроса: найти адресованные мне открытые задачи и доставить их."""

    def __init__(
        self,
        agent: str,
        pane: TmuxPane,
        client: RouterClient,
        seen_path: Path,
        log: Callable[[str], None],
        interval: float = DEFAULT_INTERVAL_SEC,
        gone_limit: int = DEFAULT_GONE_LIMIT,
        sleep: Callable[[float], None] = time.sleep,
    ) -> None:
        """Args:
            agent: Имя агента-получателя.
            pane: Обёртка над tmux-сессией агента.
            client: Клиент memory_router с живой MCP-сессией.
            seen_path: Файл уже доставленных задач.
            log: Куда писать строки журнала.
            interval: Секунды между опросами.
            gone_limit: Сколько промахов подряд по сессии tmux до выхода.
            sleep: Функция паузы; вынесена ради быстрых тестов.
        """
        self._agent = agent
        self._pane = pane
        self._client = client
        self._seen_path = seen_path
        self._log = log
        self._interval = interval
        self._gone_limit = gone_limit
        self._sleep = sleep
        self._task_re = re.compile(
            r"task-for:\s*" + re.escape(agent.lower()) + r"\b"
        )
        self._open_re = re.compile(r"status:\s*open\b")
        self._stop = False

    def request_stop(self) -> None:
        """Попросить цикл завершиться после текущего прохода."""
        self._stop = True

    def _seen(self) -> set[str]:
        """Пути задач, уже доставленных в сессию."""
        try:
            return {
                line.strip()
                for line in self._seen_path.read_text(encoding="utf-8").splitlines()
                if line.strip()
            }
        except OSError:
            return set()

    def _mark_seen(self, path: str) -> None:
        """Запомнить доставленную задачу, чтобы не слать её повторно."""
        try:
            with self._seen_path.open("a", encoding="utf-8") as fh:
                fh.write(f"{path}\n")
        except OSError as exc:
            self._log(f"не удалось записать {self._seen_path.name}: {exc}")

    def open_tasks(self, items: list[dict[str, Any]]) -> list[str]:
        """Отобрать открытые задачи, адресованные этому агенту.

        Адресация живёт в ТЕЛЕ заметки: `recent()` отдаёт тело как `snippet`,
        но не отдаёт ни frontmatter-теги, ни заголовок.
        """
        found: list[str] = []
        for item in items:
            blob = str(item.get("snippet", "")).lower()
            if not self._task_re.search(blob) or not self._open_re.search(blob):
                continue
            path = item.get("path")
            if path:
                found.append(str(path))
        return found

    def poll_once(self) -> None:
        """Один проход опроса. Никогда не бросает исключений наружу."""
        # Проверка простоя -- первой: доставить в занятую сессию всё равно
        # нельзя, а опрос дороже проверки на порядок.
        if not self._pane.clean_idle():
            return
        try:
            items = self._client.recent_items()
        except SessionLost as exc:
            self._log(f"сессия MCP потеряна ({exc}) — рукопожатие заново")
            self._client.invalidate()
            return
        except (OSError, ValueError) as exc:
            self._log(f"опрос не удался: {exc}")
            self._client.invalidate()
            self._sleep(BACKOFF_SEC)
            return

        seen = self._seen()
        for path in self.open_tasks(items):
            if path in seen:
                continue
            if not self._pane.clean_idle():
                # Сессия занялась, пока мы ходили в сеть -- оставляем на потом.
                continue
            if self._pane.send_line(DELIVERY_TEMPLATE.format(path=path)):
                self._mark_seen(path)
                seen.add(path)
                self._log(f"delivered task {path} → session (background subagent)")
            else:
                self._log(f"deliver failed for {path} (tmux) — will retry")

    def run(self) -> int:
        """Крутить цикл, пока жива сессия агента.

        Returns:
            Код возврата процесса: 0 -- сессия исчезла, штатный выход.
        """
        self._log(
            f"started (agent={self._agent} interval={self._interval:g}s, "
            "постоянный процесс)"
        )
        gone = 0
        try:
            while not self._stop:
                if self._pane.has_session():
                    gone = 0
                    self.poll_once()
                else:
                    gone += 1
                    if gone >= self._gone_limit:
                        self._log(f"session gone ({gone}× подряд) — exiting")
                        return 0
                    # Кратковременный флап tmux при рестарте юнита не повод
                    # выходить: за поллером всё равно следит watchdog.
                    self._log(
                        f"session check failed ({gone}/{self._gone_limit}) — "
                        "возможно рестарт, не выхожу"
                    )
                self._sleep(self._interval)
        finally:
            self._client.close()
        return 0


def build_poller() -> TaskPoller:
    """Собрать поллер из переменных окружения."""
    workspace = Path(os.environ["AGENT_WORKSPACE"])
    agent = os.environ["AGENT_ID"]
    interval = float(os.environ.get("TASK_POLL_INTERVAL") or DEFAULT_INTERVAL_SEC)
    gone_limit = int(os.environ.get("TASK_POLLER_GONE_LIMIT") or DEFAULT_GONE_LIMIT)
    input_col0 = int(os.environ.get("PANE_INPUT_COL0") or DEFAULT_INPUT_COL0)
    url = os.environ.get("SECOND_BRAIN_MEMORY_ROUTER_URL") or DEFAULT_ROUTER_URL

    log_path = workspace / "logs" / "task-poller.log"
    log_path.parent.mkdir(parents=True, exist_ok=True)

    def log(message: str) -> None:
        """Дописать строку в журнал поллера в прежнем формате."""
        try:
            with log_path.open("a", encoding="utf-8") as fh:
                fh.write(f"{utc_stamp()} [task-poller] {message}\n")
        except OSError:
            pass

    seen_path = workspace / "core" / "active" / ".task-seen"
    seen_path.parent.mkdir(parents=True, exist_ok=True)
    seen_path.touch(exist_ok=True)

    bearer = BearerCache(workspace / ".mcp.json", os.environ.get("AGENT_BEARER", ""))
    client = RouterClient(url, bearer.get)
    pane = TmuxPane(f"labops-{agent}", input_col0)
    return TaskPoller(agent, pane, client, seen_path, log, interval, gone_limit)


def main() -> int:
    """Точка входа: собрать поллер и крутить цикл до исчезновения сессии."""
    poller = build_poller()

    def _on_signal(_signum: int, _frame: Any) -> None:
        """Закрыть MCP-сессию и выйти по-человечески."""
        poller.request_stop()

    signal.signal(signal.SIGTERM, _on_signal)
    signal.signal(signal.SIGINT, _on_signal)
    return poller.run()


if __name__ == "__main__":
    sys.exit(main())
