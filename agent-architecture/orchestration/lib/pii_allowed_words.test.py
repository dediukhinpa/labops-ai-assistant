#!/usr/bin/env python3
"""Тесты lib/pii_allowed_words.py: имена агентов в исключениях маскирования ПДн."""

from __future__ import annotations

import importlib.util
import os
import stat
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("paw", HERE / "pii_allowed_words.py")
assert spec and spec.loader
paw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(paw)

SWARM = [
    ("elpablo", "# El'Pablo — Coder & Architect"),
    ("marketer", "# Marketer -- Content & Research for Three Products"),
    ("rodriguez", "# Rodriguez -- Content Producer (turnkey)"),
]


class WordsTest(unittest.TestCase):
    def test_cyrillic_spellings_operator_uses(self) -> None:
        words = paw.swarm_words(SWARM)
        # Так оператор пишет и так их расшифровывает голос
        for w in ("пабло", "родригес", "родригуез", "маркетер", "эльпабло"):
            self.assertIn(w, words)

    def test_latin_words_from_id_and_heading(self) -> None:
        words = paw.swarm_words(SWARM)
        for w in ("elpablo", "pablo", "marketer", "rodriguez"):
            self.assertIn(w, words)

    def test_heading_description_is_not_taken(self) -> None:
        words = paw.swarm_words(SWARM)
        for w in ("content", "research", "products", "coder", "architect", "turnkey"):
            self.assertNotIn(w, words)

    def test_short_words_are_skipped(self) -> None:
        # «El» и «ai» как основы разрешили бы любое слово на «эл…»
        self.assertNotIn("el", paw.swarm_words(SWARM))
        self.assertEqual(paw.swarm_words([("ai", "# AI")]), [])

    def test_variants_are_bounded_and_main_first(self) -> None:
        v = paw.cyrillic_variants("rodriguez")
        self.assertEqual(v[0], "родригес")
        self.assertLessEqual(len(v), paw.MAX_VARIANTS)
        self.assertEqual(paw.cyrillic_variants("silvio")[0], "сильвио")


    def test_speech_vowel_reduction_variant(self) -> None:
        # Расшифровка голоса пишет «Радригес»: модель не узнавала агента (24.11.2026)
        self.assertIn("радригес", paw.swarm_words([("rodriguez", "")]))
        self.assertLessEqual(len(paw.reduced_variants("родригес")), paw.MAX_REDUCED)


class ProductsTest(unittest.TestCase):
    def test_products_list_has_speech_spellings(self) -> None:
        # «Клод», «Антропик» из голосовых прятались как ФИО («Диана says Claude», 24.11.2026)
        words = paw.product_words()
        for word in ("клод", "антропик", "гемини", "дипсик", "битрикс"):
            self.assertIn(word, words)

    def test_products_list_is_clean(self) -> None:
        words = paw.product_words()
        self.assertEqual(len(words), len(set(words)))
        for word in words:
            self.assertGreaterEqual(len(word), paw.MIN_WORD_LEN, word)
            self.assertRegex(word, r"^[а-я-]+$", word)
        # Имена людей сюда не попадают: их маскирование правильное
        for person in ("маск", "альтман", "алиса", "маруся"):
            self.assertNotIn(person, words)

    def test_auto_words_join_agents_and_products(self) -> None:
        words = paw.auto_words([("rodriguez", "")])
        self.assertIn("родригес", words)
        self.assertIn("клод", words)

    def test_comments_and_short_lines_skipped(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "p.txt"
            path.write_text("# коммент\nклод  # Claude\nзум\n\nГемини\n", encoding="utf-8")
            self.assertEqual(paw.product_words(path), ["клод", "гемини"])


class SyncTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.env = Path(self.tmp.name) / "pseudonymizer.env"

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def read(self) -> dict[str, str]:
        out = {}
        for line in self.env.read_text(encoding="utf-8").splitlines():
            k, _, v = line.partition("=")
            out[k] = v
        return out

    def test_manual_words_kept_stale_auto_removed(self) -> None:
        self.env.write_text("PSEUDONYMIZER_PORT=8300\nPII_ALLOWED_WORDS=штурман,labops\n",
                            encoding="utf-8")
        self.assertTrue(paw.sync_env(self.env, ["pablo", "пабло", "tony", "тони"]))
        # Агента tony удалили: его слова уходят, ручные остаются
        self.assertTrue(paw.sync_env(self.env, ["pablo", "пабло"]))
        env = self.read()
        allowed = env["PII_ALLOWED_WORDS"].split(",")
        self.assertEqual(allowed, ["штурман", "labops", "pablo", "пабло"])
        self.assertEqual(env["PII_ALLOWED_WORDS_AUTO"], "pablo,пабло")
        self.assertEqual(env["PSEUDONYMIZER_PORT"], "8300")

    def test_idempotent_and_private(self) -> None:
        self.env.write_text("PSEUDONYMIZER_PORT=8300\n", encoding="utf-8")
        self.assertTrue(paw.sync_env(self.env, ["pablo"]))
        self.assertFalse(paw.sync_env(self.env, ["pablo"]))
        self.assertEqual(stat.S_IMODE(os.stat(self.env).st_mode), 0o600)

    def test_manual_word_equal_to_auto_word_is_not_duplicated(self) -> None:
        # Оператор вписал «pablo» до автоматики: слово одно, дальше его ведёт автоматика
        self.env.write_text("PII_ALLOWED_WORDS=pablo\n", encoding="utf-8")
        paw.sync_env(self.env, ["pablo", "пабло"])
        self.assertEqual(self.read()["PII_ALLOWED_WORDS"], "pablo,пабло")

if __name__ == "__main__":
    unittest.main()
