#!/usr/bin/env python3
"""Запуск перешифрования из рабочей копии (в контейнере: python -m pseudonymizer.rekey)."""

import sys

from pseudonymizer.rekey import main

if __name__ == "__main__":
    sys.exit(main())
