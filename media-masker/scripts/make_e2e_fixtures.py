"""Генерирует вымышленные вложения для сквозной проверки pii-proxy + media-masker.

Запуск: python media-masker/scripts/make_e2e_fixtures.py <каталог>
Создаёт person.png, phone.jpg, passport.png (фото с ПДн), scan.pdf (скан), text.pdf (текстовый
слой). Все значения вымышлены.
"""

from __future__ import annotations

import io
import sys
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from tests.conftest import PII_LINES, SAFE_LINES, make_text_image  # noqa: E402
from tests.test_api import scan_pdf, text_pdf  # noqa: E402

PASSPORT_LINES = ("Паспорт 4510 123456", "Выдан: ОВД района Ясенево", *SAFE_LINES)


def _save(img: Image.Image, path: Path, fmt: str) -> None:
    buf = io.BytesIO()
    img.save(buf, format=fmt)
    path.write_bytes(buf.getvalue())


def main(out: Path) -> None:
    """Пишет фикстуры в каталог out."""
    out.mkdir(parents=True, exist_ok=True)
    _save(make_text_image(PII_LINES), out / "person.png", "PNG")
    _save(make_text_image((*SAFE_LINES, *PII_LINES)), out / "phone.jpg", "JPEG")
    _save(make_text_image(PASSPORT_LINES), out / "passport.png", "PNG")
    (out / "scan.pdf").write_bytes(scan_pdf(2))
    (out / "text.pdf").write_bytes(text_pdf())


if __name__ == "__main__":
    main(Path(sys.argv[1]))
