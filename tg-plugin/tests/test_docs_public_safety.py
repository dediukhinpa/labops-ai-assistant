"""Docs safety tests for files that ship in the public repo.

TASK-10 (REPORT C3): plugin/docs/canary-smoke.md was originally an internal
labops runbook that hardcoded:
  - the test bot id (100000002)
  - the operator's personal Telegram user id (100000001)
  - operator-specific Mac paths (~/Users/jasonqwwen/...)
  - production session names (channel-atlas, channel-nova, etc. — kept
    in the original as `labops-nova`, `labops-vega`, ...)
  - server-specific paths (/home/agent, sa-atlas agent ids)
  - Tailscale IPs (100.64.0.1, 127.0.0.1)
  - labops-internal terminology (replaced with "operator approval")

This test fails if any of those leak back into the public docs zone, while
keeping the file as a non-trivial public canary recipe a third-party operator
could follow (size floor enforces that sanitization did not degenerate into
deletion).

Add new forbidden tokens here when future PRs reintroduce internal context.
"""

from __future__ import annotations

import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]

CANARY_SMOKE = REPO_ROOT / "plugin" / "docs" / "canary-smoke.md"

# Tokens that must NEVER appear in any public docs file. Grouped by leak type
# so failure messages stay actionable.
FORBIDDEN_IDENTIFIERS = (
    # Bot / user ids
    "100000002",
    "100000001",
    # Operator usernames / unix users
    "jasonqwwen",
    "openclaw",
    # Absolute server paths
    "/home/agent",
    # Agent identifiers
    "sa-atlas",
    # Tailscale IPs (private mesh network — must never ship)
    "100.64.0.1",
    # Internal terminology
    "principe",
)
# NOTE: `labops` is the canonical project name and `127.0.0.1` is the
# legitimate localhost bind for the webhook listener — both are allowed.
# Earlier revisions forbade them while this plugin was being prepped for a
# generic public release; that goal is retired. We still forbid real
# operator PII (chat ids, usernames, Tailscale IPs, internal jargon).

# Files in scope for this safety check. TASK-10 starts with canary-smoke.md;
# extend the tuple as more docs are sanitized.
#
# Note: TASK-12 removed the operator Telegram user id (100000001) from
# docs/05-troubleshooting.md but that file still uses labops-specific
# operator paths (`/home/agent`, `openclaw`) inside concrete
# sudo / systemd examples. Adding TROUBLESHOOTING to this tuple requires
# rewriting those examples first. TASK-12 instead added a narrower
# `TroubleshootingPublicSafetyTest` in tests/test_docs_links.py that
# only enforces the user-id rule. A future TASK-N can promote the file
# here once the wider sanitization lands.
PUBLIC_DOCS = (CANARY_SMOKE,)

# Lower bound on file size. Sanitization must not collapse the runbook into
# a stub — it has value as a public smoke-test template only if it stays
# substantive.
MIN_BYTES = 500


class PublicDocsExistTest(unittest.TestCase):
    """Sanitization should not delete the file outright."""

    def test_canary_smoke_exists(self) -> None:
        self.assertTrue(
            CANARY_SMOKE.exists(),
            f"{CANARY_SMOKE} missing — sanitization should rewrite, not delete.",
        )

    def test_canary_smoke_non_trivial(self) -> None:
        size = CANARY_SMOKE.stat().st_size
        self.assertGreater(
            size,
            MIN_BYTES,
            f"{CANARY_SMOKE} is only {size} bytes; expected > {MIN_BYTES}. "
            "Sanitization should not strip the runbook down to a stub.",
        )


class PublicDocsNoInternalLeaksTest(unittest.TestCase):
    """Every public docs file must be free of labops-internal identifiers."""

    def _scan(self, path: Path) -> list[str]:
        text = path.read_text(encoding="utf-8")
        return [token for token in FORBIDDEN_IDENTIFIERS if token in text]

    def test_canary_smoke_no_leaks(self) -> None:
        leaks = self._scan(CANARY_SMOKE)
        self.assertEqual(
            leaks,
            [],
            f"{CANARY_SMOKE} still contains internal identifiers: {leaks}. "
            "Replace each with a public placeholder (e.g. `<test-bot-id>`, "
            "`<your-telegram-user-id>`, `~/path/to/your/.claude-lab`, "
            "`channel-<your-agent>`, `operator approval`).",
        )

    def test_all_public_docs_no_leaks(self) -> None:
        """Sweep all in-scope docs in one pass so adding new files to
        ``PUBLIC_DOCS`` automatically inherits the same guard."""
        failures: list[str] = []
        for path in PUBLIC_DOCS:
            for token in self._scan(path):
                failures.append(f"{path.name}: contains forbidden token `{token}`")
        self.assertEqual(failures, [], "\n".join(failures))


class PublicDocsMacPathsGeneralizedTest(unittest.TestCase):
    """Operator-specific Mac paths must be replaced with placeholders."""

    def test_canary_smoke_no_jasonqwwen_users_path(self) -> None:
        text = CANARY_SMOKE.read_text(encoding="utf-8")
        self.assertNotIn(
            "/Users/jasonqwwen",
            text,
            "Mac path `/Users/jasonqwwen/...` must be replaced with a generic "
            "placeholder like `~/path/to/your/.claude-lab`.",
        )

    def test_canary_smoke_uses_placeholder_path(self) -> None:
        text = CANARY_SMOKE.read_text(encoding="utf-8")
        self.assertIn(
            "~/path/to/your/.claude-lab",
            text,
            "Sanitized runbook should reference the placeholder "
            "`~/path/to/your/.claude-lab` so third-party operators see how to "
            "adapt the commands.",
        )


class PublicDocsPlaceholderHintsTest(unittest.TestCase):
    """The runbook must explain its placeholders so a stranger can follow it."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.text = CANARY_SMOKE.read_text(encoding="utf-8")

    def test_test_bot_placeholder_present(self) -> None:
        self.assertIn(
            "<test-bot-id>",
            self.text,
            "Runbook should use `<test-bot-id>` placeholder where the leaked "
            "concrete id used to live.",
        )

    def test_user_id_placeholder_present(self) -> None:
        self.assertIn(
            "<your-telegram-user-id>",
            self.text,
            "Runbook should use `<your-telegram-user-id>` placeholder where "
            "the operator's concrete id used to live.",
        )

    def test_userinfobot_hint_present(self) -> None:
        self.assertIn(
            "userinfobot",
            self.text,
            "Runbook should mention @userinfobot so operators know how to "
            "discover their numeric Telegram user id.",
        )

    def test_pre_cutover_section_marked(self) -> None:
        # Rule #5 of the sanitization spec: gateway.py references stay, but
        # must be marked as a pre-cutover migration path.
        self.assertIn(
            "Pre-cutover",
            self.text,
            "Runbook must mark Python `gateway.py` sections as `Pre-cutover` "
            "so fresh installers know to skip them.",
        )

    def test_operator_approval_wording(self) -> None:
        # The labops-internal approval wording was replaced with "operator approval".
        self.assertIn(
            "operator approval",
            self.text,
            "Production cutover sentence should read `operator approval` "
            "instead of the older labops-internal approval wording.",
        )


class PreCutoverWarningTest(unittest.TestCase):
    """MED-G #2: pre-cutover marker must include the 2026-06-15 cutover date
    and an explicit instruction for fresh installers, not a generic skip note."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.text = CANARY_SMOKE.read_text(encoding="utf-8")

    def test_warning_glyph_present(self) -> None:
        self.assertIn(
            "⚠ Pre-cutover (Python gateway.py)",
            self.text,
            "Pre-cutover header must lead with the ⚠ warning glyph and the "
            "exact phrase `Pre-cutover (Python gateway.py)` so the section is "
            "visually distinct from the rest of the runbook.",
        )

    def test_cutover_date_present(self) -> None:
        self.assertIn(
            "2026-06-15 cutover",
            self.text,
            "Pre-cutover marker must reference the `2026-06-15 cutover` date "
            "so readers know when the Python gateway path stops being supported.",
        )

    def test_legacy_reference_clause(self) -> None:
        self.assertIn(
            "becomes legacy reference only",
            self.text,
            "Pre-cutover marker must explicitly say the section "
            "`becomes legacy reference only` after the cutover.",
        )

    def test_skip_if_installing_fresh(self) -> None:
        self.assertIn(
            "Skip if installing fresh",
            self.text,
            "Pre-cutover marker must instruct fresh installers to "
            "`Skip if installing fresh`.",
        )


class SmokeMatrixCoverageTest(unittest.TestCase):
    """MED-G #11: smoke matrix must cover the multichat-era features that
    landed in PR #13 (TaskMirror), PR #22 (format=html default), and
    PR #26 (MultichatRouter + TmuxSessionPool + TmuxMirror)."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.text = CANARY_SMOKE.read_text(encoding="utf-8")

    def test_matrix_mentions_multichat_router(self) -> None:
        self.assertIn(
            "MultichatRouter",
            self.text,
            "Smoke matrix must include MultichatRouter rows (default-OFF + "
            "enabled-in-allowed-group) so operators verify PR #26 gating.",
        )

    def test_matrix_mentions_tmux_session_pool(self) -> None:
        self.assertIn(
            "TmuxSessionPool",
            self.text,
            "Smoke matrix must include TmuxSessionPool reuse + idle-kill rows "
            "so operators verify per-chat session lifecycle from PR #26.",
        )

    def test_matrix_mentions_tmux_mirror(self) -> None:
        self.assertIn(
            "TmuxMirror",
            self.text,
            "Smoke matrix must include TmuxMirror rows (enabled in DM, "
            "disabled in group) so operators verify the operator-DM-only "
            "policy for the live progress mirror.",
        )

    def test_matrix_mentions_task_mirror(self) -> None:
        self.assertIn(
            "TaskMirror",
            self.text,
            "Smoke matrix must include a TaskMirror row covering PR #13 "
            "todo-task in-place updates.",
        )

    def test_matrix_mentions_redaction(self) -> None:
        self.assertIn(
            "redact",
            self.text.lower(),
            "Smoke matrix must include a safe-telegram-api redaction row so "
            "operators verify telegram token leak protection.",
        )

    def test_matrix_mentions_format_html(self) -> None:
        self.assertIn(
            "format=html",
            self.text,
            "Smoke matrix must include a `format=html` default row covering "
            "PR #22 HTML-by-default reply rendering.",
        )

    def test_matrix_mentions_format_text_override(self) -> None:
        self.assertIn(
            "format=text",
            self.text,
            "Smoke matrix must include a `format=text` override row so "
            "operators can confirm the opt-out path from HTML rendering.",
        )

    def test_multichat_section_header_present(self) -> None:
        """Operators need a clear anchor so they can decide to skip the
        multichat block when the features are disabled in their build."""
        self.assertIn(
            "### Multichat-era smoke",
            self.text,
            "Multichat rows must be grouped under a `### Multichat-era smoke` "
            "subheader so operators can skip them when MULTICHAT_ENABLED=false.",
        )


if __name__ == "__main__":
    unittest.main()
