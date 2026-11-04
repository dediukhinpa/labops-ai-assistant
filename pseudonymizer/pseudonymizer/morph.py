"""Нормализация ФИО: приведение слов к лемме, чтобы «Иванова» и «Иванов» совпали."""

from __future__ import annotations

import re
from collections.abc import Iterator
from contextlib import contextmanager
from contextvars import ContextVar
from dataclasses import dataclass, field
from functools import lru_cache

import pymorphy3
from pymorphy3.analyzer import Parse

WORD_RE = re.compile(r"[А-Яа-яЁёA-Za-z]+(?:-[А-Яа-яЁёA-Za-z]+)*")
NAME_GRAMMEMES = ("Surn", "Name", "Patr")
LEMMA_CACHE_SIZE = 4096
MIN_FILE_NAME_LEN = 3  # короче — инициалы и предлоги, в именах файлов ФИО не ищем


@lru_cache(maxsize=1)
def _analyzer() -> pymorphy3.MorphAnalyzer:
    """Лениво создаёт морфологический анализатор (загрузка словаря ~сотни мс)."""
    return pymorphy3.MorphAnalyzer()


@lru_cache(maxsize=LEMMA_CACHE_SIZE)
def _parse_cached(lowered: str) -> tuple[Parse, ...]:
    """Разбор слова pymorphy с кэшем (R5-PY-2): parse стоит ~0.75 мс на слово.

    Возвращает кортеж, а не список: значение лежит в общем кэше и вызывающий не должен
    его менять. Объекты Parse неизменяемы (namedtuple), предикаты только читают их.

    Args:
        lowered: Слово в нижнем регистре, «ё» заменена на «е».
    """
    return tuple(_analyzer().parse(lowered))


@dataclass(slots=True)
class _RequestMemo:
    """Разборы и ключи ФИО одного запроса (R9-A4-08).

    Общий LRU на `LEMMA_CACHE_SIZE` слов при тексте больше ~4 000 разных слов вытесняет
    разбор до повторного обращения: детектор проходит по словам несколькими детекторами, и
    pymorphy звался на каждое слово заново (повтор плотного списка ФИО 70 000 знаков в том
    же треде - 9,2 с CPU при таймауте клиента 10 с). Память запроса живёт только до конца
    `detect`, поэтому не растит процесс навсегда, как вырос бы общий кэш на 65 536 слов.
    """

    parses: dict[str, tuple[Parse, ...]] = field(default_factory=dict)
    person_keys: dict[str, str] = field(default_factory=dict)


# Контекстная, а не глобальная: запросы идут параллельно в потоках одного процесса.
_request_memo: ContextVar[_RequestMemo | None] = ContextVar("morph_request_memo", default=None)


@contextmanager
def request_cache() -> Iterator[None]:
    """Включает память разборов и ключей ФИО на время одного запроса.

    Вложенный вызов пользуется памятью внешнего. Без контекста функции модуля работают
    как прежде, только через общий LRU.
    """
    if _request_memo.get() is not None:
        yield
        return
    token = _request_memo.set(_RequestMemo())
    try:
        yield
    finally:
        _request_memo.reset(token)


def _parse(lowered: str) -> tuple[Parse, ...]:
    """Разбор слова: сначала память запроса, затем общий LRU `_parse_cached`.

    Args:
        lowered: Слово в нижнем регистре, «ё» заменена на «е».
    """
    memo = _request_memo.get()
    if memo is None:
        return _parse_cached(lowered)
    parses = memo.parses.get(lowered)
    if parses is None:
        parses = _parse_cached(lowered)
        memo.parses[lowered] = parses
    return parses


@lru_cache(maxsize=LEMMA_CACHE_SIZE)
def lemma(word: str) -> str:
    """Возвращает лемму слова, предпочитая разбор «фамилия/имя/отчество».

    Args:
        word: Слово в любом падеже.

    Returns:
        Лемма в нижнем регистре (для инициалов — одна буква).
    """
    lowered = word.lower().replace("ё", "е")
    if len(lowered) == 1:
        return lowered
    parses = _parse(lowered)
    named = [p for p in parses if any(g in p.tag for g in NAME_GRAMMEMES)]
    # Разбор во множественном числе пропускается (R9-A4-06): у «Борисов», «Семенов»,
    # «Абрамов» первым идёт «Борис/Семён/Абрам, мн.ч. род.п.», и лемма именительного падежа
    # выходила «борис», а косвенных («Борисова», «Борисову») — «борисов». Страховка
    # known_lemmas тогда не ловила фамилию в косвенном падеже, а формы одного человека
    # получали разные ключи и токены. Слово только с разборами мн.ч. («Ивановы») — как раньше.
    best = next((p for p in named if "plur" not in p.tag), named[0] if named else None)
    if best is not None:
        return best.normal_form.replace("ё", "е")
    return parses[0].normal_form.replace("ё", "е") if parses else lowered


# Род в ключе ФИО хранится служебным «словом» с этим префиксом: он не буква и не часть леммы,
# поэтому обычные слова ключа (known_lemmas, индекс) его не путают, а старые ключи без него
# остаются совместимыми с любым родом.
GENDER_PREFIX = "\x01"
GENDER_MALE = "m"
GENDER_FEMALE = "f"
PATRONYM_MALE_ENDINGS = ("ович", "евич", "ьич", "ич")
PATRONYM_FEMALE_ENDINGS = ("овна", "евна", "ична", "инична", "ьична")
# Окончания женской формы фамилии на -ов/-ев/-ин/-ын: «Ивановой». «Иванову» сюда не входит
# (мужской дательный или женский винительный): без уверенности рода нет.
SURNAME_FEMALE_SUFFIXES = frozenset({"ой"})
# «Иванова» — женский именительный или мужской родительный/винительный (R9-A4-07). Без
# других признаков форма по-прежнему считается женской (R3-ALG-14: «Иванова И.И.» не
# сливается с «Ивановым И.И.»), но её снимают признаки мужского косвенного падежа:
# предлог перед ФИО (см. `with_preposition_gender`) или имя, которое тоже может быть
# мужским родительным («Петрова Александра», «Петрова Дмитрия»).
SURNAME_AMBIGUOUS_SUFFIX = "а"
# Служебная метка голоса фамилии на «-а»; в ключ не попадает.
_SURNAME_FEMALE_OR_MALE_OBLIQUE = "f?"
# Падежи, в которых мужское имя совпадает по форме с женским именительным («Александра»).
_MALE_OBLIQUE_CASES = ("gent", "accs")
ADJ_SURNAME_FEMALE_SUFFIXES = frozenset({"ая", "яя", "ой", "ей", "ую", "юю"})
ADJ_SURNAME_ENDINGS = ("ий", "ый", "ой")
# Фамилии с этими окончаниями меняются по родам: совпадение формы с леммой значит мужской род
SURNAME_MALE_ENDINGS = ("ов", "ев", "ёв", "ин", "ын", "ский", "цкий", "ой", "ий", "ый")


@lru_cache(maxsize=LEMMA_CACHE_SIZE)
def _name_vote(word: str) -> str | None:
    """Род по имени или отчеству: только если все разборы слова согласны."""
    lowered = word.lower().replace("ё", "е")
    if len(lowered) <= 1:  # инициал: рода не несёт, разбор не нужен
        return None
    if len(lowered) > MIN_FILE_NAME_LEN:
        if lowered.endswith(PATRONYM_FEMALE_ENDINGS):
            return GENDER_FEMALE
        if lowered.endswith(PATRONYM_MALE_ENDINGS):
            return GENDER_MALE
    genders = {
        g
        for p in _parse(lowered)
        if "Name" in p.tag
        for g in (GENDER_MALE if "masc" in p.tag else GENDER_FEMALE if "femn" in p.tag else "",)
        if g
    }
    return genders.pop() if len(genders) == 1 else None


@lru_cache(maxsize=LEMMA_CACHE_SIZE)
def _surname_vote(word: str) -> str | None:
    """Род по форме фамилии относительно её леммы (мужская начальная форма или женская)."""
    lowered = word.lower().replace("ё", "е")
    if len(lowered) <= 1:
        return None
    surn = next((p for p in _parse(lowered) if "Surn" in p.tag), None)
    if surn is None:
        return None
    base = surn.normal_form.replace("ё", "е")
    if lowered == base:
        return GENDER_MALE if base.endswith(SURNAME_MALE_ENDINGS) else None
    adjectival = base.endswith(ADJ_SURNAME_ENDINGS)
    stem = base[:-2] if adjectival else base
    if not lowered.startswith(stem):
        return None
    suffix = lowered[len(stem):]
    if not adjectival and suffix == SURNAME_AMBIGUOUS_SUFFIX:
        return _SURNAME_FEMALE_OR_MALE_OBLIQUE
    female = ADJ_SURNAME_FEMALE_SUFFIXES if adjectival else SURNAME_FEMALE_SUFFIXES
    return GENDER_FEMALE if suffix in female else GENDER_MALE


@lru_cache(maxsize=LEMMA_CACHE_SIZE)
def _likely_male_oblique_name(word: str) -> bool:
    """Говорит, что имя скорее мужское в родительном/винительном падеже, чем женское.

    «Александра», «Дмитрия», «Артёма» — у pymorphy есть и мужской косвенный, и женский
    именительный разбор, поэтому `_name_vote` рода не даёт. Рядом с фамилией на «-а»
    («Петрова Александра») оба прочтения согласованы по падежу. Решает частота разборов:
    «Юлия», «Валентина» (формально и «Юлий», «Валентин» в род. п.) остаются женскими.
    """
    lowered = word.lower().replace("ё", "е")
    if len(lowered) <= 1:
        return False
    male_oblique = female_nominative = 0.0
    for p in _parse(lowered):
        if "Name" not in p.tag:
            continue
        if "masc" in p.tag and any(c in p.tag for c in _MALE_OBLIQUE_CASES):
            male_oblique += p.score
        elif "femn" in p.tag and "nomn" in p.tag:
            female_nominative += p.score
    return male_oblique > female_nominative


def gender_of(words: list[str], after_preposition: bool = False) -> str | None:
    """Определяет род человека по словам ФИО или None, если уверенности нет.

    Сильные признаки (отчество, имя) главнее формы фамилии; если они спорят, рода нет.

    Args:
        words: Слова ФИО (инициалы допускаются, рода они не несут).
        after_preposition: Перед ФИО стоит предлог. Женская фамилия на «-а» бывает только
            в именительном падеже, а после предлога его нет: «от Петрова» — мужчина.
    """
    strong = {v for w in words if (v := _name_vote(w))}
    if strong:
        return strong.pop() if len(strong) == 1 else None
    weak = {v for w in words if (v := _surname_vote(w))}
    if _SURNAME_FEMALE_OR_MALE_OBLIQUE in weak:
        weak.discard(_SURNAME_FEMALE_OR_MALE_OBLIQUE)
        if after_preposition:
            weak.add(GENDER_MALE)
        elif not any(_likely_male_oblique_name(w) for w in words):
            weak.add(GENDER_FEMALE)  # прежнее поведение (R3-ALG-14)
        # иначе («Петрова Александра») форма фамилии голоса не даёт: решают остальные слова
    return weak.pop() if len(weak) == 1 else None


def split_key(key: str) -> tuple[list[str], str | None]:
    """Разбирает ключ ФИО на слова (леммы и инициалы) и род (или None)."""
    words: list[str] = []
    gender: str | None = None
    for part in key.split():
        if part.startswith(GENDER_PREFIX):
            gender = part[len(GENDER_PREFIX):] or None
        else:
            words.append(part)
    return words, gender


def person_key(text: str) -> str:
    """Строит ключ ФИО: отсортированные леммы слов через пробел и род, если он известен.

    Порядок слов не важен («Иванов Иван» == «Иван Иванов»); падеж не важен. Род отделяет
    «Иванов И.И.» от «Иванова И.И.»: раньше обе записи сливались в один токен, и /restore
    возвращал женщине написание мужчины (R3-ALG-14).
    """
    memo = _request_memo.get()
    if memo is not None:
        known = memo.person_keys.get(text)
        if known is not None:
            return known
    raw = WORD_RE.findall(text)
    parts = sorted(lemma(w) for w in raw)
    gender = gender_of(raw)
    if gender:
        parts.append(f"{GENDER_PREFIX}{gender}")
    key = " ".join(parts)
    if memo is not None:
        memo.person_keys[text] = key
    return key


def with_preposition_gender(key: str, text: str) -> str:
    """Уточняет род ключа ФИО, перед которым в тексте стоит предлог (R9-A4-07).

    «Нет ответа от Петрова»: без контекста форма «Петрова» считается женской, и мужчина
    в треде получал второй токен. Меняется только пометка рода, леммы ключа остаются.

    Args:
        key: Ключ, построенный `person_key` по тому же фрагменту.
        text: Фрагмент текста ФИО (без предлога).

    Returns:
        Ключ с уточнённым родом (или тот же ключ, если уточнять нечего).
    """
    words, gender = split_key(key)
    if gender != GENDER_FEMALE:
        return key
    refined = gender_of(WORD_RE.findall(text), after_preposition=True)
    if refined == gender:
        return key
    if refined:
        words.append(f"{GENDER_PREFIX}{refined}")
    return " ".join(words)


def keys_compatible(first: str, second: str) -> bool:
    """Решает, относятся ли два ключа ФИО к одному человеку.

    Совпадают, если полные слова одного ключа входят в другой и первые буквы
    всех слов (инициалы) одного — подмножество букв другого. Так «Иванов И.»
    и «Иванов Иван» — один человек, а «Иванов И.» и «Иванов Пётр» — разные.
    Известные и разные роды несовместимы; ключ без рода совместим с любым.
    """
    words_a, gender_a = split_key(first)
    words_b, gender_b = split_key(second)
    if gender_a and gender_b and gender_a != gender_b:
        return False
    full_a = {w for w in words_a if len(w) > 1}
    full_b = {w for w in words_b if len(w) > 1}
    if not full_a or not full_b:
        return False
    if not (full_a <= full_b or full_b <= full_a):
        return False
    letters_a = sorted(w[0] for w in words_a)
    letters_b = sorted(w[0] for w in words_b)
    small, large = sorted((letters_a, letters_b), key=len)
    pool = list(large)
    for letter in small:
        if letter not in pool:
            return False
        pool.remove(letter)
    return True


NON_NAME_POS = frozenset(
    {"VERB", "INFN", "PRTF", "PRTS", "GRND", "ADVB", "PRCL", "CONJ", "PREP", "NPRO", "INTJ",
     "PRED", "COMP"}
)


def is_non_name_word(word: str) -> bool:
    """Говорит, что слово точно не часть ФИО (глагол, предлог и т.п.).

    Нужно, чтобы отсечь ложный захват NER вроде «Позвони Петрову».
    Инициалы (одна буква) за имя не считаются.
    """
    lowered = word.lower().replace("ё", "е")
    if len(lowered) <= 1:
        return False
    parses = _parse(lowered)
    if any(g in p.tag for p in parses for g in NAME_GRAMMEMES):
        return False
    return bool(parses) and parses[0].tag.POS in NON_NAME_POS


def is_inanimate_common_noun(word: str) -> bool:
    """Говорит, что слово — словарное неодушевлённое существительное, не имя и не фамилия.

    Так отсекаются названия компаний и вещей («Металлопрокат», «Сибирь», «Прайс»),
    которые NER иногда принимает за ФИО. Одушевлённые слова («Мельник», «Заяц» — они же
    фамилии) и любые слова с разбором «фамилия/имя/отчество» под фильтр не попадают.
    """
    lowered = word.lower().replace("ё", "е")
    if len(lowered) <= 1:
        return False
    parses = _parse(lowered)
    if not parses or not all(p.is_known and p.tag.POS == "NOUN" for p in parses):
        return False
    return not any(
        g in p.tag for p in parses for g in (*NAME_GRAMMEMES, "anim")
    )


def is_surname_candidate(word: str) -> bool:
    """Говорит, что слово рядом с двумя инициалами можно считать фамилией.

    Мягче `is_person_word`: хватает любого разбора «фамилия» («Черных», «Шмидт», у которых
    главный разбор другой) или полного отсутствия слова в словаре (иностранная фамилия).
    Сами инициалы «О.И.» — сильный признак ФИО, поэтому строгий главный разбор не нужен;
    словарные слова без разбора «фамилия» («Согласовано», «Директор») не проходят.
    """
    lowered = word.lower().replace("ё", "е")
    if len(lowered) < MIN_FILE_NAME_LEN:
        return False
    parses = _parse(lowered)
    if not parses:
        return False
    return any("Surn" in p.tag for p in parses) or not any(p.is_known for p in parses)


def is_person_word(word: str) -> bool:
    """Говорит, что слово — фамилия/имя/отчество по главному разбору pymorphy.

    Используется внутри имён файлов и путей, где нет контекста для NER: слово считается
    ФИО, только если лучший разбор одушевлённый «фамилия/имя/отчество». Словарные слова
    («Договор», «Счёт», «Прайс», «Август») и неоднозначные («Надежда», «Вера») не проходят.
    """
    lowered = word.lower().replace("ё", "е")
    if len(lowered) < MIN_FILE_NAME_LEN:
        return False
    parses = _parse(lowered)
    if not parses:
        return False
    best = parses[0]
    return any(g in best.tag for g in NAME_GRAMMEMES) and "anim" in best.tag


@lru_cache(maxsize=LEMMA_CACHE_SIZE)
def name_gramme(word: str) -> str | None:
    """Возвращает грамему «Surn»/«Name»/«Patr» главного разбора одушевлённого слова.

    Для слов вне ФИО (и для коротких слов) возвращает None. Регистр слова не важен.
    """
    lowered = word.lower().replace("ё", "е")
    if len(lowered) < MIN_FILE_NAME_LEN:
        return None
    parses = _parse(lowered)
    if not parses or "anim" not in parses[0].tag:
        return None
    return next((g for g in NAME_GRAMMEMES if g in parses[0].tag), None)
