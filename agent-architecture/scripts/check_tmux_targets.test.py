#!/usr/bin/env python3
"""Юнит-тест стража точных целей tmux (scripts/check_tmux_targets.py).

Прежний страж — grep по одной форме записи — пропускал почти все неточные
цели. Здесь собраны все формы, на которых он молчал (цель без кавычек, -t"$S",
одинарные кавычки, tmux -L, "$TMUX_BIN", перенос строки, связка -pJt,
подкоманды вне списка, Python, TypeScript, tg-plugin), и точные формы, на
которых новый страж срабатывать не должен.
"""

from __future__ import annotations

import importlib.util
import logging
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
_SPEC = importlib.util.spec_from_file_location("check_tmux_targets", HERE / "check_tmux_targets.py")
assert _SPEC is not None and _SPEC.loader is not None
ctt = importlib.util.module_from_spec(_SPEC)
# dataclass ищет модуль в sys.modules — без регистрации загрузка падает.
sys.modules["check_tmux_targets"] = ctt
_SPEC.loader.exec_module(ctt)


def scan(name: str, text: str) -> list:
    """Проверить один файл с заданным именем и содержимым."""
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / name
        path.write_text(text, encoding="utf-8")
        return ctt.scan_file(path)


# Неточные формы в bash. Номера — пункты из разбора прежнего стража.
BAD_SHELL: dict[str, str] = {
    "1. цель без кавычек": 'tmux has-session -t $S\n',
    "2. -t\"$S\" слитно": 'tmux send-keys -t"$S" Enter\n',
    "3. одинарные кавычки": "tmux kill-session -t 'labops-app'\n",
    "4. tmux -L сокет": 'tmux -L swarm capture-pane -pt "$S" -S -8\n',
    "5. \"$TMUX_BIN\"": '"$TMUX_BIN" send-keys -t "$S" Enter\n',
    "6. перенос строки": 'tmux send-keys \\\n  -t "$S" Enter\n',
    "7. связка -pJt": 'tmux capture-pane -pJt "$S" -S -8\n',
    "8a. respawn-pane": 'tmux respawn-pane -k -t "$S" "bash"\n',
    "8b. select-window": 'tmux select-window -t "$S:1"\n',
    "8c. run-shell": "tmux run-shell -t \"$S\" 'true'\n",
    "-t$x слитно без кавычек": 'tmux has-session -t$S\n',
    "панель текущего окна": 'tmux capture-pane -pt "=$S:" -S -8\n',
    "вторая команда после \\;": 'tmux has-session -t "=$S" \\; send-keys -t "$S" Enter\n',
    "внутри $(...)": 'x="$(tmux display -p -t "$S" "#{pane_pid}")"\n',
    "путь к бинарю": '/usr/bin/tmux kill-session -t "$S"\n',
    "алиас подкоманды": 'tmux send -t "$S" Enter\n',
    "переменная без «=»": 'T="$S:^.{top-left}"\ntmux send-keys -t "$T" Enter\n',
}

# 9. Python: не только self._session и не только подкоманды из старого списка.
BAD_PY: dict[str, str] = {
    "9a. обёртка с атрибутом без «=»": (
        "class Pane:\n"
        "    def __init__(self, session: str) -> None:\n"
        "        self._pane = f\"{session}:^.{{top-left}}\"\n"
        "    def send(self) -> None:\n"
        "        self._tmux(\"send-keys\", \"-t\", self._pane, \"Enter\")\n"
    ),
    "9b. список [\"tmux\", …] с параметром": (
        "import subprocess\n"
        "def alive(name: str) -> bool:\n"
        "    return subprocess.run([\"tmux\", \"has-session\", \"-t\", name]).returncode == 0\n"
    ),
    "9c. панель текущего окна": (
        "class Pane:\n"
        "    def __init__(self, s: str) -> None:\n"
        "        self._p = f\"={s}:\"\n"
        "    def tail(self) -> None:\n"
        "        self._tmux(\"capture-pane\", \"-pt\", self._p)\n"
    ),
    "9d. команда строкой": "import os\nos.system(f\"tmux kill-session -t {name}\")\n",
}

# 10. TypeScript: весь плагин раньше не проверялся вовсе.
BAD_TS: dict[str, str] = {
    "10a. execFile с параметром": (
        "export async function clear(session: string): Promise<void> {\n"
        "  await execFileAsync('tmux', ['send-keys', '-t', session, 'C-u'])\n"
        "}\n"
    ),
    "10b. обёртка runTmux": (
        "async function kill(handle: Handle): Promise<void> {\n"
        "  await runTmux(['kill-session', '-t', handle.sessionName])\n"
        "}\n"
    ),
    "10c. шаблонная строка": "exec(`tmux send-keys -t ${s} Enter`)\n",
    "10d. spawn с литералом без «=»": "spawn('tmux', ['has-session', '-t', 'labops-app'])\n",
    "10e. панель текущего окна": (
        "const out = await execFileAsync('tmux', ['capture-pane', '-pt', `=${s}:`, '-S', '-8'])\n"
    ),
    "10f. после регулярки с кавычкой": (
        "if (/^Try\".*\"$/.test(input)) return false\n"
        "await execFileAsync('tmux', ['send-keys', '-t', session, 'Enter'])\n"
    ),
}

GOOD_SHELL: dict[str, str] = {
    "сессия": 'tmux has-session -t "=$S"\n',
    "панель агента": 'tmux send-keys -t "=$S:^.{top-left}" Enter\n',
    "сокет и перенаправления": 'tmux -L x kill-session -t "=$S" 2>/dev/null || true\n',
    "окно с двоеточием у оконной команды": 'tmux new-window -t "=$S:" bash\n',
    "формат с решёткой": "tmux display -pt \"=$1:^.{top-left}\" '#{cursor_x}'\n",
    "без цели": 'tmux new-session -d -s "$S" -x 80 -y 20 "cmd"\n',
    "значение -S не флаг": 'tmux capture-pane -p -S -8 -t "=$S:^.{top-left}"\n',
    "комментарий": '# tmux send-keys -t "$S" — так было раньше\n',
    "проверка наличия": 'command -v tmux >/dev/null || die "нужен tmux"\n',
    "слово в тексте": 'echo "tmux-сессия агента не подключится"\n',
    "переменная с «=»": 'T="=$S:^.{top-left}"\ntmux send-keys -t "$T" Enter\n',
    "пометка с объяснением": (
        'tmux kill-session -t "$S"  # tmux-target-ok: сессия создана тут же под уникальным именем\n'
    ),
    "список сессий": "tmux list-sessions -F '#{session_name}'\n",
    "перенос строки, точная цель": 'tmux send-keys \\\n  -t "=$S:^.{top-left}" Enter\n',
}

GOOD_PY: dict[str, str] = {
    "как в task_poller.py": (
        "import subprocess\n"
        "class TmuxPane:\n"
        "    \"\"\"Раньше было tmux send-keys -t $S — это докстринг, не код.\"\"\"\n"
        "    def __init__(self, session: str) -> None:\n"
        "        self._session_target = f\"={session}\"\n"
        "        self._pane_target = f\"={session}:^.{{top-left}}\"\n"
        "    def _tmux(self, *args: str) -> int:\n"
        "        return subprocess.run([\"tmux\", *args]).returncode\n"
        "    def alive(self) -> bool:\n"
        "        return self._tmux(\"has-session\", \"-t\", self._session_target) == 0\n"
        "    def send(self) -> None:\n"
        "        self._tmux(\"send-keys\", \"-t\", self._pane_target, \"Enter\")\n"
        "        self._log(\"deliver failed (tmux) — will retry\")\n"
    ),
    "помощник возвращает «=»": (
        "def exact(name: str) -> str:\n"
        "    return \"=\" + name\n"
        "def kill(name: str) -> None:\n"
        "    run([\"tmux\", \"kill-session\", \"-t\", exact(name)])\n"
    ),
}

GOOD_TS: dict[str, str] = {
    "шаблон с «=»": (
        "await execFileAsync('tmux', ['send-keys', '-t', `=${session}:^.{top-left}`, 'C-u'])\n"
    ),
    "сессия шаблоном": "await runTmux(['has-session', '-t', `=${sessionName}`])\n",
    "конкатенация с «=»": "await runTmux(['has-session', '-t', '=' + sessionName])\n",
    "константа с «=»": (
        "const target = `=${s}:^.{top-left}`\n"
        "await execFile('tmux', ['capture-pane', '-pt', target])\n"
    ),
    "функция-помощник": (
        "function exactSession(name: string): string {\n"
        "  return `=${name}`\n"
        "}\n"
        "await runTmux(['kill-session', '-t', exactSession(n)])\n"
    ),
    "стрелочный помощник": (
        "const paneOf = (name: string): string => `=${name}:^.{top-left}`\n"
        "await runTmux(['send-keys', '-t', paneOf(n), 'Enter'])\n"
    ),
    "лог и комментарий": (
        "// tmux send-keys -t ${s} — было раньше\n"
        "logger.warn('tmux kill-session failed', { chatId })\n"
        "if (/^Try\".*\"$/.test(input)) return false\n"
    ),
}


# Раскладка как в tg-plugin: форму цели строит один модуль из констант, index.ts
# реэкспортирует помощники, остальные модули их импортируют.
TARGETS_TS = """\
/** Префикс, запрещающий tmux подбирать сессию по началу имени. */
const EXACT_SESSION_PREFIX = '='
const FIRST_WINDOW_TOP_LEFT_PANE = '^.{top-left}'
// target = `${name}` — комментарий, не присваивание
const FORBIDDEN_NAME_CHARS = /[:.\\s]/
export function assertSessionName(name: string): void {
  if (FORBIDDEN_NAME_CHARS.test(name)) {
    throw new TypeError(`bad name: ${name}`)
  }
}
export function sessionTarget(name: string): string {
  assertSessionName(name)
  return `${EXACT_SESSION_PREFIX}${name}`
}
export function paneTarget(name: string): string {
  return `${sessionTarget(name)}:${FIRST_WINDOW_TOP_LEFT_PANE}`
}
export function looseTarget(name: string): string {
  return `${name}:${FIRST_WINDOW_TOP_LEFT_PANE}`
}
"""
INDEX_TS = "export { paneTarget, sessionTarget, looseTarget } from './targets.js'\n"
GOOD_CONSUMER_TS = """\
import { paneTarget, sessionTarget as exactSession } from '../tmux/index.js'
export async function submit(session: string, text: string): Promise<void> {
  const target = paneTarget(session)
  await exec(['send-keys', '-t', target, '-l', text])
  await exec(['capture-pane', '-p', '-t', paneTarget(session), '-S', '-8'])
  await runTmux(['kill-session', '-t', exactSession(session)])
}
"""
BAD_CONSUMER_TS = """\
import { looseTarget } from '../tmux/index.js'
export async function submit(session: string): Promise<void> {
  await exec(['send-keys', '-t', looseTarget(session), 'Enter'])
}
"""


class BadFormsTest(unittest.TestCase):
    """Каждая неточная форма даёт ровно одно нарушение."""

    def _check(self, name: str, cases: dict[str, str]) -> None:
        for desc, text in cases.items():
            with self.subTest(desc):
                found = scan(name, text)
                self.assertEqual(len(found), 1, f"{desc}: {[v.reason for v in found]}")

    def test_shell(self) -> None:
        self._check("agent.sh", BAD_SHELL)

    def test_python(self) -> None:
        self._check("agent.py", BAD_PY)

    def test_typescript(self) -> None:
        self._check("agent.ts", BAD_TS)

    def test_pane_reason_names_current_window(self) -> None:
        """Причина для «=имя:» объясняет, чем она плоха, а не просто «неточно»."""
        found = scan("agent.sh", BAD_SHELL["панель текущего окна"])
        self.assertIn("ТЕКУЩЕГО окна", found[0].reason)

    def test_exempt_marker_needs_reason(self) -> None:
        """Пометка без объяснения — не исключение, а нарушение."""
        found = scan("agent.sh", 'tmux kill-session -t "$S"  # tmux-target-ok:\n')
        self.assertEqual([v.reason for v in found], ["пометка-исключение без объяснения"])


class GoodFormsTest(unittest.TestCase):
    """Точные формы и упоминания tmux в тексте нарушением не считаются."""

    def _check(self, name: str, cases: dict[str, str]) -> None:
        for desc, text in cases.items():
            with self.subTest(desc):
                found = scan(name, text)
                self.assertEqual(found, [], f"{desc}: {[v.reason for v in found]}")

    def test_shell(self) -> None:
        self._check("agent.sh", GOOD_SHELL)

    def test_python(self) -> None:
        self._check("agent.py", GOOD_PY)

    def test_typescript(self) -> None:
        self._check("agent.ts", GOOD_TS)


class TreeTest(unittest.TestCase):
    """Обход дерева: оба корня, тесты в стороне."""

    def test_tg_plugin_is_scanned(self) -> None:
        """11. Второй корень (tg-plugin) проверяется наравне с первым."""
        with tempfile.TemporaryDirectory() as tmp:
            aa = Path(tmp) / "agent-architecture"
            tg = Path(tmp) / "tg-plugin" / "plugin" / "src"
            aa.mkdir()
            tg.mkdir(parents=True)
            (aa / "ok.sh").write_text('tmux has-session -t "=$S"\n', encoding="utf-8")
            (tg / "bad.ts").write_text(BAD_TS["10a. execFile с параметром"], encoding="utf-8")
            found, count = ctt.scan_paths([aa, Path(tmp) / "tg-plugin"])
        self.assertEqual(count, 2)
        self.assertEqual([v.path.name for v in found], ["bad.ts"])

    def _plugin_tree(self, tmp: str, consumer: str) -> Path:
        """Дерево в раскладке tg-plugin: tmux/targets.ts, tmux/index.ts, потребитель."""
        src = Path(tmp) / "src"
        (src / "tmux").mkdir(parents=True)
        (src / "channel").mkdir()
        (src / "tmux" / "targets.ts").write_text(TARGETS_TS, encoding="utf-8")
        (src / "tmux" / "index.ts").write_text(INDEX_TS, encoding="utf-8")
        (src / "channel" / "submit.ts").write_text(consumer, encoding="utf-8")
        return src

    def test_imported_helpers_resolve(self) -> None:
        """Помощник из другого модуля (через реэкспорт index.ts) — точная цель.

        Так устроен tg-plugin: без разбора импортов и констант в шаблонах страж
        объявил бы нарушением каждый точный вызов и держал бы гейт красным.
        """
        with tempfile.TemporaryDirectory() as tmp:
            found, count = ctt.scan_paths([self._plugin_tree(tmp, GOOD_CONSUMER_TS)])
        self.assertEqual(count, 3)
        self.assertEqual([v.reason for v in found], [])

    def test_imported_helper_without_prefix(self) -> None:
        """Импортированный помощник, собирающий цель без «=», — нарушение."""
        with tempfile.TemporaryDirectory() as tmp:
            found, _ = ctt.scan_paths([self._plugin_tree(tmp, BAD_CONSUMER_TS)])
        self.assertEqual([v.path.name for v in found], ["submit.ts"])
        self.assertIn("без «=»", found[0].reason)

    def test_tests_are_exempt(self) -> None:
        """Тесты нарочно пишут неточные формы и работают в своём сервере."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "pane.test.sh").write_text(BAD_SHELL["1. цель без кавычек"], encoding="utf-8")
            (root / "tests").mkdir()
            (root / "tests" / "a.ts").write_text(BAD_TS["10c. шаблонная строка"], encoding="utf-8")
            (root / "node_modules").mkdir()
            (root / "node_modules" / "x.sh").write_text(BAD_SHELL["3. одинарные кавычки"],
                                                        encoding="utf-8")
            found, count = ctt.scan_paths([root])
        self.assertEqual((found, count), ([], 0))

    def test_agent_architecture_is_clean(self) -> None:
        """Сам agent-architecture обязан быть чистым — иначе страж врёт или код сломан."""
        found, count = ctt.scan_paths([ctt.AA_ROOT])
        self.assertGreater(count, 0)
        self.assertEqual([v.format(ctt.AA_ROOT) for v in found], [])

    def test_cli_exit_code(self) -> None:
        """Код выхода: 1 при нарушении, 0 без них."""
        with tempfile.TemporaryDirectory() as tmp:
            bad = Path(tmp) / "bad.sh"
            good = Path(tmp) / "good.sh"
            bad.write_text(BAD_SHELL["1. цель без кавычек"], encoding="utf-8")
            good.write_text(GOOD_SHELL["сессия"], encoding="utf-8")
            logging.disable(logging.CRITICAL)
            try:
                self.assertEqual(ctt.main([str(bad)]), 1)
                self.assertEqual(ctt.main([str(good)]), 0)
            finally:
                logging.disable(logging.NOTSET)


if __name__ == "__main__":
    unittest.main()
