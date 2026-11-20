"""Тесты разбора потока событий поиска (без сети)."""

import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

import search  # noqa: E402


def sse(*events: dict) -> list[str]:
    """Собирает строки потока: событие -> строка data:."""
    return [f"data: {json.dumps(e, ensure_ascii=False)}" for e in events]


class ParseSseTest(unittest.TestCase):
    def test_collects_text_queries_and_unique_sources(self) -> None:
        lines = sse(
            {"type": "response.output_item.done",
             "item": {"type": "web_search_call", "action": {"query": "новости"}}},
            {"type": "response.output_text.delta", "delta": "Привет, "},
            {"type": "response.output_text.delta", "delta": "мир"},
            {"type": "response.output_item.done", "item": {"type": "message", "content": [
                {"annotations": [
                    {"title": "AP", "url": "https://apnews.com/a"},
                    {"title": "AP again", "url": "https://apnews.com/a"},
                    {"title": "", "url": "https://b.example/x"},
                ]}]}},
        )
        result = search.parse_sse(lines)
        self.assertEqual(result.text, "Привет, мир")
        self.assertEqual(result.queries, ["новости"])
        self.assertEqual(result.sources, [("AP", "https://apnews.com/a"),
                                          ("https://b.example/x", "https://b.example/x")])

    def test_reports_backend_error(self) -> None:
        result = search.parse_sse(sse({"type": "error", "error": {"message": "лимит"}}))
        self.assertIn("лимит", result.error)

    def test_ignores_noise_lines(self) -> None:
        result = search.parse_sse(["event: x", "", "data: не json", *sse({"type": "ping"})])
        self.assertEqual(result.text, "")
        self.assertEqual(result.error, "")

    def test_format_puts_sources_after_answer(self) -> None:
        text = search.format_result(search.SearchResult(text="ответ", sources=[("T", "https://u")]))
        self.assertEqual(text, "ответ\n\nИсточники:\n- T: https://u")


class EnvFileTest(unittest.TestCase):
    def test_reads_values_without_quotes(self) -> None:
        path = Path(self.id() + ".env")
        try:
            path.write_text("A=1\n# c\nB='два'\n", encoding="utf-8")
            self.assertEqual(search.read_env_file(path), {"A": "1", "B": "два"})
        finally:
            path.unlink(missing_ok=True)

    def test_missing_file_is_empty(self) -> None:
        self.assertEqual(search.read_env_file(Path("/нет/такого")), {})


if __name__ == "__main__":
    unittest.main()
