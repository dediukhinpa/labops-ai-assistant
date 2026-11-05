#!/usr/bin/env python3
"""Юнит-тест pii_forget.py на фикстурах во временном каталоге (живые данные не нужны).

Проверяет: поиск, dry-run ничего не меняет, apply удаляет только нужного
собеседника, бэкап создан с chmod 700, просроченный бэкап чистится, отчёт без ПДн.
"""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import stat
import sys
import tempfile
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
_SPEC = importlib.util.spec_from_file_location("pii_forget", HERE / "pii_forget.py")
assert _SPEC is not None and _SPEC.loader is not None
pf = importlib.util.module_from_spec(_SPEC)
sys.modules["pii_forget"] = pf
_SPEC.loader.exec_module(pf)

SUBJECT = "777000111"
OTHER = "555000222"
GROUP = "-1009990001"
SUBJECT_NAME = "Тестовый Субъект"
SECS_PER_DAY = 86400


def tag(chat: str, uid: str | None, name: str = "x") -> str:
    """Строка транскрипта с тегом канала, как её пишет CLI (кавычки экранированы)."""
    u = f' user_id=\\"{uid}\\"' if uid else ""
    body = f'<channel source=\\"telegram\\" chat_id=\\"{chat}\\"{u} user=\\"{name}\\">hi</channel>'
    return '{"type":"user","message":{"content":"' + body + '"}}\n'


def write(path: Path, text: str) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    return path


class PiiForgetTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.projects = self.root / "projects"
        self.ws = self.root / "agent" / ".claude"
        self.listener = self.root / "listener"
        self.backup = self.root / "bk"
        proj = self.projects / "-proj"
        self.pure = write(proj / "aaaa.jsonl", tag(SUBJECT, SUBJECT) * 2)
        write(proj / "aaaa" / "tool-results" / "r.txt", "x")
        self.pure_dir = proj / "aaaa"
        self.mixed = write(
            proj / "bbbb.jsonl",
            tag(SUBJECT, SUBJECT) + tag(OTHER, OTHER) + '{"type":"assistant"}\n',
        )
        self.foreign = write(proj / "cccc.jsonl", tag(OTHER, OTHER) + tag(GROUP, "9"))
        self.dm_dir = write(self.ws / "chats" / SUBJECT / "persona.md", "p").parent
        self.other_dir = write(self.ws / "chats" / OTHER / "persona.md", "p").parent
        mc = self.ws / "state" / "multichat" / "chats" / SUBJECT / "w.log"
        self.mc_dir = write(mc, "x").parent
        write(self.ws / "state" / "multichat" / "sessions.json", json.dumps({SUBJECT: 1, OTHER: 2}))
        self.log = write(
            self.ws / "logs" / "server.log",
            f"a chat={SUBJECT}\nb chat={OTHER}\nc id=-100{SUBJECT}9\n",
        )
        self.run_sub = write(self.listener / "dev" / "1_t.log", f"task for {SUBJECT}")
        self.run_other = write(self.listener / "dev" / "2_t.log", f"task for {OTHER}")

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def run_cli(self, *extra: str) -> dict:
        report = self.root / "report.json"
        argv = [
            "--user-id", SUBJECT, "--projects-dir", str(self.projects),
            "--workspace", str(self.ws), "--listener-log-dir", str(self.listener),
            "--backup-dir", str(self.backup), "--report", str(report), *extra,
        ]
        self.assertEqual(pf.main(argv), 0)
        return json.loads(report.read_text(encoding="utf-8"))

    def test_dry_run_finds_but_changes_nothing(self) -> None:
        before = {p: p.read_bytes() for p in self.root.rglob("*") if p.is_file()}
        rep = self.run_cli()
        after = {p: p.read_bytes() for p in before if p.is_file()}
        self.assertEqual(before, {p: after[p] for p in before})
        self.assertFalse(self.backup.exists())
        c = rep["counts"]
        self.assertEqual(rep["mode"], "dry-run")
        self.assertEqual(c["sessions_whole"], 1)
        self.assertEqual(c["sessions_mixed_lines"], 1)
        self.assertEqual(c["chat_dirs"], 2)
        self.assertEqual(c["multichat_session_entries"], 1)
        self.assertEqual(c["log_lines"], 1)
        self.assertEqual(c["listener_run_logs"], 1)

    def test_apply_removes_only_subject(self) -> None:
        rep = self.run_cli("--apply")
        self.assertFalse(self.pure.exists())
        self.assertFalse(self.pure_dir.exists())
        self.assertTrue(self.foreign.exists())
        self.assertEqual(self.foreign.read_text(encoding="utf-8").count("<channel"), 2)
        mixed = self.mixed.read_text(encoding="utf-8")
        self.assertNotIn(SUBJECT, mixed)
        self.assertIn(OTHER, mixed)
        self.assertIn('"type":"assistant"', mixed)
        self.assertFalse(self.dm_dir.exists())
        self.assertFalse(self.mc_dir.exists())
        self.assertTrue(self.other_dir.exists())
        sessions = json.loads((self.ws / "state/multichat/sessions.json").read_text())
        self.assertEqual(sessions, {OTHER: 2})
        left = self.log.read_text(encoding="utf-8")
        self.assertNotIn(f"chat={SUBJECT}", left)
        self.assertIn(OTHER, left)
        self.assertIn(f"-100{SUBJECT}9", left)  # чужой чат с похожими цифрами цел
        self.assertFalse(self.run_sub.exists())
        self.assertTrue(self.run_other.exists())
        self.assertEqual(rep["counts"]["backup_ttl_days"], pf.DEFAULT_BACKUP_TTL_DAYS)

    def test_backup_created_private_with_expiry(self) -> None:
        self.run_cli("--apply")
        dirs = list(self.backup.iterdir())
        self.assertEqual(len(dirs), 1)
        self.assertEqual(stat.S_IMODE(os.stat(self.backup).st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(os.stat(dirs[0]).st_mode), 0o700)
        expires = int((dirs[0] / pf.EXPIRES_FILE).read_text())
        self.assertGreater(expires, time.time())
        manifest = json.loads((dirs[0] / pf.MANIFEST_FILE).read_text())
        saved = {Path(m["orig"]).name for m in manifest}
        self.assertIn("aaaa.jsonl", saved)
        copies = [p for p in dirs[0].iterdir() if p.name.endswith("aaaa.jsonl")]
        self.assertIn(SUBJECT, copies[0].read_text(encoding="utf-8"))

    def test_report_has_no_pii(self) -> None:
        self.run_cli("--apply", "--name", SUBJECT_NAME)
        text = (self.root / "report.json").read_text(encoding="utf-8")
        self.assertNotIn(SUBJECT, text)
        self.assertNotIn(SUBJECT_NAME, text)
        self.assertIn(hashlib.sha256(SUBJECT.encode()).hexdigest()[:12], text)

    def test_drop_mixed_removes_whole_session(self) -> None:
        self.run_cli("--apply", "--drop-mixed")
        self.assertFalse(self.mixed.exists())

    def test_purge_expired_backups(self) -> None:
        old = self.backup / "old"
        fresh = self.backup / "fresh"
        foreign = self.backup / "foreign"
        for d, exp in ((old, 100), (fresh, int(time.time()) + SECS_PER_DAY)):
            d.mkdir(parents=True)
            (d / pf.EXPIRES_FILE).write_text(str(exp))
        foreign.mkdir()
        self.assertEqual(pf.purge_expired_backups(self.backup), 1)
        self.assertFalse(old.exists())
        self.assertTrue(fresh.exists())
        self.assertTrue(foreign.exists())

    def test_bad_user_id_rejected(self) -> None:
        self.assertEqual(pf.main(["--user-id", "abc"]), 2)


if __name__ == "__main__":
    unittest.main()
