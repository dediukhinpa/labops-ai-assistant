"""Генерирует вымышленные вложения для сквозной проверки pii-proxy + media-masker.

Запуск: python pii-proxy/scripts/make_e2e_fixtures.py <каталог>
Создаёт person.png, phone.jpg, passport.png (фото с ПДн), scan.pdf (скан), text.pdf (текстовый
слой), card.png (визитка с подписью), qr.png (QR с vCard), photo.png (фото без текста).
Все значения вымышлены. Нужны Pillow, OpenCV и numpy (есть в venv вендоренной labops-pii).
"""

from __future__ import annotations

import io
import random
import sys
from pathlib import Path

import cv2
import numpy as np
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


def make_text_image(lines: tuple[str, ...], size: tuple[int, int] = PAGE_SIZE) -> Image.Image:
    """Рисует строки чёрным по белому шрифтом DejaVu."""
    font = ImageFont.truetype(str(FONT_PATH), FONT_SIZE)
    img = Image.new("RGB", size, "white")
    draw = ImageDraw.Draw(img)
    for i, line in enumerate(lines):
        draw.text((TEXT_ORIGIN[0], TEXT_ORIGIN[1] + i * LINE_STEP), line, font=font, fill="black")
    return img


CARD_SIZE = (1200, 600)
CARD_LINES = (
    "Иванов Пётр Сергеевич",
    "Директор по закупкам",
    "+7 912 345-67-89",
    "г. Абакан, ул. Ленина 15",
)
CARD_FRAGMENTS = ("Иванов", "Сергеевич", "912", "Абакан", "Ленина")

VCARD = (
    "BEGIN:VCARD\nVERSION:3.0\nN:Иванов;Пётр;Сергеевич;;\nFN:Иванов Пётр Сергеевич\n"
    "TEL;TYPE=CELL:+7 912 345-67-89\nEMAIL:petr.ivanov@example.com\n"
    "ADR;TYPE=WORK:;;ул. Ленина 15;Абакан;;655017;Россия\nEND:VCARD"
)
QR_MODULE_PX = 5
QR_QUIET_PX = 40
QR_ORIGIN = (100, 100)

SIGNATURE_ORIGIN = (700, 450)
SIGNATURE_BOX = (680, 400, 1000, 520)
INK = (20, 20, 60)
SIGNATURE_POINTS = 40
SIGNATURE_WIDTH = 3



def card_image() -> Image.Image:
    """Визитка: ФИО, должность, телефон, адрес."""
    return make_text_image(CARD_LINES, CARD_SIZE)


def draw_signature(img: Image.Image, origin: tuple[int, int] = SIGNATURE_ORIGIN) -> None:
    """Рисует «рукописную» подпись: плавная кривая со случайной дрожью и росчерк.

    Tesseract такое не читает (проверено в тестах), как и настоящую подпись.
    """
    rnd = random.Random(7)
    draw = ImageDraw.Draw(img)
    x, y = origin
    points = []
    for i in range(SIGNATURE_POINTS):
        x += rnd.randint(4, 9)
        y = origin[1] + int(35 * np.sin(i / 2.3)) + rnd.randint(-6, 6)
        points.append((x, y))
    draw.line(points, fill=INK, width=SIGNATURE_WIDTH, joint="curve")
    draw.line([(origin[0] - 10, origin[1] + 50), (x + 20, origin[1] + 30)],
              fill=INK, width=SIGNATURE_WIDTH)


def qr_image(payload: str, size: tuple[int, int] = (1200, 700)) -> Image.Image:
    """Белая картинка с QR-кодом на месте QR_ORIGIN."""
    code = cv2.QRCodeEncoder.create().encode(payload)
    code = cv2.resize(code, None, fx=QR_MODULE_PX, fy=QR_MODULE_PX,
                      interpolation=cv2.INTER_NEAREST)
    code = cv2.copyMakeBorder(code, QR_QUIET_PX, QR_QUIET_PX, QR_QUIET_PX, QR_QUIET_PX,
                              cv2.BORDER_CONSTANT, value=255)
    img = Image.new("RGB", size, "white")
    img.paste(Image.fromarray(code).convert("RGB"), QR_ORIGIN)
    return img


def photo_image(size: tuple[int, int] = (900, 600)) -> Image.Image:
    """Фото без текста: градиент, пятна и мелкий шум, слегка размытые."""
    rnd = np.random.RandomState(1)
    width, height = size
    base = np.zeros((height, width, 3), np.float32)
    yy, xx = np.mgrid[0:height, 0:width]
    base[..., 0] = 120 + 60 * xx / width
    base[..., 1] = 140 + 50 * yy / height
    base[..., 2] = 170
    for _ in range(6):
        center = (int(rnd.randint(100, width - 100)), int(rnd.randint(100, height - 100)))
        color = tuple(int(v) for v in rnd.randint(40, 230, 3))
        cv2.circle(base, center, int(rnd.randint(40, 120)), color, -1)
    base += rnd.normal(0, 6, base.shape)
    base = cv2.GaussianBlur(base, (0, 0), 3)
    return Image.fromarray(np.clip(base, 0, 255).astype(np.uint8))



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
    card = card_image()
    draw_signature(card)
    _save(card, out / "card.png", "PNG")
    _save(qr_image(VCARD), out / "qr.png", "PNG")
    _save(photo_image(), out / "photo.png", "PNG")
    (out / "scan.pdf").write_bytes(scan_pdf(SCAN_PAGES))
    (out / "text.pdf").write_bytes(text_pdf())


if __name__ == "__main__":
    main(Path(sys.argv[1]))
