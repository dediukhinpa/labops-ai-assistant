#!/usr/bin/env python3
"""Страж точных целей tmux в agent-architecture и tg-plugin.

Без «=» tmux, не найдя сессии с точным именем, берёт первую, чьё имя НАЧИНАЕТСЯ
так же: 10.09.2026 watchdog labops-app принял labops-app-124546645 за свою
сессию и не поднял агента. А «=имя:» — это ТЕКУЩЕЕ окно сессии: открой оператор
в сессии агента второе окно, и клавиши агента ушли бы в его bash. Поэтому цель
сессии — «=имя», цель панели — «=имя:^.{top-left}».

Прежний страж был grep-ом по одной форме записи и пропускал почти все неточные:
цель без кавычек, -t"$S", одинарные кавычки, `tmux -L x …`, "$TMUX_BIN" …,
перенос строки через обратную косую, связку -pJt, подкоманды вне списка, Python
кроме self._session, весь TypeScript и tg-plugin. Этот разбирает вызов целиком.

Что считается вызовом tmux:
    * bash — слово tmux (путь …/tmux, переменная вида $TMUX_BIN) в роли команды,
      строки с продолжением склеены, «\\;» разделяет команды tmux;
    * Python (ast) — последовательность аргументов ["tmux", …] и вызов обёртки,
      чей первый аргумент — подкоманда tmux, а дальше идёт флаг цели; строки с
      командой tmux внутри разбираются как bash;
    * TypeScript — массив ['tmux', …] или [подкоманда, '-t', …] (так выглядят
      аргументы spawn/execFile и обёрток вроде runTmux), а также строки и
      шаблонные строки с командой tmux.

Нарушение — у флага с «t» (-t, -pt, -Jt, -t"…", -t$x) цель не начинается с «=»,
либо у команды над панелью цель «=имя:» (текущее окно). Цель-выражение
разрешается статически: переменная — по присваиваниям, вызов — по тому, что
возвращает функция-помощник; в TypeScript и через импорты (включая реэкспорт из
index.ts) и константы внутри шаблонных строк. Параметры функций неизвестны:
внутри строки они становятся «{}», а сами по себе целью не считаются.
Исключения — тесты (*.test.*, test_*.py, каталоги tests/) и строка с пометкой
«tmux-target-ok: <почему>».

Usage: check_tmux_targets.py [корень ...]   (по умолчанию agent-architecture
и соседний tg-plugin). Код выхода 1, если найдено хоть одно нарушение.
"""

from __future__ import annotations

import argparse
import ast
import logging
import re
import shlex
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterator, Optional, Sequence

LOG = logging.getLogger("check_tmux_targets")

AA_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_ROOTS = (AA_ROOT, AA_ROOT.parent / "tg-plugin")

# Пометка-исключение обязана нести объяснение — иначе она ничем не отличается
# от молчаливого отключения стража.
EXEMPT_MARKER = "tmux-target-ok:"
EXEMPT_RE = re.compile(re.escape(EXEMPT_MARKER) + r"[ \t]*(?P<why>\S?)")
SCANNED_SUFFIXES = frozenset({".sh", ".py", ".ts"})
SKIPPED_DIRS = frozenset(
    {".git", "node_modules", "__pycache__", ".venv", "venv", "dist", "tests", "test"}
)
# Тесты заводят свои сессии в своём сервере (lib/tmux-test-isolation.sh) и
# нарочно пишут неточные формы, чтобы проверить защиту от них.
TEST_FILE_RE = re.compile(r"(\.test\.(sh|py|ts)|\.spec\.ts|_test\.py)$|^test_.*\.py$")

# Шаблоны getopt подкоманд tmux 3.4: буква с «:» принимает значение. Без них
# значение чужого флага (-S -8, -F '#{…}', -c dir) читалось бы как флаг цели.
TMUX_COMMANDS: dict[str, str] = {
    "attach-session": "c:dEf:rt:x",
    "break-pane": "abdPF:n:s:t:",
    "capture-pane": "ab:CeE:JNpPqS:Tt:",
    "clear-history": "Ht:",
    "clock-mode": "t:",
    "command-prompt": "1bFkiI:Np:t:T:",
    "confirm-before": "bc:p:t:y",
    "copy-mode": "eHMs:t:uq",
    "detach-client": "aE:s:t:P",
    "display-message": "aCc:d:lINpt:F:v",
    "display-panes": "bd:Nt:",
    "display-popup": "Bb:Cc:d:e:Eh:s:S:t:T:w:x:y:",
    "find-window": "CiNrt:TZ",
    "has-session": "t:",
    "if-shell": "bFt:",
    "join-pane": "bdfhvp:l:s:t:",
    "kill-pane": "at:",
    "kill-server": "",
    "kill-session": "aCt:",
    "kill-window": "at:",
    "last-pane": "det:Z",
    "last-window": "t:",
    "link-window": "abdks:t:",
    "list-panes": "asF:f:O:rt:",
    "list-sessions": "F:f:O:r",
    "list-windows": "aF:f:O:rt:",
    "load-buffer": "b:t:w",
    "lock-session": "t:",
    "move-window": "abdkrs:t:",
    "new-session": "Ac:dDe:EF:f:n:Ps:t:x:Xy:",
    "new-window": "abc:de:F:kn:PSt:",
    "next-window": "at:",
    "paste-buffer": "db:prSs:t:",
    "pipe-pane": "IOot:",
    "previous-window": "at:",
    "rename-session": "t:",
    "rename-window": "t:",
    "resize-pane": "DLMRTt:Ux:y:Z",
    "resize-window": "aADLRt:Ux:y:",
    "respawn-pane": "c:e:kt:",
    "respawn-window": "c:e:kt:",
    "rotate-window": "Dt:UZ",
    "run-shell": "bd:Ct:c:",
    "select-layout": "Enopt:",
    "select-pane": "DdegLlMmP:RT:t:UZ",
    "select-window": "lnpTt:",
    "send-keys": "c:FHKlMN:Rt:X",
    "set-buffer": "ab:t:n:w",
    "set-environment": "Fhgrt:u",
    "set-hook": "agpRt:uw",
    "set-option": "aFgopqst:uUw",
    "set-window-option": "aFgoqt:u",
    "show-environment": "hgst:",
    "show-messages": "JTt:",
    "show-options": "AgHpqst:vw",
    "show-window-options": "gvt:",
    "source-file": "t:Fnqv",
    "split-window": "bc:de:fF:hIl:p:Pt:vZ",
    "swap-pane": "dDs:t:UZ",
    "swap-window": "ds:t:",
    "switch-client": "c:EFlnO:pt:rT:Z",
    "unlink-window": "kt:",
    "wait-for": "LSU",
}
TMUX_ALIASES: dict[str, str] = {
    "attach": "attach-session", "breakp": "break-pane", "capturep": "capture-pane",
    "clearhist": "clear-history", "display": "display-message", "displayp": "display-panes",
    "popup": "display-popup", "has": "has-session", "if": "if-shell",
    "joinp": "join-pane", "killp": "kill-pane", "killw": "kill-window",
    "lastp": "last-pane", "last": "last-window", "linkw": "link-window",
    "lsp": "list-panes", "ls": "list-sessions", "lsw": "list-windows",
    "movew": "move-window", "new": "new-session", "neww": "new-window",
    "next": "next-window", "pasteb": "paste-buffer", "pipep": "pipe-pane",
    "prev": "previous-window", "rename": "rename-session", "renamew": "rename-window",
    "resizep": "resize-pane", "resizew": "resize-window", "respawnp": "respawn-pane",
    "respawnw": "respawn-window", "rotatew": "rotate-window", "run": "run-shell",
    "selectl": "select-layout", "selectp": "select-pane", "selectw": "select-window",
    "send": "send-keys", "setb": "set-buffer", "setenv": "set-environment",
    "set": "set-option", "setw": "set-window-option", "showenv": "show-environment",
    "showmsgs": "show-messages", "show": "show-options", "showw": "show-window-options",
    "source": "source-file", "splitw": "split-window", "swapp": "swap-pane",
    "swapw": "swap-window", "switchc": "switch-client", "unlinkw": "unlink-window",
    "wait": "wait-for",
}
# Флаги самого tmux до подкоманды, принимающие значение: -c -f -L -S -T.
GLOBAL_VALUE_FLAGS = frozenset("cfLST")
# Для подкоманды, которой нет в таблице: считаем значащими все обычные буквы.
DEFAULT_VALUE_FLAGS = frozenset("bcdeEFfhlLnNOpsSTxy")
# Команды над панелью: у них «=имя:» означает панель ТЕКУЩЕГО окна.
PANE_COMMANDS = frozenset({
    "break-pane", "capture-pane", "clear-history", "copy-mode", "display-message",
    "display-popup", "if-shell", "join-pane", "kill-pane", "last-pane", "list-panes",
    "pipe-pane", "resize-pane", "respawn-pane", "run-shell", "select-pane", "send-keys",
    "split-window", "swap-pane",
})
SUBCOMMAND_RE = re.compile(r"[a-z][a-z-]*")
T_FLAG_RE = re.compile(r"-[A-Za-z]*t")
VAR_REF_RE = re.compile(r"\$\{?(?P<name>[A-Za-z_][A-Za-z_0-9]*)\}?")
# Стоит вместо «\;» — разделителя команд внутри одного вызова tmux.
TMUX_SEP = "@@tmux-sep@@"
SHELL_STOPS = frozenset({";", ";;", "&", "&&", "|", "||", "|&", "(", ")", "<", ">", ">>"})
# Слово tmux в роли команды: сам tmux, путь к нему или переменная с «tmux» в имени.
SHELL_TMUX_RE = re.compile(
    r"(?:^|(?<=[\s;&|(`{!]))"
    r"(?P<word>(?:[\w./-]*/)?tmux|\"?\$\{?(?P<var>[A-Za-z_][A-Za-z_0-9]*)\}?\"?)(?=\s)"
)
# Это переменные окружения самого tmux, а не путь к бинарю.
NOT_TMUX_BINARY = frozenset({"TMUX", "TMUX_PANE", "TMUX_TMPDIR"})
# Строка содержит команду tmux — повод разобрать её как командную строку.
EMBEDDED_TMUX_RE = re.compile(r"(?:^|[\s;&|(`])tmux\s+-?[a-zA-Z]")
# Сколько раз разрешать ссылку «имя → присваивание → имя …», чтобы не зациклиться.
MAX_RESOLVE_DEPTH = 8
# TypeScript тратит уровень на каждый шаг: вызов → импорт → return → шаблон →
# константа; цепочка paneTarget → sessionTarget → EXACT_SESSION_PREFIX уже ~10.
TS_MAX_RESOLVE_DEPTH = 32
# Предел вариантов значения (переменная с несколькими присваиваниями и т.п.).
MAX_VARIANTS = 16

Resolver = Callable[[object], Optional[list[str]]]


@dataclass(frozen=True)
class Tok:
    """Аргумент вызова tmux: литерал (text) или выражение (expr), которое разрешают."""

    text: Optional[str]
    expr: object = None

    @property
    def is_lit(self) -> bool:
        """Литерал ли это (значение известно без разрешения)."""
        return self.text is not None


@dataclass(frozen=True)
class TargetUse:
    """Одно вхождение флага цели в вызове tmux."""

    command: str
    flag: str
    value: Optional[Tok]


@dataclass(frozen=True)
class Violation:
    """Найденная неточная цель."""

    path: Path
    line: int
    reason: str
    source: str

    def format(self, base: Optional[Path] = None) -> str:
        """Строка отчёта: путь:строка: причина, затем сама строка кода.

        Args:
            base: Каталог, относительно которого печатать путь.

        Returns:
            Готовая к выводу строка.
        """
        shown = self.path
        if base is not None:
            try:
                shown = self.path.resolve().relative_to(base.resolve())
            except ValueError:
                shown = self.path
        return f"{shown}:{self.line}: {self.reason}\n    {self.source.strip()[:160]}"


def resolve_command(word: str) -> Optional[str]:
    """Полное имя подкоманды tmux по имени, алиасу или однозначному префиксу.

    Args:
        word: Слово на месте подкоманды.

    Returns:
        Полное имя или None, если такой подкоманды нет.
    """
    if word in TMUX_COMMANDS:
        return word
    if word in TMUX_ALIASES:
        return TMUX_ALIASES[word]
    matches = [name for name in TMUX_COMMANDS if name.startswith(word)]
    return matches[0] if len(matches) == 1 else None


def _value_flags(command: Optional[str]) -> frozenset[str]:
    """Буквы флагов подкоманды, принимающих значение."""
    if command is None or command not in TMUX_COMMANDS:
        return DEFAULT_VALUE_FLAGS
    template = TMUX_COMMANDS[command]
    return frozenset(ch for i, ch in enumerate(template)
                     if ch != ":" and i + 1 < len(template) and template[i + 1] == ":")


def parse_tmux_args(toks: Sequence[Tok]) -> list[TargetUse]:
    """Найти флаги цели в аргументах, идущих после слова tmux.

    Разбор повторяет getopt tmux: глобальные флаги, подкоманда, её флаги до
    первого позиционного аргумента. «\\;» (TMUX_SEP) начинает следующую команду.

    Args:
        toks: Аргументы после слова tmux (или начиная с подкоманды).

    Returns:
        Все вхождения флагов цели.
    """
    uses: list[TargetUse] = []
    i, n = 0, len(toks)
    while i < n and toks[i].is_lit and _is_flag(toks[i].text or ""):
        cluster = (toks[i].text or "")[1:]
        i += 1
        for j, ch in enumerate(cluster):
            if ch in GLOBAL_VALUE_FLAGS:
                i += 1 if j == len(cluster) - 1 else 0
                break
    if i >= n or not toks[i].is_lit or not SUBCOMMAND_RE.fullmatch(toks[i].text or ""):
        return uses
    word = toks[i].text or ""
    command = resolve_command(word) or word
    value_flags = _value_flags(resolve_command(word))
    i += 1
    while i < n:
        tok = toks[i]
        text = tok.text or ""
        if tok.is_lit and text == TMUX_SEP:
            return uses + parse_tmux_args(toks[i + 1:])
        if not tok.is_lit or text in SHELL_STOPS or not _is_flag(text):
            break
        i += 1
        for j, ch in enumerate(text[1:]):
            rest = text[1 + j + 1:]
            if ch == "t":
                if rest:
                    uses.append(TargetUse(command, text, _shell_tok(rest)))
                else:
                    value = toks[i] if i < n else None
                    uses.append(TargetUse(command, text, value))
                    i += 1
                break
            if ch in value_flags:
                i += 0 if rest else 1
                break
    # Разделитель мог стоять после позиционных аргументов (send-keys … Enter \; …).
    while i < n:
        if toks[i].is_lit and toks[i].text == TMUX_SEP:
            return uses + parse_tmux_args(toks[i + 1:])
        if toks[i].is_lit and toks[i].text in SHELL_STOPS:
            break
        i += 1
    return uses


def _is_flag(text: str) -> bool:
    """Флаг или связка флагов (но не «-» и не «--»)."""
    return text.startswith("-") and len(text) > 1 and text != "--"


def _shell_tok(text: str) -> Tok:
    """Токен командной строки: чистая ссылка на переменную — выражение, иначе литерал."""
    m = VAR_REF_RE.fullmatch(text)
    return Tok(None, ("shellvar", m.group("name"))) if m else Tok(text)


def judge(use: TargetUse, resolve: Resolver) -> Optional[str]:
    """Причина нарушения для вхождения цели или None, если цель точная.

    Args:
        use: Вхождение флага цели.
        resolve: Разрешение выражения в список возможных строк.

    Returns:
        Текст причины или None.
    """
    if use.value is None:
        return f"{use.flag} без цели"
    values = [use.value.text or ""] if use.value.is_lit else resolve(use.value.expr)
    if not values:
        return ("цель не разбирается статически — нужен литерал с «=» "
                f"(или пометка «{EXEMPT_MARKER} <почему>»)")
    for value in values:
        if not value.startswith("="):
            return f"цель {value!r} без «=»: tmux найдёт сессию по началу имени"
        if use.command in PANE_COMMANDS and value.endswith(":"):
            return (f"цель {value!r} — панель ТЕКУЩЕГО окна; панель агента — "
                    "«=имя:^.{top-left}»")
    return None


def _exempt(lines: Sequence[str], first: int, last: int) -> Optional[bool]:
    """Есть ли в строках first..last пометка-исключение.

    Returns:
        None — пометки нет; True — пометка с объяснением; False — без него.
    """
    for line in lines[max(first - 1, 0):last]:
        m = EXEMPT_RE.search(line)
        if m:
            return bool(m.group("why"))
    return None


def _report(path: Path, lines: Sequence[str], first: int, last: int,
            reason: Optional[str]) -> list[Violation]:
    """Учесть пометку-исключение и собрать нарушение."""
    source = lines[first - 1] if 0 < first <= len(lines) else ""
    mark = _exempt(lines, first, last)
    if mark is False:
        return [Violation(path, first, "пометка-исключение без объяснения", source)]
    if reason is None or mark:
        return []
    return [Violation(path, first, reason, source)]


# ── bash ────────────────────────────────────────────────────────────────────


def logical_lines(text: str) -> Iterator[tuple[int, int, str]]:
    """Склеить продолжения строк («\\» в конце).

    Yields:
        (первая строка, последняя строка, склеенный текст).
    """
    buf: list[str] = []
    start = 0
    for no, line in enumerate(text.splitlines(), 1):
        if not buf:
            start = no
        stripped = line.rstrip()
        if stripped.endswith("\\") and not stripped.endswith("\\\\"):
            buf.append(stripped[:-1])
            continue
        buf.append(line)
        yield start, no, " ".join(buf)
        buf = []
    if buf:
        yield start, start + len(buf) - 1, " ".join(buf)


def shell_tokens(command: str) -> list[str]:
    """Разбить командную строку, как это сделал бы shell (без подстановок).

    Незакрытая кавычка значит, что «tmux» стоял внутри строки: берём то, что
    успели разобрать, — хвост кавычки уже не аргументы.
    """
    lex = shlex.shlex(command.replace("\\;", f" {TMUX_SEP} "), posix=True,
                      punctuation_chars=";&|()<>")
    lex.whitespace_split = True
    lex.commenters = ""
    out: list[str] = []
    try:
        for tok in lex:
            out.append(tok)
    except ValueError:
        pass
    return out


def shell_uses(line: str) -> list[TargetUse]:
    """Все вхождения флагов цели в одной (склеенной) командной строке."""
    uses: list[TargetUse] = []
    for m in SHELL_TMUX_RE.finditer(line):
        var = m.group("var")
        if var is not None and ("tmux" not in var.lower() or var in NOT_TMUX_BINARY):
            continue
        toks = [_shell_tok(t) for t in shell_tokens(line[m.end():])]
        uses.extend(parse_tmux_args(toks))
    return uses


def _shell_assignments(text: str, name: str) -> list[str]:
    """Значения присваиваний переменной в shell-файле (кавычки сняты)."""
    pattern = re.compile(
        r"(?:^|[\s;&(])(?:local\s+|export\s+|readonly\s+|declare\s+(?:-\w+\s+)?)?"
        + re.escape(name) + r"=(\"[^\"]*\"|'[^']*'|[^\s;]*)", re.M)
    values = []
    for m in pattern.finditer(text):
        raw = m.group(1)
        values.append(raw[1:-1] if raw[:1] in "\"'" and len(raw) >= 2 else raw)
    return values


def scan_shell(path: Path, text: str) -> list[Violation]:
    """Проверить shell-скрипт."""
    lines = text.splitlines()

    def resolve(expr: object) -> Optional[list[str]]:
        if not (isinstance(expr, tuple) and expr[0] == "shellvar"):
            return None
        found = _shell_assignments(text, str(expr[1]))
        return found or None

    out: list[Violation] = []
    for first, last, line in logical_lines(text):
        if line.lstrip().startswith("#"):
            continue
        for use in shell_uses(line):
            out.extend(_report(path, lines, first, last, judge(use, resolve)))
    return out


def scan_embedded_shell(path: Path, lines: Sequence[str], text: str,
                        first: int, last: int) -> list[Violation]:
    """Проверить команду tmux, записанную строкой внутри Python/TypeScript."""
    if not EMBEDDED_TMUX_RE.search(text):
        return []
    out: list[Violation] = []
    for use in shell_uses(text):
        out.extend(_report(path, lines, first, last, judge(use, lambda _e: None)))
    return out


# ── общая часть Python/TypeScript ───────────────────────────────────────────


def arg_list_uses(toks: Sequence[Tok]) -> list[TargetUse]:
    """Вхождения целей в последовательности аргументов (список, вызов обёртки).

    Последовательность считается вызовом tmux, если в ней есть литерал «tmux»
    (дальше идут его аргументы) или если она начинается с подкоманды tmux и
    дальше есть флаг цели — так выглядят аргументы обёрток вроде runTmux([...]).
    """
    for i, tok in enumerate(toks):
        if tok.is_lit and (tok.text == "tmux" or (tok.text or "").endswith("/tmux")):
            return parse_tmux_args(toks[i + 1:])
    if not toks or not toks[0].is_lit:
        return []
    word = toks[0].text or ""
    if word not in TMUX_COMMANDS and word not in TMUX_ALIASES:
        return []
    if not any(t.is_lit and T_FLAG_RE.fullmatch(t.text or "") for t in toks[1:]):
        return []
    return parse_tmux_args(toks)


# ── Python ──────────────────────────────────────────────────────────────────


class PyResolver:
    """Разрешение выражений-целей по присваиваниям в том же модуле."""

    def __init__(self, tree: ast.Module) -> None:
        """Args:
            tree: Разобранный модуль.
        """
        self.by_name: dict[str, list[ast.expr]] = {}
        self.by_attr: dict[str, list[ast.expr]] = {}
        self.funcs: dict[str, list[ast.expr]] = {}
        for node in ast.walk(tree):
            if isinstance(node, (ast.Assign, ast.AnnAssign)) and node.value is not None:
                targets = node.targets if isinstance(node, ast.Assign) else [node.target]
                for target in targets:
                    if isinstance(target, ast.Name):
                        self.by_name.setdefault(target.id, []).append(node.value)
                    elif isinstance(target, ast.Attribute):
                        self.by_attr.setdefault(target.attr, []).append(node.value)
            elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                returns = [n.value for n in ast.walk(node)
                           if isinstance(n, ast.Return) and n.value is not None]
                self.funcs.setdefault(node.name, []).extend(returns)

    def __call__(self, expr: object) -> Optional[list[str]]:
        """Все строки, которыми может оказаться выражение, или None."""
        return self.literal(expr, 0) if isinstance(expr, ast.AST) else None

    def literal(self, node: ast.AST, depth: int) -> Optional[list[str]]:
        """Разрешить узел в список строк (подстановки — «{}»)."""
        if depth > MAX_RESOLVE_DEPTH:
            return None
        if isinstance(node, ast.Constant) and isinstance(node.value, str):
            return [node.value]
        if isinstance(node, ast.JoinedStr):
            return [joined_str_text(node)]
        if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add):
            left = self.literal(node.left, depth + 1)
            right = self.literal(node.right, depth + 1) or ["{}"]
            return [a + b for a in left for b in right][:MAX_VARIANTS] if left else None
        sources: list[ast.expr] = []
        if isinstance(node, ast.Name):
            sources = self.by_name.get(node.id, [])
        elif isinstance(node, ast.Attribute):
            sources = self.by_attr.get(node.attr, [])
        elif isinstance(node, ast.Call):
            func = node.func
            name = func.id if isinstance(func, ast.Name) else getattr(func, "attr", "")
            sources = self.funcs.get(name, [])
        values: list[str] = []
        for src in sources:
            got = self.literal(src, depth + 1)
            if got is None:
                return None
            values.extend(got)
        return values or None


def joined_str_text(node: ast.JoinedStr) -> str:
    """Текст f-строки с «{}» на месте подстановок."""
    parts = []
    for value in node.values:
        if isinstance(value, ast.Constant):
            parts.append(str(value.value))
        else:
            parts.append("{}")
    return "".join(parts)


def _docstring_ids(tree: ast.Module) -> set[int]:
    """id узлов-докстрингов: в них формы tmux упоминаются как текст."""
    ids: set[int] = set()
    for node in ast.walk(tree):
        if isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)):
            body = node.body
            if body and isinstance(body[0], ast.Expr) and isinstance(body[0].value, ast.Constant):
                ids.add(id(body[0].value))
    return ids


def scan_python(path: Path, text: str) -> list[Violation]:
    """Проверить Python-модуль."""
    try:
        tree = ast.parse(text, filename=str(path))
    except SyntaxError as err:
        LOG.warning("%s: не разбирается (%s) — пропуск", path, err)
        return []
    lines = text.splitlines()
    resolve = PyResolver(tree)
    skip = _docstring_ids(tree)
    for node in ast.walk(tree):
        if isinstance(node, ast.JoinedStr):
            skip.update(id(v) for v in node.values)
    out: list[Violation] = []
    for node in ast.walk(tree):
        elts: list[ast.expr] = []
        if isinstance(node, (ast.List, ast.Tuple)):
            elts = list(node.elts)
        elif isinstance(node, ast.Call):
            elts = list(node.args)
        if elts:
            toks = [Tok(e.value) if isinstance(e, ast.Constant) and isinstance(e.value, str)
                    else Tok(None, e) for e in elts]
            first, last = node.lineno, node.end_lineno or node.lineno
            for use in arg_list_uses(toks):
                out.extend(_report(path, lines, first, last, judge(use, resolve)))
        text_value: Optional[str] = None
        if isinstance(node, ast.Constant) and isinstance(node.value, str) and id(node) not in skip:
            text_value = node.value
        elif isinstance(node, ast.JoinedStr):
            text_value = joined_str_text(node)
        if text_value is not None:
            first, last = node.lineno, node.end_lineno or node.lineno
            out.extend(scan_embedded_shell(path, lines, text_value, first, last))
    return out


# ── TypeScript: лексер ──────────────────────────────────────────────────────


@dataclass(frozen=True)
class TsTok:
    """Лексема TypeScript.

    kind: str (строка в кавычках, text — значение), tpl (шаблонная строка, text —
    значение с «{}» на месте ${…}), id (цепочка a.b.c), punct, other. start/end —
    смещения в исходнике: по ним берётся текст выражения для разрешения.
    """

    kind: str
    text: str
    line: int
    start: int
    end: int


# После этих слов «/» открывает регулярное выражение, а не делит.
TS_REGEX_KEYWORDS = frozenset(
    {"return", "typeof", "case", "in", "of", "delete", "void", "throw", "new", "else",
     "do", "yield", "await"})
TS_IDENT_RE = re.compile(r"[\w$]+(?:\??\.[\w$]+)*")
TS_NUMBER_RE = re.compile(r"[\w.]+")


def _ts_regex_allowed(prev: Optional[TsTok]) -> bool:
    """Может ли «/» в этом месте начинать регулярное выражение."""
    if prev is None:
        return True
    if prev.kind == "punct":
        return prev.text not in ")]"
    return prev.kind == "id" and prev.text in TS_REGEX_KEYWORDS


def _ts_skip_string(src: str, i: int) -> int:
    """Индекс за концом строки в кавычках, начинающейся в i."""
    quote, j, n = src[i], i + 1, len(src)
    while j < n and src[j] != quote and src[j] != "\n":
        j += 2 if src[j] == "\\" else 1
    return j + 1


def _ts_template_parts(src: str, i: int) -> tuple[list[tuple[bool, str]], int]:
    """Разобрать шаблонную строку с i.

    Returns:
        (части: (это ли ${выражение}, текст), индекс за закрывающей кавычкой).
    """
    j, n = i + 1, len(src)
    parts: list[tuple[bool, str]] = []
    buf: list[str] = []
    while j < n and src[j] != "`":
        if src[j] == "\\" and j + 1 < n:
            buf.append(src[j + 1])
            j += 2
        elif src.startswith("${", j):
            if buf:
                parts.append((False, "".join(buf)))
                buf = []
            end = _ts_skip_balanced(src, j + 1)
            parts.append((True, src[j + 2:end - 1]))
            j = end
        else:
            buf.append(src[j])
            j += 1
    if buf:
        parts.append((False, "".join(buf)))
    return parts, j + 1


def _ts_template_text(parts: Sequence[tuple[bool, str]]) -> str:
    """Текст шаблона с «{}» на месте подстановок."""
    return "".join("{}" if is_expr else text for is_expr, text in parts)


def _ts_skip_balanced(src: str, i: int) -> int:
    """Индекс за скобкой, парной открывающей в i (строки внутри пропускаются)."""
    depth, j, n = 0, i, len(src)
    while j < n:
        ch = src[j]
        if ch in "'\"":
            j = _ts_skip_string(src, j)
            continue
        if ch == "`":
            j = _ts_template_parts(src, j)[1]
            continue
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
            if depth == 0:
                return j + 1
        j += 1
    return n


def ts_tokens(src: str) -> list[TsTok]:
    """Лексер TypeScript, достаточный для поиска аргументов tmux.

    Комментарии пропускаются, регулярные выражения узнаются по предыдущей
    лексеме (иначе кавычка внутри /Try".*"/ открыла бы мнимую строку).
    """
    toks: list[TsTok] = []
    i, n = 0, len(src)

    def add(kind: str, text: str, start: int, end: int) -> None:
        toks.append(TsTok(kind, text, src.count("\n", 0, start) + 1, start, end))

    while i < n:
        ch = src[i]
        if ch.isspace():
            i += 1
        elif src.startswith("//", i):
            nl = src.find("\n", i)
            i = n if nl < 0 else nl
        elif src.startswith("/*", i):
            end = src.find("*/", i + 2)
            i = n if end < 0 else end + 2
        elif ch in "'\"":
            end = _ts_skip_string(src, i)
            add("str", re.sub(r"\\(.)", r"\1", src[i + 1:end - 1]), i, end)
            i = end
        elif ch == "`":
            parts, end = _ts_template_parts(src, i)
            add("tpl", _ts_template_text(parts), i, end)
            i = end
        elif ch == "/" and _ts_regex_allowed(toks[-1] if toks else None):
            j, in_class = i + 1, False
            while j < n and src[j] != "\n":
                if src[j] == "\\":
                    j += 2
                    continue
                if in_class:
                    in_class = src[j] != "]"
                elif src[j] == "[":
                    in_class = True
                elif src[j] == "/":
                    break
                j += 1
            j += 1
            while j < n and src[j].isalpha():
                j += 1
            add("other", src[i:j], i, j)
            i = j
        elif ch.isalpha() or ch in "_$":
            m = TS_IDENT_RE.match(src, i)
            assert m is not None
            add("id", m.group(0).replace("?.", "."), i, m.end())
            i = m.end()
        elif ch.isdigit():
            m = TS_NUMBER_RE.match(src, i)
            assert m is not None
            add("other", m.group(0), i, m.end())
            i = m.end()
        else:
            add("punct", ch, i, i + 1)
            i += 1
    return toks


def ts_strip_comments(src: str) -> str:
    """Исходник с комментариями, заменёнными пробелами (смещения сохраняются).

    Разрешение имён ищет присваивания по тексту, и фраза «target = …» в
    комментарии иначе читалась бы как присваивание.
    """
    out = list(src)
    i, n = 0, len(src)
    while i < n:
        ch = src[i]
        if ch in "'\"":
            i = _ts_skip_string(src, i)
            continue
        if ch == "`":
            i = _ts_template_parts(src, i)[1]
            continue
        if src.startswith("//", i):
            end = src.find("\n", i)
            end = n if end < 0 else end
        elif src.startswith("/*", i):
            end = src.find("*/", i + 2)
            end = n if end < 0 else end + 2
        else:
            i += 1
            continue
        for k in range(i, end):
            if out[k] != "\n":
                out[k] = " "
        i = end
    return "".join(out)


# ── TypeScript: разрешение целей ────────────────────────────────────────────

# Хвост/начало строки, при которых выражение продолжается на следующей строке.
TS_CONTINUE_TAIL = ("+", "=", "(", ",", "?", ":", "&&", "||", "=>")
TS_CONTINUE_HEAD = ("+", ".", "?", ":", "&&", "||")
TS_CAST_RE = re.compile(r"\s+as\s+[\w$.<>\[\]| ]+$")
TS_CALL_RE = re.compile(r"(?P<name>[\w$]+(?:\??\.[\w$]+)*)\s*\(")
TS_NAME_RE = re.compile(r"[\w$]+(?:\??\.[\w$]+)*")
TS_ARROW_RE = re.compile(r"(?:async\s*)?(?:\([^)]*\)|[\w$]+)\s*(?::\s*[^=]+?)?=>")
TS_IMPORT_RE = re.compile(
    r"\bimport\s+(?:type\s+)?\{(?P<names>[^}]*)\}\s*from\s*['\"](?P<spec>[^'\"]+)['\"]")
TS_REEXPORT_RE = re.compile(
    r"\bexport\s+(?:type\s+)?\{(?P<names>[^}]*)\}\s*from\s*['\"](?P<spec>[^'\"]+)['\"]")
TS_STAR_EXPORT_RE = re.compile(r"\bexport\s+\*\s+from\s*['\"](?P<spec>[^'\"]+)['\"]")


def _ts_expr_end(src: str, i: int) -> int:
    """Индекс конца выражения, начинающегося в i (до ; , или закрывающей скобки)."""
    depth, j, n = 0, i, len(src)
    while j < n:
        ch = src[j]
        if ch in "'\"":
            j = _ts_skip_string(src, j)
            continue
        if ch == "`":
            j = _ts_template_parts(src, j)[1]
            continue
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            if depth == 0:
                return j
            depth -= 1
        elif depth == 0 and ch in ";,":
            return j
        elif depth == 0 and ch == "\n":
            before, after = src[i:j].rstrip(), src[j:].lstrip()
            if before and not before.endswith(TS_CONTINUE_TAIL) \
                    and not after.startswith(TS_CONTINUE_HEAD):
                return j
        j += 1
    return n


def _ts_split_plus(expr: str) -> list[str]:
    """Разбить выражение по «+» верхнего уровня (конкатенация строк)."""
    parts: list[str] = []
    depth, j, start, n = 0, 0, 0, len(expr)
    while j < n:
        ch = expr[j]
        if ch in "'\"":
            j = _ts_skip_string(expr, j)
            continue
        if ch == "`":
            j = _ts_template_parts(expr, j)[1]
            continue
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        elif ch == "+" and depth == 0 and expr[j + 1:j + 2] not in ("+", "=") \
                and expr[j - 1:j] != "+":
            parts.append(expr[start:j])
            start = j + 1
        j += 1
    parts.append(expr[start:])
    return [p.strip() for p in parts]


def _ts_named(names: str) -> Iterator[tuple[str, str]]:
    """Пары (исходное имя, локальное имя) из «{ a, b as c, type d }»."""
    for item in names.split(","):
        item = re.sub(r"^\s*type\s+", "", item).strip()
        if not item:
            continue
        orig, _, local = item.partition(" as ")
        yield orig.strip(), (local or orig).strip()


def _ts_returns(body: str) -> list[str]:
    """Выражения всех return в теле функции."""
    return [body[r.end():_ts_expr_end(body, r.end())]
            for r in re.finditer(r"\breturn\b\s*", body)]


class TsProject:
    """Разрешение выражений-целей TypeScript: литералы, константы, помощники, импорты.

    Цель вроде paneTarget(session) точна, если помощник — в этом же файле или
    импортированный, в том числе через реэкспорт из index.ts, — возвращает
    строку с «=». Так устроен tg-plugin: форму цели строит один модуль, и без
    разбора импортов страж объявил бы нарушением каждый точный вызов.
    """

    def __init__(self) -> None:
        """Кэш исходников: путь → текст без комментариев."""
        self._sources: dict[Path, str] = {}

    def remember(self, path: Path, text: str) -> str:
        """Запомнить уже прочитанный файл; вернуть его текст без комментариев."""
        code = ts_strip_comments(text)
        self._sources[path.resolve()] = code
        return code

    def source(self, path: Path) -> str:
        """Текст файла без комментариев (пусто, если не читается)."""
        key = path.resolve()
        if key not in self._sources:
            try:
                self._sources[key] = ts_strip_comments(key.read_text(encoding="utf-8"))
            except (OSError, UnicodeDecodeError):
                self._sources[key] = ""
        return self._sources[key]

    def evaluate(self, path: Path, expr: str, depth: int = 0) -> Optional[list[str]]:
        """Все строки, которыми может оказаться выражение, или None.

        Args:
            path: Файл, в контексте которого записано выражение.
            expr: Текст выражения.
            depth: Глубина разрешения (защита от циклов).

        Returns:
            Список вариантов значения (неизвестные подстановки — «{}») или None.
        """
        if depth > TS_MAX_RESOLVE_DEPTH:
            return None
        expr = TS_CAST_RE.sub("", expr.strip()).rstrip("!").strip()
        if not expr:
            return None
        pieces = _ts_split_plus(expr)
        if len(pieces) > 1:
            acc = [""]
            for idx, piece in enumerate(pieces):
                vals = self.evaluate(path, piece, depth + 1)
                if vals is None:
                    if idx == 0:
                        return None
                    vals = ["{}"]
                acc = [a + v for a in acc for v in vals][:MAX_VARIANTS]
            return acc
        head = expr[0]
        if head in "'\"":
            end = _ts_skip_string(expr, 0)
            return [re.sub(r"\\(.)", r"\1", expr[1:end - 1])] if end == len(expr) else None
        if head == "`":
            parts, end = _ts_template_parts(expr, 0)
            if end != len(expr):
                return None
            acc = [""]
            for is_expr, text in parts:
                vals = (self.evaluate(path, text, depth + 1) or ["{}"]) if is_expr else [text]
                acc = [a + v for a in acc for v in vals][:MAX_VARIANTS]
            return acc
        if head == "(" and _ts_skip_balanced(expr, 0) == len(expr):
            return self.evaluate(path, expr[1:-1], depth + 1)
        call = TS_CALL_RE.match(expr)
        if call and _ts_skip_balanced(expr, call.end() - 1) == len(expr):
            name = call.group("name").replace("?.", ".").rsplit(".", 1)[-1]
            return self.call_values(path, name, depth + 1)
        if TS_NAME_RE.fullmatch(expr):
            return self.name_values(path, expr.replace("?.", ".").rsplit(".", 1)[-1], depth + 1)
        return None

    def name_values(self, path: Path, name: str, depth: int) -> Optional[list[str]]:
        """Значения, которые получает имя: присваивания, литеральные свойства, импорт."""
        if depth > TS_MAX_RESOLVE_DEPTH:
            return None
        src = self.source(path)
        esc = re.escape(name)
        assign = re.compile(
            r"(?:\b(?:const|let|var)\s+|(?<![\w$]))(?:[\w$]+\.)*" + esc
            + r"\s*(?::\s*[^=;\n]+?)?\s*=(?![=>])\s*")
        # Свойство объекта считаем, только если его значение — строка: иначе
        # «name: string» в типе читалось бы как присваивание.
        prop = re.compile(r"(?<![\w$?.])" + esc + r"\s*:\s*(?=['\"`])")
        values: list[str] = []
        found = False
        for m in assign.finditer(src):
            rhs = src[m.end():_ts_expr_end(src, m.end())]
            if TS_ARROW_RE.match(rhs):
                continue    # это функция, а не значение
            found = True
            got = self.evaluate(path, rhs, depth + 1)
            if got is None:
                return None
            values.extend(got)
        for m in prop.finditer(src):
            got = self.evaluate(path, src[m.end():_ts_expr_end(src, m.end())], depth + 1)
            if got is not None:
                found = True
                values.extend(got)
        if not found:
            origin = self.import_origin(path, name)
            if origin is not None:
                return self.name_values(origin[0], origin[1], depth + 1)
        return values[:MAX_VARIANTS] or None

    def call_values(self, path: Path, name: str, depth: int) -> Optional[list[str]]:
        """Строки, которые возвращает функция-помощник (здесь или импортированная)."""
        if depth > TS_MAX_RESOLVE_DEPTH:
            return None
        returns = self.function_returns(path, name)
        if returns is None:
            origin = self.import_origin(path, name)
            return self.call_values(origin[0], origin[1], depth + 1) if origin else None
        values: list[str] = []
        for expr in returns:
            got = self.evaluate(path, expr, depth + 1)
            if got is None:
                return None
            values.extend(got)
        return values[:MAX_VARIANTS] or None

    def function_returns(self, path: Path, name: str) -> Optional[list[str]]:
        """Выражения return функции name, объявленной в файле; None — её здесь нет."""
        src = self.source(path)
        esc = re.escape(name)
        decl = re.search(r"\bfunction\s+" + esc + r"\s*(?:<[^>]*>)?\s*\(", src)
        if decl:
            close = _ts_skip_balanced(src, decl.end() - 1)
            brace = src.find("{", close)
            if brace < 0:
                return []
            return _ts_returns(src[brace:_ts_skip_balanced(src, brace)])
        arrow_decl = re.search(r"\b(?:const|let|var)\s+" + esc + r"\s*(?::[^=]+?)?=\s*", src)
        if arrow_decl:
            arrow = TS_ARROW_RE.match(src, arrow_decl.end())
            if arrow:
                k = arrow.end()
                while k < len(src) and src[k].isspace():
                    k += 1
                if k < len(src) and src[k] == "{":
                    return _ts_returns(src[k:_ts_skip_balanced(src, k)])
                return [src[k:_ts_expr_end(src, k)]]
        return None

    def import_origin(self, path: Path, name: str) -> Optional[tuple[Path, str]]:
        """Файл и исходное имя, откуда импортировано локальное имя."""
        for m in TS_IMPORT_RE.finditer(self.source(path)):
            for orig, local in _ts_named(m.group("names")):
                if local == name:
                    module = self.module_path(path, m.group("spec"))
                    return self.export_origin(module, orig, 0) if module else None
        return None

    def export_origin(self, module: Path, name: str, depth: int) -> Optional[tuple[Path, str]]:
        """Где на самом деле объявлено экспортируемое имя (сквозь реэкспорты)."""
        if depth > TS_MAX_RESOLVE_DEPTH:
            return None
        src = self.source(module)
        if re.search(r"\b(?:function\s+|(?:const|let|var)\s+)" + re.escape(name) + r"\b", src):
            return module, name
        for m in TS_REEXPORT_RE.finditer(src):
            for orig, exported in _ts_named(m.group("names")):
                if exported == name:
                    sub = self.module_path(module, m.group("spec"))
                    return self.export_origin(sub, orig, depth + 1) if sub else None
        for m in TS_STAR_EXPORT_RE.finditer(src):
            sub = self.module_path(module, m.group("spec"))
            got = self.export_origin(sub, name, depth + 1) if sub else None
            if got is not None:
                return got
        return None

    @staticmethod
    def module_path(path: Path, spec: str) -> Optional[Path]:
        """Файл модуля по относительному спецификатору импорта ('./x.js' → x.ts)."""
        if not spec.startswith("."):
            return None
        base = path.parent / spec
        candidates = [base.with_suffix(".ts")] if base.suffix == ".js" else []
        candidates += [base, Path(f"{base}.ts"), base / "index.ts"]
        for candidate in candidates:
            if candidate.is_file():
                return candidate.resolve()
        return None


def _ts_group(toks: Sequence[TsTok], open_idx: int) -> tuple[list[list[TsTok]], int]:
    """Элементы скобочной группы с open_idx до парной скобки, разбитые по запятым.

    Returns:
        (элементы, индекс закрывающей скобки).
    """
    elements: list[list[TsTok]] = [[]]
    depth, i = 0, open_idx
    while i < len(toks):
        tok = toks[i]
        if tok.kind == "punct" and tok.text in "([{":
            depth += 1
            if depth > 1:
                elements[-1].append(tok)
        elif tok.kind == "punct" and tok.text in ")]}":
            depth -= 1
            if depth == 0:
                return [e for e in elements if e], i
            elements[-1].append(tok)
        elif tok.kind == "punct" and tok.text == "," and depth == 1:
            elements.append([])
        else:
            elements[-1].append(tok)
        i += 1
    return [e for e in elements if e], len(toks) - 1


def _ts_element_tok(code: str, element: list[TsTok]) -> Tok:
    """Элемент массива/вызова как аргумент tmux: строка — литерал, прочее — выражение."""
    if len(element) == 1 and element[0].kind == "str":
        return Tok(element[0].text)
    return Tok(None, ("ts", code[element[0].start:element[-1].end]))


def scan_typescript(path: Path, text: str,
                    project: Optional[TsProject] = None) -> list[Violation]:
    """Проверить модуль TypeScript.

    Args:
        path: Путь к файлу.
        text: Его содержимое.
        project: Общий кэш разрешения импортов (для обхода дерева).

    Returns:
        Найденные нарушения.
    """
    project = project or TsProject()
    code = project.remember(path, text)
    lines = text.splitlines()
    toks = ts_tokens(text)

    def resolve(expr: object) -> Optional[list[str]]:
        if not (isinstance(expr, tuple) and expr[0] == "ts"):
            return None
        return project.evaluate(path, str(expr[1]))

    out: list[Violation] = []
    for i, tok in enumerate(toks):
        is_array = tok.kind == "punct" and tok.text == "["
        is_call = (tok.kind == "punct" and tok.text == "(" and i > 0
                   and toks[i - 1].kind == "id")
        if is_array or is_call:
            elements, close = _ts_group(toks, i)
            args = [_ts_element_tok(code, e) for e in elements]
            for use in arg_list_uses(args):
                out.extend(_report(path, lines, tok.line, toks[close].line,
                                   judge(use, resolve)))
        elif tok.kind in ("str", "tpl"):
            out.extend(scan_embedded_shell(path, lines, tok.text, tok.line, tok.line))
    return out


# ── обход дерева ────────────────────────────────────────────────────────────


def iter_files(root: Path) -> Iterator[Path]:
    """Файлы под проверку: .sh/.py/.ts, кроме тестов и служебных каталогов."""
    if root.is_file():
        yield root
        return
    for path in sorted(root.rglob("*")):
        rel = path.relative_to(root).parts
        if any(part in SKIPPED_DIRS for part in rel[:-1]):
            continue
        if path.suffix in SCANNED_SUFFIXES and path.is_file() and not TEST_FILE_RE.search(
                path.name):
            yield path


def scan_file(path: Path, project: Optional[TsProject] = None) -> list[Violation]:
    """Проверить один файл.

    Args:
        path: Путь к файлу (.sh, .py или .ts).
        project: Общий кэш разрешения импортов TypeScript.

    Returns:
        Найденные нарушения.
    """
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as err:
        LOG.warning("%s: не читается (%s) — пропуск", path, err)
        return []
    if path.suffix == ".sh":
        return scan_shell(path, text)
    if path.suffix == ".py":
        return scan_python(path, text)
    return scan_typescript(path, text, project)


def scan_paths(roots: Sequence[Path]) -> tuple[list[Violation], int]:
    """Проверить все корни.

    Args:
        roots: Каталоги (или файлы) под проверку; несуществующие пропускаются.

    Returns:
        (нарушения, число проверенных файлов).
    """
    violations: list[Violation] = []
    project = TsProject()
    count = 0
    for root in roots:
        if not root.exists():
            LOG.info("%s: нет — пропуск", root)
            continue
        for path in iter_files(root):
            count += 1
            violations.extend(scan_file(path, project))
    return violations, count


def main(argv: Optional[Sequence[str]] = None) -> int:
    """Точка входа CLI.

    Args:
        argv: Аргументы командной строки (без имени программы).

    Returns:
        0 — все цели точные, 1 — есть нарушения.
    """
    logging.basicConfig(level=logging.INFO, format="%(message)s", stream=sys.stdout)
    parser = argparse.ArgumentParser(description="Страж точных целей tmux.")
    parser.add_argument("roots", nargs="*", type=Path,
                        help="каталоги под проверку (по умолчанию agent-architecture и tg-plugin)")
    args = parser.parse_args(argv)
    roots = args.roots or list(DEFAULT_ROOTS)
    violations, count = scan_paths(roots)
    base = AA_ROOT.parent
    for violation in violations:
        LOG.error("%s", violation.format(base))
    if violations:
        LOG.error("неточных целей tmux: %d (проверено файлов: %d)", len(violations), count)
        return 1
    LOG.info("цели tmux точные (проверено файлов: %d)", count)
    return 0


if __name__ == "__main__":
    sys.exit(main())
