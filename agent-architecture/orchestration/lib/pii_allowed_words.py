#!/usr/bin/env python3
"""Имена агентов роя в исключениях маскирования ПДн (PII_ALLOWED_WORDS сервиса).

Зачем: имя агента («Rodriguez», «Родригес») детектор принимает за ФИО и прячет под токеном.
Модель тогда не знает, о каком агенте речь: переспрашивает оператора («кто такой Радригес?»)
или ставит в ответ не тот токен, и при восстановлении в текст попадает чужой фрагмент
(рой Дианы, 24.11.2026). Имена агентов - не ПДн, поэтому они попадают в исключения сами:
латиница из agent-id и заголовка CLAUDE.md, плюс несколько вариантов кириллицы.

Слова, вписанные оператором вручную, не теряются: прошлый автоматический набор хранится в
PII_ALLOWED_WORDS_AUTO, при пересчёте убирается только он и добавляется новый.

    pii_allowed_words.py sync <env-файл> <агент>[=<заголовок CLAUDE.md>] ...
        печатает changed / unchanged (код 0); env-файл переписывается атомарно, права 600.
    pii_allowed_words.py words <агент>[=<заголовок>] ...
        печатает слова через запятую (для проверки руками).
"""

from __future__ import annotations

import itertools
import os
import re
import sys
import tempfile
from pathlib import Path

ALLOWED_KEY = "PII_ALLOWED_WORDS"
AUTO_KEY = "PII_ALLOWED_WORDS_AUTO"
# Короче - слишком общие основы: «tony» → «тони» ещё ладно, «el», «ai» разрешили бы мусор.
# Сервис разрешает основу плюс до 3 букв окончания, поэтому короткая основа опасна.
MIN_WORD_LEN = 4
# Вариантов кириллицы на одно слово не больше: каждая лишняя основа - лишнее исключение.
MAX_VARIANTS = 6
# Предел перебора развилок одного слова (защита от длинного имени с десятком развилок)
MAX_COMBOS = 4096
# Заголовок CLAUDE.md: «# El'Pablo — Coder & Architect» - имя до первого разделителя.
HEADING_SPLIT_RE = re.compile(r"\s+(?:—|–|--|-|:|\|)\s+|:\s")
LATIN_WORD_RE = re.compile(r"[a-z]+")
VOWELS = set("aeiouy")

# Транслитерация латиницы в кириллицу. Варианты по порядку: первый - основной, остальные -
# как имя часто пишут или слышат по-русски (Rodriguez → «родригес» и «родригуез»).
DIGRAPHS: list[tuple[str, list[str]]] = [
    ("sch", ["ш"]),
    ("tch", ["ч"]),
    ("sh", ["ш"]),
    ("ch", ["ч", "к"]),
    ("zh", ["ж"]),
    ("kh", ["х"]),
    ("ph", ["ф"]),
    ("th", ["т"]),
    ("ck", ["к"]),
    ("qu", ["кв"]),
    ("tz", ["ц"]),
    ("ts", ["ц", "тс"]),
    ("ya", ["я"]),
    ("yu", ["ю"]),
    ("yo", ["е"]),
    ("ee", ["и"]),
    ("oo", ["у"]),
    ("ou", ["у"]),
    ("ll", ["л", "лл"]),
    ("ss", ["сс", "с"]),
    ("ff", ["фф", "ф"]),
    ("tt", ["тт", "т"]),
    ("mm", ["мм", "м"]),
    ("nn", ["нн", "н"]),
    ("rr", ["р", "рр"]),
]
SINGLE: dict[str, list[str]] = {
    "a": ["а"], "b": ["б"], "d": ["д"], "f": ["ф"], "g": ["г"], "h": ["х"], "i": ["и"],
    "j": ["дж", "х"], "k": ["к"], "l": ["л"], "m": ["м"], "n": ["н"], "o": ["о"], "p": ["п"],
    "q": ["к"], "r": ["р"], "s": ["с", "з"], "t": ["т"], "u": ["у"], "v": ["в"],
    "w": ["у", "в"], "x": ["кс"],
}


def _options(word: str) -> list[list[str]]:
    """Слово латиницей → по каждому звуку список вариантов кириллицы."""
    out: list[list[str]] = []
    i = 0
    while i < len(word):
        nxt = word[i + 1] if i + 1 < len(word) else ""
        # «gu» перед e/i - испанское «г» (Rodriguez, Guillermo); второй вариант - «гу»
        if word.startswith("gu", i) and word[i + 2:i + 3] in ("e", "i"):
            out.append(["г", "гу"])
            i += 2
            continue
        for latin, cyr in DIGRAPHS:
            if word.startswith(latin, i):
                out.append(cyr)
                i += len(latin)
                break
        else:
            ch = word[i]
            if ch == "c":
                out.append(["с"] if nxt in ("e", "i", "y") else ["к"])
            elif ch == "e":
                out.append(["э", "е"] if i == 0 else ["е"])
            elif ch == "y":
                out.append(["й"] if i == 0 or nxt in VOWELS or word[i - 1] in VOWELS
                           else ["и"])
            elif ch == "l" and nxt and nxt not in VOWELS:
                out.append(["ль", "л"])  # Silvio → «сильвио», El'Pablo → «эльпабло»
            elif ch == "z":
                out.append(["с", "з"] if i == len(word) - 1 else ["з", "с"])
            else:
                out.append(SINGLE.get(ch, [""]))
            i += 1
    return out


def cyrillic_variants(word: str) -> list[str]:
    """Варианты написания латинского имени кириллицей, основной - первый."""
    opts = _options(word.lower())
    # Сначала варианты с наименьшим числом отступлений от основного написания: «родригуез»
    # (одно отступление) важнее «родригэз» (два). Перебор индексов ограничен: слово имени
    # короткое, развилок в нём единицы.
    combos = itertools.islice(
        itertools.product(*(range(len(o)) for o in opts)), MAX_COMBOS)
    ranked = sorted(combos, key=lambda idx: (sum(1 for k in idx if k), idx))
    seen: dict[str, None] = {}
    for idx in ranked:
        seen.setdefault("".join(o[k] for o, k in zip(opts, idx)), None)
        if len(seen) >= MAX_VARIANTS:
            break
    return list(seen)


def name_words(agent_id: str, heading: str = "") -> list[str]:
    """Латинские слова имени агента: части agent-id и имя из заголовка CLAUDE.md."""
    words: list[str] = []
    words += agent_id.lower().split("-")
    title = heading.lstrip("#").strip()
    title = HEADING_SPLIT_RE.split(title, maxsplit=1)[0] if title else ""
    words += LATIN_WORD_RE.findall(title.lower())
    # Склеенное имя («El'Pablo» → «elpablo» уже из agent-id) и его части
    return [w for w in dict.fromkeys(words) if len(w) >= MIN_WORD_LEN]


def swarm_words(agents: list[tuple[str, str]]) -> list[str]:
    """Все слова-исключения роя: латиница и кириллические варианты, без повторов."""
    out: dict[str, None] = {}
    for agent_id, heading in agents:
        for word in name_words(agent_id, heading):
            out.setdefault(word, None)
            for cyr in cyrillic_variants(word):
                if len(cyr) >= MIN_WORD_LEN:
                    out.setdefault(cyr, None)
    return list(out)


def _split(value: str) -> list[str]:
    return [w.strip() for w in value.strip().strip("\"'").split(",") if w.strip()]


def _read_env(path: Path) -> tuple[list[str], dict[str, str]]:
    lines = path.read_text(encoding="utf-8").splitlines() if path.exists() else []
    values: dict[str, str] = {}
    for line in lines:
        key, sep, value = line.partition("=")
        if sep and key.strip() in (ALLOWED_KEY, AUTO_KEY):
            values[key.strip()] = value
    return lines, values


def sync_env(path: Path, auto: list[str]) -> bool:
    """Обновить PII_ALLOWED_WORDS в env-файле; True - файл изменился."""
    lines, values = _read_env(path)
    old_auto = {w.lower() for w in _split(values.get(AUTO_KEY, ""))}
    manual = [w for w in _split(values.get(ALLOWED_KEY, "")) if w.lower() not in old_auto]
    merged = list(dict.fromkeys([*manual, *auto]))
    new_values = {ALLOWED_KEY: ",".join(merged), AUTO_KEY: ",".join(auto)}
    out = [ln for ln in lines if ln.partition("=")[0].strip() not in new_values]
    out += [f"{k}={v}" for k, v in new_values.items()]
    text = "\n".join(out) + "\n"
    if path.exists() and path.read_text(encoding="utf-8") == text:
        return False
    # Атомарно: сервис может перечитывать файл при старте в любой момент
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise
    return True


def _parse_agents(args: list[str]) -> list[tuple[str, str]]:
    agents = []
    for arg in args:
        agent_id, _, heading = arg.partition("=")
        if agent_id:
            agents.append((agent_id, heading))
    return agents


def main(argv: list[str]) -> int:
    if len(argv) >= 2 and argv[0] == "words":
        print(",".join(swarm_words(_parse_agents(argv[1:]))))
        return 0
    if len(argv) >= 2 and argv[0] == "sync":
        changed = sync_env(Path(argv[1]), swarm_words(_parse_agents(argv[2:])))
        print("changed" if changed else "unchanged")
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
