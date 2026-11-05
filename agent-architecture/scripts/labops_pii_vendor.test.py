#!/usr/bin/env python3
"""Тест: вендоренные файлы labops-pii не правились руками.

Читает vendor/labops-pii/VERSION и сверяет sha256 каждого файла; лишний или изменённый файл -
падение. Чинить нужно в репозитории labops-pii (PR, тег), затем обновить копию командой
`labops-pii/tools/vendor.sh <каталог монорепо> <тег> service,media`.
"""

from __future__ import annotations

import hashlib
import unittest
from pathlib import Path

VENDOR_DIR = Path(__file__).resolve().parents[2] / "vendor" / "labops-pii"
VERSION_NAME = "VERSION"
IGNORED_DIRS = {"__pycache__"}


def declared_hashes() -> dict[str, str]:
    """Хеши из VERSION: путь -> sha256."""
    result: dict[str, str] = {}
    in_files = False
    for line in (VENDOR_DIR / VERSION_NAME).read_text(encoding="utf-8").splitlines():
        if line.startswith("files:"):
            in_files = True
        elif in_files and line.strip():
            digest, name = line.split(None, 1)
            result[name.strip()] = digest
    return result


class VendoredUnchanged(unittest.TestCase):
    """Сверка вендоренной копии с VERSION."""

    def test_version_declares_files(self) -> None:
        self.assertTrue(declared_hashes(), "в VERSION нет списка файлов")

    def test_files_match_version(self) -> None:
        actual = {
            str(p.relative_to(VENDOR_DIR)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in VENDOR_DIR.rglob("*")
            if p.is_file() and p.name != VERSION_NAME and not IGNORED_DIRS & set(p.parts)
            and p.suffix != ".pyc"
        }
        self.assertEqual(
            actual, declared_hashes(),
            "вендоренные файлы изменены руками или не совпадают с VERSION: "
            "обновите командой labops-pii/tools/vendor.sh",
        )


if __name__ == "__main__":
    unittest.main()
