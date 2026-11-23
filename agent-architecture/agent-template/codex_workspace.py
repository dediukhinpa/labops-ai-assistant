#!/usr/bin/env python3
"""Сборка рабочей папки агента на харнесе Codex CLI из тех же шаблонов, что у Claude Code.

Тексты идентичности, правил и памяти у обоих харнесов общие: шаблоны пишутся один раз
(agent-template/templates/*.template), а для Codex этот модуль только адаптирует их:

- ``adapt`` — заменяет в уже заполненном файле упоминания, которые у Codex другие
  (где лежат общие правила, как называется файл идентичности, чем запускать подагентов);
- ``identity`` — собирает исходник идентичности ``AGENTS.src.md`` из заполненного
  CLAUDE.md: раздел о канале заменяется на вариант Codex (ответ — финальное сообщение хода,
  его доставляет драйвер), остальное без изменений;
- ``agents-md`` — разворачивает строки ``@путь`` исходника в ``AGENTS.md``. Codex не умеет
  @-импорт, а Claude перечитывает импортированные файлы на каждом старте сессии; поэтому
  драйвер вызывает эту команду перед каждым стартом нити, и память в AGENTS.md свежая.
  Заодно сверяет размер результата с ``project_doc_max_bytes`` из config.toml агента: Codex
  молча обрезает AGENTS.md сверх предела, а память (decisions.md, preferences.md) растёт.
  Размер пишется в ``state/agents-md-size.json`` — его читает doctor.sh.

Запись атомарная (временный файл + rename): драйвер может читать AGENTS.md в любой момент.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import re
import sys
import tempfile
import tomllib
from dataclasses import dataclass
from pathlib import Path

logger = logging.getLogger("codex_workspace")

# Заголовок раздела о канале в CLAUDE.md.template: раздел идёт до следующего «## ».
CHANNEL_HEADING = "## Talking to the operator (channel)"
SECTION_HEADING = re.compile(r"^## ", re.MULTILINE)
IMPORT_LINE = re.compile(r"^@(\S+)\s*$")
# Путь импорта: только «путевые» символы. Так «@christopher_coderbot» или «@dataclass» не путь,
# даже если рядом вдруг окажется файл с таким именем; обязательна «/» или «.» (расширение).
IMPORT_PATH = re.compile(r"^[\w.~+/-]+$")
# Начало/конец fenced-блока кода по CommonMark: до 3 пробелов отступа, забор из ``` или ~~~.
FENCE_LINE = re.compile(r"^ {0,3}(`{3,}|~{3,})(.*)$")
# Глубина вложенных @-импортов: у Claude Code предел 5, наши шаблоны используют один уровень.
MAX_IMPORT_DEPTH = 5
# Предел размера AGENTS.md по умолчанию — тот же, что в templates/codex/config.toml.template
# (project_doc_max_bytes); берётся, когда config.toml агента не читается.
DEFAULT_PROJECT_DOC_MAX_BYTES = 262144
# С какой доли предела предупреждать: после неё до обрезки остаётся лишь запас на рост памяти.
WARN_FRACTION = 0.75
# Сколько самых крупных источников называть в предупреждении и статус-файле.
TOP_SOURCES = 5
# Статус-файл размера рядом с рабочей папкой: его читает doctor.sh.
SIZE_STATUS_REL = Path("state") / "agents-md-size.json"
LEVEL_OK, LEVEL_WARN, LEVEL_OVER = "ok", "warn", "over"
GENERATED_NOTE = (
    "<!-- Собрано из AGENTS.src.md командой codex_workspace.py agents-md; правьте исходник и"
    " файлы памяти, этот файл перезаписывается перед каждым стартом нити. -->\n\n"
)


@dataclass(frozen=True)
class Replacement:
    """Замена текста в файле для Codex.

    Attributes:
        old: Строка, как она стоит в шаблоне Claude.
        new: Строка для Codex; ``{agent_id}`` подставляется id агента.
    """

    old: str
    new: str


# Порядок важен: длинные строки раньше их частей (``~/.claude/CLAUDE.md`` раньше ``CLAUDE.md``).
REPLACEMENTS: tuple[Replacement, ...] = (
    Replacement("`~/.claude/CLAUDE.md`", "`~/.claude-lab/{agent_id}/.codex/AGENTS.md`"),
    Replacement("~/.claude/CLAUDE.md", "~/.claude-lab/{agent_id}/.codex/AGENTS.md"),
    Replacement(
        "- **CLAUDE.md**: `~/.claude-lab/{agent_id}/.claude/CLAUDE.md` (identity)",
        "- **AGENTS.md**: `~/.claude-lab/{agent_id}/.claude/AGENTS.md` (identity, assembled from"
        " `AGENTS.src.md` and the memory files before every thread start)",
    ),
    Replacement("live in\nCLAUDE.md;", "live in\nAGENTS.src.md;"),
    Replacement("| IDENTITY (red) | CLAUDE.md,", "| IDENTITY (red) | AGENTS.src.md,"),
    Replacement(
        "- **Subagents:** only the native Claude Code Agent tool (inherit the parent model or\n"
        "  override in agents/*.md), at most",
        "- **Subagents:** only Codex's built-in sub-agents (they inherit the parent model),\n"
        "  at most",
    ),
    Replacement(
        " (alias — resolves to the latest model of its tier; a full model name pins a version)",
        "",
    ),
)


def adapt_text(text: str, agent_id: str) -> str:
    """Применить замены Codex к тексту.

    Args:
        text: Заполненный текст шаблона Claude.
        agent_id: Id агента (для путей).

    Returns:
        Текст для Codex.
    """
    for rep in REPLACEMENTS:
        old = rep.old.replace("{agent_id}", agent_id)
        new = rep.new.replace("{agent_id}", agent_id)
        text = text.replace(old, new)
    return text


def swap_channel_section(identity: str, codex_section: str) -> str:
    """Заменить раздел о канале на вариант Codex.

    Args:
        identity: Заполненный CLAUDE.md.
        codex_section: Текст раздела для Codex (с заголовком).

    Returns:
        Текст идентичности для Codex.

    Raises:
        ValueError: В тексте нет раздела о канале (шаблон поменялся — молча собрать
            идентичность без правил ответа нельзя).
    """
    start = identity.find(CHANNEL_HEADING)
    if start < 0:
        raise ValueError(f"нет раздела «{CHANNEL_HEADING}» в шаблоне идентичности")
    following = SECTION_HEADING.search(identity, start + len(CHANNEL_HEADING))
    end = following.start() if following else len(identity)
    section = codex_section.rstrip("\n") + "\n\n"
    return identity[:start] + section + identity[end:]


@dataclass(frozen=True)
class Source:
    """Файл, вошедший в AGENTS.md.

    Attributes:
        path: Как файл назван в импорте (для исходника — ``AGENTS.src.md``).
        size: Размер самого файла в байтах (без вложенных импортов, чтобы не считать дважды).
    """

    path: str
    size: int


def _fence_close(fence: str, line: str) -> bool:
    """Закрывает ли ``line`` fenced-блок, открытый забором ``fence`` (CommonMark)."""
    m = FENCE_LINE.match(line.rstrip("\r\n"))
    if m is None or m.group(2).strip():
        return False
    return m.group(1)[0] == fence[0] and len(m.group(1)) >= len(fence)


def _fence_open(line: str) -> str | None:
    """Забор, которым ``line`` открывает fenced-блок, или None, если это не открытие."""
    m = FENCE_LINE.match(line.rstrip("\r\n"))
    if m is None:
        return None
    # Инфострока бэктик-забора не может содержать бэктик (иначе это инлайн-код).
    if m.group(1)[0] == "`" and "`" in m.group(2):
        return None
    return m.group(1)


def _resolve_import(spec: str, base: Path) -> Path | None:
    """Файл импорта ``@spec`` или None, если строка не похожа на путь к существующему файлу."""
    if IMPORT_PATH.match(spec) is None or not ("/" in spec or "." in spec):
        return None
    try:
        target = (base / spec).resolve()
        return target if target.is_file() else None
    except (OSError, RuntimeError):
        return None


def expand_imports(
    text: str,
    base: Path,
    depth: int = 0,
    sources: list[Source] | None = None,
    root: Path | None = None,
) -> str:
    """Развернуть строки ``@путь`` содержимым файлов (пути от каталога ``base``).

    Как Claude Code: внутри fenced-блоков кода (``` и ~~~) импорты не трогаются, а строка,
    которая не указывает на существующий файл (``@handle`` в USER.md, ``@dataclass``),
    остаётся как есть — иначе исходный текст памяти молча пропал бы из AGENTS.md.

    Args:
        text: Текст с импортами.
        base: Каталог, от которого считаются пути.
        depth: Текущая глубина вложенности.
        sources: Если задан — сюда добавляются все развёрнутые файлы (для учёта размера).
        root: Рабочая папка: от неё считаются имена источников (у вложенного импорта путь
            написан от его каталога, оператору нужен понятный путь от корня).

    Returns:
        Текст, где строки существующих импортов заменены содержимым файлов.
    """
    out: list[str] = []
    fence: str | None = None
    for line in text.splitlines(keepends=True):
        if fence is not None:
            if _fence_close(fence, line):
                fence = None
            out.append(line)
            continue
        opened = _fence_open(line)
        if opened is not None:
            fence = opened
            out.append(line)
            continue
        m = IMPORT_LINE.match(line)
        target = _resolve_import(m.group(1), base) if m else None
        if m is None or target is None:
            out.append(line)
            continue
        if depth >= MAX_IMPORT_DEPTH:
            out.append(f"<!-- импорт {m.group(1)} пропущен: глубже {MAX_IMPORT_DEPTH} -->\n")
            continue
        raw = target.read_text(encoding="utf-8")
        if sources is not None:
            label = os.path.relpath(target, root) if root is not None else m.group(1)
            sources.append(Source(label, len(raw.encode("utf-8"))))
        body = expand_imports(raw, target.parent, depth + 1, sources, root)
        out.append(f"<!-- begin {m.group(1)} -->\n{body.rstrip()}\n<!-- end {m.group(1)} -->\n")
    return "".join(out)


def read_doc_limit(config_path: Path) -> int:
    """Предел ``project_doc_max_bytes`` из config.toml агента.

    Args:
        config_path: Путь к CODEX_HOME/config.toml.

    Returns:
        Значение из файла; если файла нет, он не читается или значение не положительное
        целое — предел по умолчанию из шаблона.
    """
    try:
        value = tomllib.loads(config_path.read_text(encoding="utf-8")).get("project_doc_max_bytes")
    except (OSError, ValueError):
        return DEFAULT_PROJECT_DOC_MAX_BYTES
    if isinstance(value, int) and not isinstance(value, bool) and value > 0:
        return value
    return DEFAULT_PROJECT_DOC_MAX_BYTES


def size_level(size: int, limit: int) -> str:
    """Уровень размера: ok, warn (с доли ``WARN_FRACTION``) или over (больше предела)."""
    if size > limit:
        return LEVEL_OVER
    if size >= limit * WARN_FRACTION:
        return LEVEL_WARN
    return LEVEL_OK


def report_size(workspace: Path, size: int, limit: int, sources: list[Source]) -> str:
    """Сверить размер AGENTS.md с пределом: лог и статус-файл для doctor.

    Сборку это не прерывает: агент должен стартовать, пусть и с обрезанной памятью.

    Args:
        workspace: Рабочая папка агента (статус пишется в ``state/``).
        size: Размер собранного AGENTS.md в байтах.
        limit: Предел ``project_doc_max_bytes``.
        sources: Вошедшие файлы.

    Returns:
        Уровень размера (``ok``/``warn``/``over``).
    """
    level = size_level(size, limit)
    top = sorted(sources, key=lambda src: src.size, reverse=True)[:TOP_SOURCES]
    top_text = ", ".join(f"{src.path} ({src.size} Б)" for src in top)
    if level == LEVEL_OVER:
        logger.error(
            "AGENTS.md занимает %d Б при пределе %d Б: Codex обрежет хвост без предупреждения."
            " Самые крупные источники: %s. Сократите или консолидируйте decisions.md /"
            " preferences.md.", size, limit, top_text)
    elif level == LEVEL_WARN:
        logger.warning(
            "AGENTS.md занимает %d Б из %d Б (порог предупреждения %s)."
            " Самые крупные источники: %s. Пора сокращать decisions.md / preferences.md.",
            size, limit, f"{WARN_FRACTION:.0%}", top_text)
    status = {
        "bytes": size,
        "limit": limit,
        "warn_fraction": WARN_FRACTION,
        "level": level,
        "sources": [{"path": src.path, "bytes": src.size} for src in top],
    }
    write_atomic(workspace / SIZE_STATUS_REL, json.dumps(status, ensure_ascii=False) + "\n")
    return level


def write_atomic(path: Path, text: str, mode: int = 0o644) -> None:
    """Записать файл атомарно: временный файл в том же каталоге и rename.

    Args:
        path: Куда писать.
        text: Содержимое.
        mode: Права файла.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise


def cmd_adapt(args: argparse.Namespace) -> int:
    """Адаптировать файлы на месте."""
    for name in args.files:
        path = Path(name)
        text = path.read_text(encoding="utf-8")
        adapted = adapt_text(text, args.agent_id)
        if adapted != text:
            write_atomic(path, adapted, path.stat().st_mode & 0o777)
            logger.info("адаптирован для Codex: %s", path)
    return 0


def cmd_identity(args: argparse.Namespace) -> int:
    """Собрать AGENTS.src.md из заполненного CLAUDE.md."""
    src = Path(args.claude_md).read_text(encoding="utf-8")
    section = Path(args.channel_section).read_text(encoding="utf-8")
    text = adapt_text(swap_channel_section(src, section), args.agent_id)
    write_atomic(Path(args.out), text)
    logger.info("идентичность Codex: %s", args.out)
    return 0


def cmd_agents_md(args: argparse.Namespace) -> int:
    """Развернуть AGENTS.src.md рабочей папки в AGENTS.md."""
    workspace = Path(args.workspace)
    src = workspace / "AGENTS.src.md"
    if not src.is_file():
        logger.error("нет %s", src)
        return 1
    raw = src.read_text(encoding="utf-8")
    sources = [Source("AGENTS.src.md", len(raw.encode("utf-8")))]
    text = GENERATED_NOTE + expand_imports(raw, workspace, sources=sources, root=workspace)
    write_atomic(workspace / "AGENTS.md", text)
    # config.toml лежит в CODEX_HOME агента рядом с рабочей папкой (.claude/ и .codex/).
    config = Path(args.config) if args.config else workspace.parent / ".codex" / "config.toml"
    try:
        report_size(workspace, len(text.encode("utf-8")), read_doc_limit(config), sources)
    except OSError as exc:  # статус — вспомогательный: из-за него сборка не падает
        logger.warning("не записан статус размера AGENTS.md: %s", exc)
    return 0


def main(argv: list[str] | None = None) -> int:
    """Точка входа CLI.

    Args:
        argv: Аргументы (по умолчанию sys.argv).

    Returns:
        Код выхода.
    """
    logging.basicConfig(level=logging.INFO, format="%(message)s", stream=sys.stderr)
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("adapt", help="адаптировать заполненные файлы для Codex на месте")
    p.add_argument("--agent-id", required=True)
    p.add_argument("files", nargs="+")
    p.set_defaults(func=cmd_adapt)
    p = sub.add_parser("identity", help="AGENTS.src.md из заполненного CLAUDE.md")
    p.add_argument("--agent-id", required=True)
    p.add_argument("--channel-section", required=True)
    p.add_argument("claude_md")
    p.add_argument("out")
    p.set_defaults(func=cmd_identity)
    p = sub.add_parser("agents-md", help="развернуть AGENTS.src.md в AGENTS.md")
    p.add_argument("workspace")
    p.add_argument("--config", help="config.toml Codex (по умолчанию ../.codex/config.toml)")
    p.set_defaults(func=cmd_agents_md)
    args = parser.parse_args(argv)
    return int(args.func(args))


if __name__ == "__main__":
    sys.exit(main())
