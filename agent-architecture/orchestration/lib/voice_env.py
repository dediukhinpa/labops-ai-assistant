#!/usr/bin/env python3
"""Env-файл сервиса voice-transcriber и токен для агентов, без секрета в argv.

Установщик (lib/voice-install.sh) зовёт этот скрипт от root: токен генерируется и
переносится только через файлы, поэтому не появляется ни в командной строке, ни в
выводе. Повторная установка берёт токен из прежнего env-файла: новый токен молча
отключил бы голос у всех уже созданных агентов.

Команды:
    render <example> <out> <models_dir> [<existing_env>]
        Собрать env-файл из образца: свой VOICE_MODEL_DIR, токен прежний или новый.
    export-token <env> <out>
        Записать токен из env-файла в отдельный файл (для агентов).
"""

from __future__ import annotations

import logging
import os
import secrets
import sys
from pathlib import Path

TOKEN_KEY = "VOICE_TRANSCRIBER_API_TOKEN"
MODEL_DIR_KEY = "VOICE_MODEL_DIR"
# Сервис отвергает токен короче 32 знаков (voice_transcriber/config.py).
MIN_TOKEN_LENGTH = 32
# token_urlsafe(32) даёт 43 знака: с запасом выше минимума сервиса.
TOKEN_BYTES = 32
SECRET_FILE_MODE = 0o600
EXIT_USAGE = 2
EXIT_NO_TOKEN = 1

logger = logging.getLogger("voice_env")


def read_value(env_path: Path, key: str) -> str:
    """Возвращает значение ключа из env-файла или пустую строку.

    Args:
        env_path: Путь к env-файлу (строки KEY=VALUE).
        key: Имя переменной.

    Returns:
        Значение без пробелов по краям; пусто, если файла или ключа нет.
    """
    if not env_path.is_file():
        return ""
    prefix = f"{key}="
    for line in env_path.read_text(encoding="utf-8").splitlines():
        if line.startswith(prefix):
            return line[len(prefix):].strip()
    return ""


def write_secret(path: Path, text: str) -> None:
    """Пишет файл с правами 600, не оставляя окна с более широкими правами.

    Args:
        path: Куда писать.
        text: Содержимое.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, SECRET_FILE_MODE)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(text)
    os.chmod(path, SECRET_FILE_MODE)


def render(example: Path, out: Path, models_dir: str, existing: Path | None) -> None:
    """Собирает env-файл сервиса из образца.

    Args:
        example: voice-transcriber.env.example.
        out: Куда записать готовый env-файл.
        models_dir: Каталог весов моделей.
        existing: Прежний env-файл, из которого берётся токен (может отсутствовать).
    """
    token = read_value(existing, TOKEN_KEY) if existing else ""
    if len(token) < MIN_TOKEN_LENGTH:
        token = secrets.token_urlsafe(TOKEN_BYTES)
    lines = []
    for line in example.read_text(encoding="utf-8").splitlines():
        if line.startswith(f"{TOKEN_KEY}="):
            line = f"{TOKEN_KEY}={token}"
        elif line.startswith(f"{MODEL_DIR_KEY}="):
            line = f"{MODEL_DIR_KEY}={models_dir}"
        lines.append(line)
    write_secret(out, "\n".join(lines) + "\n")


def export_token(env_path: Path, out: Path) -> int:
    """Записывает токен сервиса в отдельный файл.

    Args:
        env_path: Готовый env-файл сервиса.
        out: Файл токена для агентов.

    Returns:
        0 при успехе, EXIT_NO_TOKEN, если токена в env-файле нет.
    """
    token = read_value(env_path, TOKEN_KEY)
    if len(token) < MIN_TOKEN_LENGTH:
        logger.error("в %s нет токена сервиса", env_path)
        return EXIT_NO_TOKEN
    write_secret(out, token)
    return 0


def main(argv: list[str]) -> int:
    """Точка входа командной строки.

    Args:
        argv: Аргументы без имени скрипта.

    Returns:
        Код выхода.
    """
    logging.basicConfig(level=logging.INFO, format="voice_env: %(message)s")
    if len(argv) in (4, 5) and argv[0] == "render":
        existing = Path(argv[4]) if len(argv) == 5 else None
        render(Path(argv[1]), Path(argv[2]), argv[3], existing)
        return 0
    if len(argv) == 3 and argv[0] == "export-token":
        return export_token(Path(argv[1]), Path(argv[2]))
    logger.error("использование: render <example> <out> <models_dir> [<existing>] | "
                 "export-token <env> <out>")
    return EXIT_USAGE


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
