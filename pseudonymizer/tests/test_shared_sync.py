"""Копия pii_patterns.py совпадает с каноническим shared/pii_patterns.py."""

import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[3]


def test_shared_patterns_match_canonical_source() -> None:
    """Расхождение копии с исходником падает локально (sync-shared.sh --check)."""
    script = ROOT / "scripts" / "sync-shared.sh"
    if not script.is_file():
        pytest.skip("скрипт синхронизации недоступен (отдельный образ)")
    result = subprocess.run(
        ["bash", str(script), "--check"], capture_output=True, text=True, check=False
    )
    assert result.returncode == 0, result.stderr
