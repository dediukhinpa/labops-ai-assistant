"""Генерирует вымышленные вложения для сквозной проверки pii-proxy + media-masker.

Запуск: python pii-proxy/scripts/make_e2e_fixtures.py <каталог>
Создаёт person.png, phone.jpg, passport.png (фото с ПДн), scan.pdf (скан), text.pdf (текстовый
слой). Все значения вымышлены. Нужен Pillow (есть в venv вендоренной labops-pii).
"""

from __future__ import annotations

import io
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

FONT_PATH = Path("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf")
FONT_SIZE = 32
LINE_STEP = 70
TEXT_ORIGIN = (40, 40)
PAGE_SIZE = (1200, 500)
SCAN_PAGES = 2
SCAN_DPI = 100.0

# Все значения вымышлены; ИНН с верной контрольной суммой, иначе детектор его не примет
PII_LINES = ("ФИО: Иванов Пётр Сергеевич", "Телефон: +7 912 345-67-89", "ИНН 500100732259")
SAFE_LINES = ("Заявление на отпуск", "Отдел закупок, офис 12")
PASSPORT_LINES = ("Паспорт 4510 123456", "Выдан: ОВД района Ясенево", *SAFE_LINES)
TEXT_PDF_BODY = (
    "Dear customer, please contact Peter Ivanov by phone +7 912 345-67-89 about order 1234."
)


def make_text_image(lines: tuple[str, ...]) -> Image.Image:
    """Рисует строки чёрным по белому шрифтом DejaVu."""
    font = ImageFont.truetype(str(FONT_PATH), FONT_SIZE)
    img = Image.new("RGB", PAGE_SIZE, "white")
    draw = ImageDraw.Draw(img)
    for i, line in enumerate(lines):
        draw.text((TEXT_ORIGIN[0], TEXT_ORIGIN[1] + i * LINE_STEP), line, font=font, fill="black")
    return img


def text_pdf() -> bytes:
    """Минимальный PDF с одной страницей и настоящим текстовым слоем (Helvetica, латиница)."""
    stream = f"BT /F1 12 Tf 40 700 Td ({TEXT_PDF_BODY}) Tj ET".encode("latin-1")
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R "
        b"/Resources << /Font << /F1 5 0 R >> >> >>",
        b"<< /Length %d >>\nstream\n" % len(stream) + stream + b"\nendstream",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    ]
    out = bytearray(b"%PDF-1.4\n")
    offsets = []
    for number, body in enumerate(objects, start=1):
        offsets.append(len(out))
        out += b"%d 0 obj\n" % number + body + b"\nendobj\n"
    xref = len(out)
    out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objects) + 1)
    for off in offsets:
        out += b"%010d 00000 n \n" % off
    out += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (
        len(objects) + 1, xref)
    return bytes(out)


def scan_pdf(pages: int) -> bytes:
    """PDF из картинок без текстового слоя (скан) с ПДн на каждой странице."""
    images = [make_text_image((SAFE_LINES[0], *PII_LINES)) for _ in range(pages)]
    buf = io.BytesIO()
    images[0].save(buf, format="PDF", save_all=True, append_images=images[1:],
                   resolution=SCAN_DPI)
    return buf.getvalue()


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
    (out / "scan.pdf").write_bytes(scan_pdf(SCAN_PAGES))
    (out / "text.pdf").write_bytes(text_pdf())


if __name__ == "__main__":
    main(Path(sys.argv[1]))
