"""Docs integrity tests for plugin/docs/progress-reporter-setup.md (docs-B2 #8).

The Codex MEDIUM review surfaced an inconsistent log-location story: the
Smoke-test / Troubleshooting section pointed operators at
``<state_dir>/logs/server.log`` while every other doc (Linux journalctl,
macOS launchd `.out.log`/`.err.log`, tmux pane capture, JSONL permissions
audit, dead-letter forensics) used a different sink. The plugin does NOT
write a ``server.log`` file — that path was phantom.

These tests pin the post-fix shape so a future edit cannot silently bring
the phantom path back:

  1. The phantom ``server.log`` reference is gone.
  2. At least one canonical supervisor-log invocation is documented
     (Linux ``journalctl -u channel-`` or macOS
     ``~/Library/Logs/labops-plugin/`` or ``tmux capture-pane``).
  3. Both the JSONL permission audit (`permissions.jsonl`) AND the
     dead-letter forensics dir (`dead-letter/`) are documented in the
     same file, so operators see the full log topology.
  4. Every relative markdown link in the file resolves to a real path,
     mirroring the guarantee `test_docs_links.RelativeLinksResolveTest`
     enforces for README/DEPRECATION-PATH.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]

PROGRESS_REPORTER_DOC = REPO_ROOT / "plugin" / "docs" / "progress-reporter-setup.md"

# Same markdown link regex as test_docs_links.py — kept local on purpose
# so this test file remains self-contained and can be run in isolation
# (`python3 tests/test_docs_progress_reporter.py -v`).
MD_LINK_RE = re.compile(r"\[[^\]]*\]\(([^)]+)\)")


def _extract_link_targets(text: str) -> list[str]:
    return MD_LINK_RE.findall(text)


def _is_external(target: str) -> bool:
    if target.startswith("http://") or target.startswith("https://"):
        return True
    if target.startswith("mailto:"):
        return True
    return False


def _strip_anchor(target: str) -> str:
    idx = target.find("#")
    if idx == -1:
        return target
    return target[:idx]


class ProgressReporterDocContentTest(unittest.TestCase):
    """Pin the post-fix shape of plugin/docs/progress-reporter-setup.md."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.text = PROGRESS_REPORTER_DOC.read_text(encoding="utf-8")

    def test_phantom_server_log_path_removed(self) -> None:
        # The plugin only DEFINES `paths.logs.server` in config.ts but no
        # writer ever creates that file. The previous wording sent operators
        # on a wild-goose chase. Forbid both spellings of the phantom path.
        self.assertNotIn(
            "logs/server.log",
            self.text,
            "plugin/docs/progress-reporter-setup.md must not reference "
            "`<state_dir>/logs/server.log` — the plugin never writes that "
            "file (docs-B2 #8). Use journalctl / launchd .out.log / tmux "
            "capture-pane instead.",
        )

    def test_canonical_supervisor_log_sink_documented(self) -> None:
        # At least one of the three canonical supervisor sinks must appear,
        # so an operator who lands on this page can find SOMETHING actionable.
        sinks = (
            "journalctl -u channel-",
            "~/Library/Logs/labops-plugin/",
            "tmux capture-pane",
        )
        missing = [s for s in sinks if s not in self.text]
        self.assertNotEqual(
            len(missing),
            len(sinks),
            "plugin/docs/progress-reporter-setup.md must document at least "
            "one canonical supervisor log sink. Expected one of: "
            f"{sinks}. None of them found. Section «Логи» missing?",
        )
        # In practice MED-E expects ALL THREE — assert that explicitly so
        # future trimming of the section trips the test instead of silently
        # losing the cross-OS coverage.
        self.assertEqual(
            missing,
            [],
            "plugin/docs/progress-reporter-setup.md must document ALL three "
            "supervisor sinks for parity with docs/03-installation-linux.md "
            f"and docs/03-installation-macos.md. Missing: {missing}.",
        )

    def test_permissions_jsonl_and_dead_letter_documented(self) -> None:
        # The two state-dir audit/forensic artifacts that an operator
        # debugging Progress Reporter needs to know about.
        self.assertIn(
            "permissions.jsonl",
            self.text,
            "plugin/docs/progress-reporter-setup.md must mention "
            "`permissions.jsonl` (JSONL audit log of relayed permission "
            "decisions) — without it operators cannot tell when a tool was "
            "blocked vs the request never reached Telegram.",
        )
        self.assertIn(
            "dead-letter/",
            self.text,
            "plugin/docs/progress-reporter-setup.md must mention "
            "`dead-letter/` (forensics dir for payloads the plugin couldn't "
            "process) — without it operators cannot diagnose why a webhook "
            "POST silently failed.",
        )


class ProgressReporterDocLinksResolveTest(unittest.TestCase):
    """Every relative markdown link in the file points to a real path.

    Mirrors `tests.test_docs_links.RelativeLinksResolveTest` so a future
    edit that introduces a cross-reference (e.g. to a renamed install
    doc) trips this test rather than leaving readers with a 404.
    """

    def test_all_relative_links_resolve(self) -> None:
        text = PROGRESS_REPORTER_DOC.read_text(encoding="utf-8")
        base_dir = PROGRESS_REPORTER_DOC.parent
        failures: list[str] = []
        for target in _extract_link_targets(text):
            if _is_external(target):
                continue
            stripped = _strip_anchor(target).strip()
            if not stripped:
                # Same-file anchor — skip.
                continue
            resolved = (base_dir / stripped).resolve()
            if not resolved.exists():
                failures.append(
                    f"link `{target}` -> {resolved} (missing)"
                )
        self.assertEqual(
            failures,
            [],
            "Broken relative links in "
            f"{PROGRESS_REPORTER_DOC.relative_to(REPO_ROOT)}:\n"
            + "\n".join(failures),
        )


if __name__ == "__main__":
    unittest.main()
