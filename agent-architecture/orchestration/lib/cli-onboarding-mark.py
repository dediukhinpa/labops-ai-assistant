#!/usr/bin/env python3
"""Отметить онбординг Claude Code пройденным в конфиге текущего пользователя.

Вызывается из ``cli_version_mark_onboarding_done`` (lib/cli-version.sh) перед
каждым стартом агентской сессии. Зачем это нужно и почему каждый раз — см.
комментарий у вызывающей функции.

Окружение:
    CFG: путь к ``~/.claude.json``.
    VERSION: версия установленного CLI, которую записываем меткой.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path
from typing import Any


def mark_done(config: Path, version: str) -> bool:
    """Проставить метку пройденного онбординга.

    Args:
        config: Файл конфигурации Claude Code.
        version: Версия установленного CLI.

    Returns:
        True, если файл переписан; False, если конфиг нечитаем.
    """
    try:
        data: dict[str, Any] = json.loads(config.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        # Битый или недоступный конфиг не чиним и не затираем: его настоящее
        # содержимое знает только сам CLI, а пустой словарь здесь стоил бы
        # оператору всех подтверждённых доверий к каталогам агентов.
        return False
    if not isinstance(data, dict):
        return False
    data["hasCompletedOnboarding"] = True
    data["lastOnboardingVersion"] = version
    # Пишем через временный файл в том же каталоге: конфиг общий на все сессии
    # хоста, и оборванная запись оставила бы соседям обрезанный JSON.
    tmp = config.with_name(config.name + ".tmp")
    tmp.write_text(json.dumps(data, indent=2), encoding="utf-8")
    os.replace(tmp, config)
    return True


def main() -> int:
    """Точка входа: читает CFG и VERSION из окружения."""
    config = os.environ.get("CFG", "")
    version = os.environ.get("VERSION", "")
    if not config or not version:
        return 0
    mark_done(Path(config), version)
    return 0


if __name__ == "__main__":
    sys.exit(main())
