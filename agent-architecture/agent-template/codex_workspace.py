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

Запись атомарная (временный файл + rename): драйвер может читать AGENTS.md в любой момент.
"""

from __future__ import annotations

import argparse
import logging
import os
import re
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

logger = logging.getLogger("codex_workspace")

# Заголовок раздела о канале в CLAUDE.md.template: раздел идёт до следующего «## ».
CHANNEL_HEADING = "## Talking to the operator (channel)"
SECTION_HEADING = re.compile(r"^## ", re.MULTILINE)
IMPORT_LINE = re.compile(r"^@(\S+)\s*$")
# Глубина вложенных @-импортов: у Claude Code предел 5, наши шаблоны используют один уровень.
MAX_IMPORT_DEPTH = 5
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


def expand_imports(text: str, base: Path, depth: int = 0) -> str:
    """Развернуть строки ``@путь`` содержимым файлов (пути от каталога ``base``).

    Отсутствующий файл не роняет сборку: на его месте пометка, как у Claude Code, который
    молча пропускает несуществующий импорт.

    Args:
        text: Текст с импортами.
        base: Каталог, от которого считаются пути.
        depth: Текущая глубина вложенности.

    Returns:
        Текст без строк импорта.
    """
    out: list[str] = []
    for line in text.splitlines(keepends=True):
        m = IMPORT_LINE.match(line)
        if m is None:
            out.append(line)
            continue
        target = (base / m.group(1)).resolve()
        if depth >= MAX_IMPORT_DEPTH:
            out.append(f"<!-- импорт {m.group(1)} пропущен: глубже {MAX_IMPORT_DEPTH} -->\n")
            continue
        if not target.is_file():
            out.append(f"<!-- {m.group(1)}: файла нет -->\n")
            continue
        body = expand_imports(target.read_text(encoding="utf-8"), target.parent, depth + 1)
        out.append(f"<!-- begin {m.group(1)} -->\n{body.rstrip()}\n<!-- end {m.group(1)} -->\n")
    return "".join(out)


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
    text = GENERATED_NOTE + expand_imports(src.read_text(encoding="utf-8"), workspace)
    write_atomic(workspace / "AGENTS.md", text)
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
    p.set_defaults(func=cmd_agents_md)
    args = parser.parse_args(argv)
    return int(args.func(args))


if __name__ == "__main__":
    sys.exit(main())
