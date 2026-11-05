#!/usr/bin/env python3
"""Удаление данных субъекта по его требованию (152-ФЗ, ст. 21).

Находит по Telegram user id (и, по желанию, имени) и удаляет:
  1. транскрипты сессий Claude Code (`~/.claude/projects/*/*.jsonl`);
  2. каталоги чатов per_person/multichat (`<ws>/chats/<id>`, `<ws>/state/multichat`);
  3. строки в журналах плагина и агента, журналы запусков webhook-listener;
  4. замены псевдонимизатора (`DELETE /threads/{session_id}`).
Заметки second-brain только перечисляются в отчёте как инструкция оператору.

По умолчанию dry-run: ничего не меняется. Отчёт не содержит ПДн: вместо id в нём
короткий хеш, вместо путей — счётчики.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import logging
import os
import re
import shutil
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path

LOG = logging.getLogger("pii-forget")

DEFAULT_BACKUP_TTL_DAYS = 7  # бэкап сам содержит ПДн, поэтому живёт недолго
SECONDS_PER_DAY = 86400
DIR_MODE = 0o700
FILE_MODE = 0o600
HASH_PREFIX_LEN = 12
HTTP_TIMEOUT_SEC = 10
HTTP_NO_CONTENT = 204
HTTP_NOT_FOUND = 404
BACKUP_ROOT_NAME = ".pii-forget-backups"
EXPIRES_FILE = "EXPIRES"
MANIFEST_FILE = "manifest.json"

# Тег канала в транскрипте: в JSON-строке кавычки экранированы (\").
CHANNEL_TAG_RE = re.compile(r"<channel\b((?:[^>\\]|\\.)*)>")
TAG_ATTR_RE = re.compile(r'(\w+)=(?:\\"|")([^"\\]*)(?:\\"|")')
LOG_SUFFIXES = (".log", ".jsonl")


@dataclass
class Subject:
    """Субъект: Telegram user id и необязательное имя из атрибута user тега."""

    user_id: str
    name: str | None = None
    extra_chat_ids: list[str] = field(default_factory=list)

    @property
    def ref(self) -> str:
        """Короткий хеш id для отчёта (сам id в отчёт не попадает)."""
        return hashlib.sha256(self.user_id.encode()).hexdigest()[:HASH_PREFIX_LEN]

    @property
    def id_re(self) -> re.Pattern[str]:
        """Целое число id без соседних цифр и без знака минус (иначе это чужой чат)."""
        return re.compile(rf"(?<![\d-]){re.escape(self.user_id)}(?!\d)")

    @property
    def reply_re(self) -> re.Pattern[str]:
        """Вызов инструмента ответа в чат субъекта (chat_id в input)."""
        return re.compile(rf'chat_id\\*"\s*:\s*\\*"?{re.escape(self.user_id)}(?!\d)')

    @property
    def owned_chat_ids(self) -> list[str]:
        """Чаты, целиком принадлежащие субъекту: личный (chat_id == user_id) и заданные."""
        return [self.user_id, *self.extra_chat_ids]


def classify_tags(line: str, subj: Subject) -> tuple[int, int]:
    """Посчитать теги канала в строке: (субъекта, чужие)."""
    mine = other = 0
    for match in CHANNEL_TAG_RE.finditer(line):
        attrs = dict(TAG_ATTR_RE.findall(match.group(1)))
        uid = attrs.get("user_id") or attrs.get("sender_id")
        if uid is not None:
            is_mine = uid == subj.user_id
        elif subj.name is not None and attrs.get("user"):
            is_mine = attrs["user"].casefold() == subj.name.casefold()
        else:
            is_mine = attrs.get("chat_id") in subj.owned_chat_ids
        if is_mine:
            mine += 1
        else:
            other += 1
    return mine, other


@dataclass
class SessionScan:
    """Итог разбора одного транскрипта."""

    path: Path
    subject_lines: list[int] = field(default_factory=list)
    other_tags: int = 0
    total_lines: int = 0

    @property
    def found(self) -> bool:
        return bool(self.subject_lines)

    @property
    def pure(self) -> bool:
        """Все теги канала в сессии — субъекта: можно удалять сессию целиком."""
        return self.found and self.other_tags == 0


def scan_session(path: Path, subj: Subject) -> SessionScan:
    """Прочитать транскрипт построчно и найти строки субъекта."""
    res = SessionScan(path=path)
    reply_re = subj.reply_re
    with path.open("r", encoding="utf-8", errors="replace") as fh:
        for num, line in enumerate(fh):
            res.total_lines += 1
            if "<channel" not in line and "chat_id" not in line:
                continue
            mine, other = classify_tags(line, subj)
            res.other_tags += other
            if mine or reply_re.search(line):
                res.subject_lines.append(num)
    return res


def scan_text_log(path: Path, subj: Subject) -> list[int]:
    """Номера строк журнала, где встречается id (или имя целым словом)."""
    pats = [subj.id_re]
    if subj.name:
        pats.append(re.compile(rf"(?<!\w){re.escape(subj.name)}(?!\w)", re.IGNORECASE))
    hits: list[int] = []
    with path.open("r", encoding="utf-8", errors="replace") as fh:
        for num, line in enumerate(fh):
            if any(p.search(line) for p in pats):
                hits.append(num)
    return hits


class Backup:
    """Каталог бэкапа удаляемого: chmod 700, срок жизни в файле EXPIRES."""

    def __init__(self, root: Path, ttl_days: int, enabled: bool) -> None:
        self.enabled = enabled
        self.dir = root / time.strftime("%Y%m%dT%H%M%S", time.gmtime())
        self.ttl_days = ttl_days
        self.items: list[dict[str, str]] = []
        if enabled:
            root.mkdir(parents=True, exist_ok=True)
            os.chmod(root, DIR_MODE)
            self.dir.mkdir(mode=DIR_MODE)
            expires = int(time.time()) + ttl_days * SECONDS_PER_DAY
            self._write(self.dir / EXPIRES_FILE, str(expires))

    @staticmethod
    def _write(path: Path, text: str) -> None:
        path.write_text(text, encoding="utf-8")
        os.chmod(path, FILE_MODE)

    def save(self, src: Path) -> None:
        """Скопировать файл или каталог в бэкап до удаления."""
        if not self.enabled:
            return
        dst = self.dir / f"{len(self.items):05d}_{src.name}"
        if src.is_dir():
            shutil.copytree(src, dst, symlinks=True)
            _chmod_tree(dst)
        else:
            shutil.copy2(src, dst)
            os.chmod(dst, FILE_MODE)
        self.items.append({"orig": str(src), "copy": dst.name})

    def save_removed_lines(self, src: Path, lines: list[str]) -> None:
        """Сохранить только вырезанные строки (оригинал уже сохранён целиком)."""
        if self.enabled:
            self._write(self.dir / f"{len(self.items):05d}_removed_{src.name}", "".join(lines))

    def finish(self) -> None:
        if self.enabled:
            self._write(self.dir / MANIFEST_FILE, json.dumps(self.items, indent=2))


def _chmod_tree(root: Path) -> None:
    for dirpath, _dirnames, filenames in os.walk(root):
        os.chmod(dirpath, DIR_MODE)
        for name in filenames:
            p = Path(dirpath) / name
            if not p.is_symlink():
                os.chmod(p, FILE_MODE)


def purge_expired_backups(root: Path, now: float | None = None) -> int:
    """Удалить каталоги бэкапов, у которых истёк срок в EXPIRES. Вернуть их число."""
    cur = time.time() if now is None else now
    removed = 0
    if not root.is_dir():
        return 0
    for d in sorted(root.iterdir()):
        marker = d / EXPIRES_FILE
        if not d.is_dir() or not marker.is_file():
            continue  # чужое не трогаем: только каталоги с нашей меткой
        try:
            expires = int(marker.read_text(encoding="utf-8").strip())
        except ValueError:
            continue
        if expires <= cur:
            shutil.rmtree(d)
            removed += 1
            LOG.info("удалён просроченный бэкап")
    return removed


def rewrite_without_lines(path: Path, drop: set[int]) -> list[str]:
    """Переписать файл без указанных строк (атомарно). Вернуть вырезанные строки."""
    removed: list[str] = []
    tmp = path.with_name(path.name + ".pii-forget.tmp")
    mode = path.stat().st_mode & 0o777
    with path.open("r", encoding="utf-8", errors="surrogateescape") as src, tmp.open(
        "w", encoding="utf-8", errors="surrogateescape"
    ) as dst:
        for num, line in enumerate(src):
            if num in drop:
                removed.append(line)
            else:
                dst.write(line)
    os.chmod(tmp, mode)
    os.replace(tmp, path)
    return removed


def delete_pseudonymizer_thread(url: str, token: str, thread_id: str) -> str:
    """DELETE /threads/{id}. Вернуть 'deleted' | 'absent' | 'error'."""
    req = urllib.request.Request(
        f"{url.rstrip('/')}/threads/{thread_id}",
        method="DELETE",
        headers={"Authorization": f"Bearer {token}"},
    )
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT_SEC) as resp:
            return "deleted" if resp.status == HTTP_NO_CONTENT else "error"
    except urllib.error.HTTPError as exc:
        return "absent" if exc.code == HTTP_NOT_FOUND else "error"
    except (urllib.error.URLError, OSError):
        return "error"


@dataclass
class Report:
    """Отчёт без ПДн: только счётчики."""

    subject_ref: str
    mode: str
    counts: dict[str, int] = field(default_factory=dict)
    notes: list[str] = field(default_factory=list)

    def add(self, key: str, n: int = 1) -> None:
        self.counts[key] = self.counts.get(key, 0) + n


def process_sessions(
    args: argparse.Namespace, subj: Subject, bk: Backup, rep: Report, thread_ids: list[str]
) -> None:
    """Транскрипты Claude Code: чистые сессии целиком, смешанные — по строкам."""
    root = Path(args.projects_dir).expanduser()
    if not root.is_dir():
        rep.notes.append("каталог транскриптов не найден: пропущен")
        return
    for pdir in sorted(p for p in root.iterdir() if p.is_dir()):
        if args.project_filter and not any(f in pdir.name for f in args.project_filter):
            continue
        for path in sorted(pdir.glob("*.jsonl")):
            res = scan_session(path, subj)
            if not res.found:
                continue
            whole = res.pure or args.drop_mixed
            rep.add("sessions_whole" if whole else "sessions_mixed_lines")
            rep.add("session_lines", len(res.subject_lines))
            if whole:
                thread_ids.append(path.stem)
            if not args.apply:
                continue
            bk.save(path)
            if whole:
                path.unlink()
                sibling = path.with_suffix("")
                if sibling.is_dir():  # tool-results и subagents этой сессии
                    bk.save(sibling)
                    shutil.rmtree(sibling)
            else:
                bk.save_removed_lines(path, rewrite_without_lines(path, set(res.subject_lines)))
    if rep.counts.get("sessions_mixed_lines"):
        rep.notes.append(
            "в смешанных сессиях убраны только строки субъекта; ответы агента без id "
            "остаются: для полной чистки --drop-mixed"
        )


def process_chat_dirs(args: argparse.Namespace, subj: Subject, bk: Backup, rep: Report) -> None:
    """Каталоги чатов per_person/multichat и записи в sessions.json."""
    for ws in map(Path, args.workspace):
        ws = ws.expanduser()
        for chat_id in subj.owned_chat_ids:
            for d in (ws / "chats" / chat_id, ws / "state" / "multichat" / "chats" / chat_id):
                if d.is_dir():
                    rep.add("chat_dirs")
                    if args.apply:
                        bk.save(d)
                        shutil.rmtree(d)
        sessions = ws / "state" / "multichat" / "sessions.json"
        if sessions.is_file():
            data = json.loads(sessions.read_text(encoding="utf-8"))
            keys = [k for k in data if k in subj.owned_chat_ids]
            if keys:
                rep.add("multichat_session_entries", len(keys))
                if args.apply:
                    bk.save(sessions)
                    for k in keys:
                        del data[k]
                    sessions.write_text(json.dumps(data), encoding="utf-8")
        policy = ws / "chats" / "policy.yaml"
        if policy.is_file() and any(
            subj.id_re.search(line) for line in policy.read_text(encoding="utf-8").splitlines()
        ):
            rep.notes.append("chats/policy.yaml упоминает id субъекта: убрать вручную (доступ)")


def iter_log_files(dirs: list[str]) -> list[Path]:
    found: list[Path] = []
    for d in map(Path, dirs):
        d = d.expanduser()
        if d.is_dir():
            found += sorted(p for p in d.rglob("*") if p.is_file() and p.suffix in LOG_SUFFIXES)
    return found


def process_logs(args: argparse.Namespace, subj: Subject, bk: Backup, rep: Report) -> None:
    """Журналы плагина/агента — вырезать строки; журналы запусков listener — файл целиком."""
    log_dirs = [str(Path(w).expanduser() / "logs") for w in args.workspace]
    log_dirs += [str(Path(s).expanduser() / "logs") for s in args.state_dir]
    for path in iter_log_files(log_dirs):
        hits = scan_text_log(path, subj)
        if hits:
            rep.add("log_files")
            rep.add("log_lines", len(hits))
            if args.apply:
                bk.save(path)
                bk.save_removed_lines(path, rewrite_without_lines(path, set(hits)))
    for path in iter_log_files(args.listener_log_dir):
        if scan_text_log(path, subj):
            rep.add("listener_run_logs")
            if args.apply:
                bk.save(path)
                path.unlink()


def process_pseudonymizer(args: argparse.Namespace, rep: Report, thread_ids: list[str]) -> None:
    """Удалить таблицы замен по id удалённых сессий."""
    rep.add("pseudonymizer_threads", len(thread_ids))
    if not thread_ids:
        return
    if not (args.pseudonymizer_url and args.pseudonymizer_token_file):
        rep.notes.append("псевдонимизатор не задан: DELETE /threads/{id} не выполнен")
        return
    token_path = Path(args.pseudonymizer_token_file).expanduser()
    if not token_path.is_file():
        rep.notes.append("файл токена псевдонимизатора не найден")
        return
    if not args.apply:
        return
    token = token_path.read_text(encoding="utf-8").strip()
    for tid in thread_ids:
        rep.add(f"pseudonymizer_{delete_pseudonymizer_thread(args.pseudonymizer_url, token, tid)}")


SECOND_BRAIN_NOTE = (
    "second-brain: автоматом не чистится (отдельный репозиторий). Оператору: через MCP "
    "recall/memory найти заметки со scope или упоминанием этого id, затем удалить заметки "
    "в vault и пересобрать индекс штатными средствами second-brain."
)


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--user-id", required=True, help="Telegram user id субъекта")
    p.add_argument("--name", help="имя из атрибута user тега канала (необязательно)")
    p.add_argument("--chat-id", action="append", default=[], help="чат, целиком принадлежащий")
    p.add_argument("--projects-dir", default="~/.claude/projects")
    p.add_argument("--project-filter", action="append", default=[], help="подстрока имени проекта")
    p.add_argument("--workspace", action="append", default=[], help="<agent>/.claude")
    p.add_argument("--state-dir", action="append", default=[], help="TELEGRAM_STATE_DIR плагина")
    p.add_argument("--listener-log-dir", action="append", default=[])
    p.add_argument("--pseudonymizer-url")
    p.add_argument("--pseudonymizer-token-file")
    p.add_argument("--drop-mixed", action="store_true", help="смешанные сессии удалять целиком")
    p.add_argument("--backup-dir", default=f"~/{BACKUP_ROOT_NAME}")
    p.add_argument("--backup-ttl-days", type=int, default=DEFAULT_BACKUP_TTL_DAYS)
    p.add_argument("--no-backup", action="store_true", help="без бэкапа (не рекомендуется)")
    p.add_argument("--report", help="файл отчёта (chmod 600); иначе stdout")
    mode = p.add_mutually_exclusive_group()
    mode.add_argument("--dry-run", action="store_true", help="только отчёт (по умолчанию)")
    mode.add_argument("--apply", action="store_true", help="удалить, с бэкапом")
    p.add_argument("--purge-expired-backups", action="store_true", help="только чистка бэкапов")
    return p


def main(argv: list[str] | None = None) -> int:
    logging.basicConfig(level=logging.INFO, format="[pii-forget] %(message)s", stream=sys.stderr)
    args = build_parser().parse_args(argv)
    backup_root = Path(args.backup_dir).expanduser()
    if args.purge_expired_backups:
        LOG.info("просроченных бэкапов удалено: %d", purge_expired_backups(backup_root))
        return 0
    if not re.fullmatch(r"-?\d{1,20}", args.user_id):
        LOG.error("user id должен быть числом")
        return 2
    subj = Subject(args.user_id, args.name, args.chat_id)
    rep = Report(subj.ref, "apply" if args.apply else "dry-run")
    bk = Backup(backup_root, args.backup_ttl_days, args.apply and not args.no_backup)
    thread_ids: list[str] = []
    LOG.info("режим: %s, субъект: %s", rep.mode, subj.ref)
    process_sessions(args, subj, bk, rep, thread_ids)
    process_chat_dirs(args, subj, bk, rep)
    process_logs(args, subj, bk, rep)
    process_pseudonymizer(args, rep, thread_ids)
    bk.finish()
    rep.notes.append(SECOND_BRAIN_NOTE)
    if args.apply and not args.no_backup:
        rep.counts["backup_ttl_days"] = args.backup_ttl_days
        rep.notes.append("бэкап содержит ПДн, удаляется по сроку: --purge-expired-backups")
    out = json.dumps(
        {"subject_ref": rep.subject_ref, "mode": rep.mode, "counts": rep.counts,
         "notes": rep.notes},
        ensure_ascii=False, indent=2,
    )
    if args.report:
        rp = Path(args.report).expanduser()
        rp.write_text(out + "\n", encoding="utf-8")
        os.chmod(rp, FILE_MODE)
    else:
        print(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
