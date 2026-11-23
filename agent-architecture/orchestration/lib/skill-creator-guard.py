#!/usr/bin/env python3
"""Inject a graceful "claude CLI absent" guard into skill-creator's eval scripts.

skill-creator is vendored from anthropics/skills (see ../../skills/THIRD_PARTY.md and
skills/external-skills.manifest). Its description eval/optimize loop shells out to the
``claude -p`` CLI, which only exists in a Claude Code swarm. On a Codex swarm the ``claude``
binary is absent, so ``run_eval.py`` / ``improve_description.py`` crashed with
``claude: command not found`` instead of degrading. The loop cannot be ported to ``codex
exec`` cheaply: ``codex exec`` streams an agent-activity log rather than the clean text
``claude -p --output-format text`` returns, and the trigger-detection harness in ``run_eval``
relies on Claude Code internals (``.claude/commands/`` + ``--include-partial-messages``).

So we add a tiny top-of-script guard: run as a script, it checks for the ``claude`` CLI and,
if absent, prints one clear line and exits 0 instead of crashing. It keys on the binary at
runtime, so it is correct on every harness and a no-op wherever ``claude`` exists. Idempotent;
run by ``skills-external.sh`` after the skill is installed. Does not touch upstream logic — it
only prepends a guarded early-exit, so a re-vendored (new SHA) skill is re-guarded cleanly.
"""
from __future__ import annotations

import sys
from pathlib import Path

MARKER = "labops-guard:"
TARGETS = ("scripts/run_eval.py", "scripts/improve_description.py")

GUARD = (
    "# labops-guard: the eval/optimize loop shells out to the `claude` CLI (Claude Code).\n"
    "# On a harness without it (e.g. a Codex swarm) skip cleanly instead of crashing.\n"
    'if __name__ == "__main__":\n'
    "    import shutil as _lo_sh, sys as _lo_sys\n"
    '    if _lo_sh.which("claude") is None:\n'
    "        _lo_sys.stderr.write(\n"
    '            "skill-creator: the description eval/optimize loop needs the `claude` CLI "\n'
    '            "(Claude Code); it is unavailable on this harness (e.g. Codex). "\n'
    '            "The skill is authored and validated \\u2014 this step is skipped.\\n"\n'
    "        )\n"
    "        raise SystemExit(0)\n"
    "# labops-guard-end\n"
)


def patch_file(path: Path) -> str:
    """Prepend the guard to ``path`` unless already present. Returns a status word."""
    text = path.read_text(encoding="utf-8")
    if MARKER in text:
        return "skip"
    lines = text.splitlines(keepends=True)
    # После shebang, если он есть, иначе в самое начало. Гард — самостоятельный
    # `if __name__ == "__main__"` блок: при запуске как скрипт он срабатывает до остального
    # модуля, при импорте — пропускается, поэтому место вставки не зависит от структуры файла.
    insert_at = 1 if lines and lines[0].startswith("#!") else 0
    block = ("\n" + GUARD) if insert_at else GUARD
    lines.insert(insert_at, block)
    path.write_text("".join(lines), encoding="utf-8")
    return "patched"


def main() -> int:
    if len(sys.argv) != 2:
        sys.stderr.write("usage: skill-creator-guard.py <skill-dir>\n")
        return 2
    skill_dir = Path(sys.argv[1])
    for rel in TARGETS:
        target = skill_dir / rel
        if target.is_file():
            print(f"skill-creator-guard: {rel}: {patch_file(target)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
