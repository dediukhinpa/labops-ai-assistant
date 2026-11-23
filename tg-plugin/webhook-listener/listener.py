#!/usr/bin/env python3
"""labops-plugin webhook listener.

Receives POST /hooks/agent from second_brain swarm worker, verifies Bearer,
spawns a headless subprocess in the agent's workspace that picks up the task
from second_brain via swarm.list_my_pending: `claude -p` on a Claude Code
swarm, `codex exec` on a Codex swarm (HARNESS in $CLAUDE_LAB/shared/swarm.env).

Designed for the labops-channel plugin family, which has no inbox-poll
loop — Claude is invoked directly when a webhook arrives.

Bind: $WEBHOOK_BIND_HOST:$WEBHOOK_PORT (default 0.0.0.0:6100).
Auth: Bearer token from $WEBHOOK_BEARER_FILE.

v6.3 features:
- enrichment from second_brain.list_my_pending when swarm worker sends an
  empty payload (P0.5 degraded-retry case)
- pre-ack Telegram notification to the agent owner (skip 3-way degraded
  payloads + 5-minute dedup window)
- silent ack when both payload and second_brain inbox are empty (fluke retry)
"""
from __future__ import annotations

import asyncio
import html
import json
import logging
import os
import re
import signal
import sys
import time
import tomllib
from pathlib import Path

from aiohttp import web

PORT = int(os.environ.get("WEBHOOK_PORT", "6100"))
# Default to loopback. Operators who terminate TLS upstream can flip to
# 0.0.0.0 explicitly; we do not encourage cleartext public exposure.
BIND_HOST = os.environ.get("WEBHOOK_BIND_HOST", "127.0.0.1")
BEARER_FILE = os.environ.get("WEBHOOK_BEARER_FILE", "/etc/labops-plugin/webhook.token")
AGENT_WORKSPACE = Path(os.environ.get(
    "WEBHOOK_AGENT_WORKSPACE",
    str(Path.home() / ".claude"),
))
CLAUDE_BIN = os.environ.get("CLAUDE_BIN", "/usr/local/bin/claude")
# Бинарь codex закреплённой версии ставит установщик роя (lib/codex-install.sh) пользователю
# агентов, а не в /usr/local/bin.
CODEX_BIN = os.environ.get("CODEX_BIN", str(Path.home() / ".local" / "bin" / "codex"))
LOG_DIR = Path(os.environ.get(
    "WEBHOOK_LOG_DIR", "/var/log/labops-plugin-webhook",
))
INVOCATION_TIMEOUT_SEC = int(os.environ.get("INVOCATION_TIMEOUT_SEC", "1800"))

SECOND_BRAIN_TOKEN_PATH = Path(os.environ.get(
    "WEBHOOK_SECOND_BRAIN_TOKEN_FILE",
    str(Path.home() / ".secrets" / "second_brain.token"),
))
SECOND_BRAIN_AGENT_ROUTER_URL = os.environ.get("WEBHOOK_SECOND_BRAIN_AGENT_ROUTER_URL", "").strip()
AGENT_NAME = os.environ.get("WEBHOOK_AGENT_NAME", "").strip()
if not AGENT_NAME:
    raise SystemExit(
        "WEBHOOK_AGENT_NAME is required — set it to the logical agent name "
        "that owns this listener (it is embedded into the spawn prompt)."
    )

OWNER_CHAT_ID = os.environ.get("WEBHOOK_OWNER_CHAT_ID", "").strip()
TG_BOT_TOKEN_FILE = Path(os.environ.get(
    "WEBHOOK_TG_BOT_TOKEN_FILE",
    str(Path.home() / ".secrets" / "telegram-bot-token"),
))

NOTIFY_TTL_SEC = int(os.environ.get("WEBHOOK_NOTIFY_TTL_SEC", "300"))

# Харнес роя: все агенты на Claude Code или все на Codex CLI. Выбор пишет установщик в
# $CLAUDE_LAB/shared/swarm.env (строка HARNESS=claude|codex), правила разбора те же, что в
# agent-architecture/orchestration/lib/harness.sh. Файла или строки нет — рой поставлен до
# появления выбора, это claude.
HARNESS_CLAUDE = "claude"
HARNESS_CODEX = "codex"
HARNESS_KNOWN = (HARNESS_CLAUDE, HARNESS_CODEX)
CLAUDE_LAB = Path(os.environ.get("CLAUDE_LAB") or str(Path.home() / ".claude-lab"))
SWARM_ENV_PATH = CLAUDE_LAB / "shared" / "swarm.env"
# Плейсхолдер bearer из agent.env: настоящего токена нет, отдавать его codex незачем.
AGENT_BEARER_PLACEHOLDER = "CHANGE_ME"
# Сколько ждём ответа pii-proxy на /health (как PII_HEALTH_TIMEOUT_SEC в lib/pii.sh).
PII_HEALTH_TIMEOUT_SEC = 3
# Решение владельца 23.11.2026: pii-proxy молчит — задача всё равно выполняется, но напрямую,
# а владелец получает предупреждение (ПДн в это время уходят в модель без маскирования).
# Режим напрямую для codex: у провайдера агента (labops-pii) подменяется только base_url — на
# бэкенд, куда ходит и сам прокси (тот же вход ChatGPT). Провайдер не меняем: Codex не продолжает
# нить с другим провайдером (проверено на 0.171.0), так что режимы у драйвера и здесь одинаковы.
PII_MODEL_PROVIDER = "labops-pii"
DIRECT_BACKEND_URL = "https://chatgpt.com/backend-api/codex"
# Файл режима агента, который ведут start-agent.sh и watchdog (lib/pii.sh: pii_mode_file).
# В нём direct — владелец уже предупреждён watchdog, второй раз не пишем.
PII_MODE_FILE = AGENT_WORKSPACE / "state" / "pii-mode"
PII_MODE_DIRECT = "direct"
# Метка «когда listener последний раз предупреждал о задаче напрямую» и троттлинг, секунд.
PII_DIRECT_WARN_STAMP = AGENT_WORKSPACE / "state" / "pii-listener-direct.warned"
PII_DIRECT_WARN_COOLDOWN_SEC = int(
    os.environ.get("WEBHOOK_PII_DIRECT_WARN_COOLDOWN_SEC", "3600"))
PII_DIRECT_WARN_TEXT = (
    "⚠️ pii-proxy агента {agent} не отвечает — задачу от другого агента выполняю напрямую: "
    "персональные данные уходят в модель без маскирования. Проверьте: "
    "systemctl --user status labops-pii-proxy@{agent}"
)
# Корень локального pii-proxy в base_url провайдера: только 127.0.0.1/localhost, как в
# pii_agent_base_url (lib/pii.sh). Путь (/backend-api/codex) для /health отбрасывается.
_PII_LOCAL_URL = re.compile(r"^(http://(?:127\.0\.0\.1|localhost):[0-9]+)(?:/|$)")

_TOXIC = re.compile(
    r"(Bearer\s+\S+|sk-[A-Za-z0-9_-]+|password=\S+)",
    re.IGNORECASE,
)


class RedactingFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        return _TOXIC.sub("<REDACTED>", super().format(record))


_handler = logging.StreamHandler(sys.stdout)
_handler.setFormatter(RedactingFormatter("%(asctime)s %(levelname)s %(message)s"))
logging.basicConfig(level=logging.INFO, handlers=[_handler])
log = logging.getLogger("labops-plugin-webhook")


def _read_secret(path: str) -> bytes:
    p = Path(path).expanduser()
    if not p.is_file():
        raise SystemExit(f"secret file not found: {p}")
    return p.read_text().rstrip("\n").encode("utf-8")


def _strip_env_value(raw: str) -> str:
    """Срезать пробелы справа и одну пару кавычек, как harness.sh и `source`."""
    value = raw.rstrip()
    for quote in ('"', "'"):
        if len(value) >= 2 and value.startswith(quote) and value.endswith(quote):
            return value[1:-1]
    return value


def _read_env_file_value(path: Path, key: str) -> str:
    """Значение ключа из env-файла (последняя строка выигрывает), пусто — нет ключа.

    Файл разбирается, а не исполняется: в нём лежат секреты, а исполнять оттуда
    что-либо listener незачем. Понимает и `KEY=value`, и `export KEY="value"`.
    """
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return ""
    pattern = re.compile(rf"^\s*(?:export\s+)?{re.escape(key)}=(.*)$")
    value = ""
    for line in text.splitlines():
        match = pattern.match(line)
        if match:
            value = _strip_env_value(match.group(1))
    return value


def _read_harness(swarm_env: Path) -> str:
    """Харнес роя из swarm.env. Неизвестное значение — отказ старта, а не тихий claude.

    Агент codex, запущенный как claude, ушёл бы мимо своего конфига и pii-proxy.
    """
    value = _read_env_file_value(swarm_env, "HARNESS")
    if not value:
        return HARNESS_CLAUDE
    if value not in HARNESS_KNOWN:
        raise SystemExit(
            f"unknown HARNESS '{value}' in {swarm_env} (expected: {', '.join(HARNESS_KNOWN)})"
        )
    return value


HARNESS = _read_harness(SWARM_ENV_PATH)
# CODEX_HOME агента — сосед рабочей папки: <lab>/<agent>/.claude и <lab>/<agent>/.codex.
CODEX_HOME = Path(os.environ.get("WEBHOOK_CODEX_HOME") or str(AGENT_WORKSPACE.parent / ".codex"))
if HARNESS == HARNESS_CODEX and not (CODEX_HOME / "config.toml").is_file():
    # Без config.toml агента codex пошёл бы к модели напрямую, мимо pii-proxy, и без
    # second-brain: лучше не стартовать, чем выполнять задачи так.
    raise SystemExit(
        f"HARNESS=codex but {CODEX_HOME / 'config.toml'} not found — set "
        "WEBHOOK_AGENT_WORKSPACE to <lab>/<agent>/.claude or WEBHOOK_CODEX_HOME explicitly."
    )

BEARER_TOKEN: bytes = _read_secret(BEARER_FILE)
LOG_DIR.mkdir(parents=True, exist_ok=True)


def _verify_bearer(request: web.Request) -> bool:
    import hmac as _hmac
    header = request.headers.get("Authorization", "")
    if not header.startswith("Bearer "):
        return False
    candidate = header[7:].strip().encode("utf-8")
    return _hmac.compare_digest(candidate, BEARER_TOKEN)


_SAFE_TASK_ID = re.compile(r"[^a-zA-Z0-9_.:-]")


def _sanitize_task_id(raw: str) -> str:
    return _SAFE_TASK_ID.sub("_", raw)[:64] or "no-id"


def _build_prompt(payload: dict) -> str:
    from_agent = payload.get("from_agent") or payload.get("from") or "unknown"
    raw_task_id = payload.get("task_id") or payload.get("_task_id") or "no-id"
    task_id = _sanitize_task_id(str(raw_task_id))
    title = payload.get("title") or "(no title)"
    body = payload.get("body") or ""
    context = payload.get("context") or ""

    if payload.get("instruction_type") == "memory_consolidate":
        # Побудка на консолидацию памяти -- это работа над файлами воркспейса,
        # а не задача с доски. Общий промпт погнал бы агента искать задачу,
        # не нашёл бы её и завершился шагом 2c ("fluke retry -> ack and exit"),
        # то есть побудка снова была бы съедена молча.
        return (
            f"Memory consolidation requested for agent {AGENT_NAME}.\n\n"
            f"Reason: {payload.get('reason') or 'unspecified'}\n"
            f"task_id: {task_id}\n\n"
            f"{body}\n\n"
            f"Steps:\n"
            f"1) Read core/active/episodic.md entries newer than the watermark in "
            f"core/passive/.consolidated-at (if the file is missing, take the whole log).\n"
            f"2) Distil them into core/passive/*.md by kind: decisions, errors, "
            f"preferences, insights. Keep provenance and decay frontmatter.\n"
            f"3) Dual-write only what is worth sharing to second_brain, recall before "
            f"write, and stay inside your can_write_scopes.\n"
            f"4) Update the watermark in core/passive/.consolidated-at.\n"
            f"5) Do not report to the owner: this is routine housekeeping.\n"
            f"6) Call mcp__second_brain-agent_router__ack(task_id=\"{task_id}\"). "
            f"It will answer acked=false — that is expected, not a failure: the "
            f"delivery worker already marks the row acked when this webhook "
            f"returns 2xx, and mark_acked only touches rows still pending. Do "
            f"not retry it and do not report it as a problem.\n"
        )

    return (
        f"Inter-agent task delivered via swarm webhook.\n\n"
        f"From agent: {from_agent}\n"
        f"task_id: {task_id}\n"
        f"Title: {title}\n\n"
        f"Body:\n{body}\n\n"
        f"Context: {context}\n\n"
        f"Steps:\n"
        f"1) Read your inbox: mcp__second_brain-agent_router__list_my_pending(agent=\"{AGENT_NAME}\")\n"
        f"2) Check the task board IN THIS ORDER:\n"
        f"   a) task_list(assignee=\"{AGENT_NAME}\", status=\"progress\") — your ACTIVE tasks. "
        f"If any — continue the FRESHEST (max id), do not reject it as new.\n"
        f"   b) If progress is empty — task_list(assignee=\"{AGENT_NAME}\", status=\"new\") — "
        f"take the FRESHEST (max id). IGNORE stale tasks older than 7 days "
        f"(created_at < today minus 7d) — residual garbage, not work.\n"
        f"   c) If both empty — webhook was a fluke retry. agent_router.ack and exit.\n"
        f"3) If payload carries a meaningful task_id, it wins. Otherwise use the task from (a) or (b).\n"
        f"4) Do the work.\n"
        f"5) Report to the owner via your usual channel.\n"
        f"6) After the owner report, send a short summary to the dispatching agent via "
        f"mcp__second_brain-agent_router__notify with payload "
        f"{{'title': 'Report from {AGENT_NAME}: <task title>', 'body': '<2-4 bullets>', "
        f"'_task_id': '{task_id}'}}.\n"
        f"7) Only then call mcp__second_brain-agent_router__ack(task_id=\"{task_id}\").\n"
    )


_SUBPROCESS_ENV_ALLOW = frozenset({
    "HOME", "PATH", "USER", "LANG", "LC_ALL", "LC_CTYPE", "TERM", "TZ",
})
_SUBPROCESS_ENV_PREFIX = ("CLAUDE_", "ANTHROPIC_")
# Ключи из блока env файла settings.json агента, которые нужны дочернему `claude -p`.
# Зачем: cwd процесса - рабочий каталог агента, а claude читает проектные настройки из
# <cwd>/.claude/settings.json, поэтому settings.json самого агента (в cwd) сюда НЕ попадает,
# и без этого задачи шли мимо pii-proxy прямо в API (проверено живым прогоном 05.11.2026:
# задача выполнена, в журнале прокси 0 запросов).
# Почему читаем settings.json, а не отдельный env-файл listener: источник один и тот же
# для TUI-агента и для listener, порт не может разойтись, а уже установленным агентам
# хватает обновить код listener. Хуки TUI-агента сюда сознательно НЕ переносим (флаг
# --settings не используем): они шлют события в вебхук плагина и ломали бы фоновую задачу.
_AGENT_SETTINGS_ENV_KEYS = (
    "ANTHROPIC_BASE_URL",
    "DISABLE_TELEMETRY",
    "DISABLE_ERROR_REPORTING",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC",
)


def _agent_settings_env(workspace: Path) -> dict[str, str]:
    """Вернуть разрешённые ключи env из settings.json агента (пусто, если файла нет)."""
    try:
        data = json.loads((workspace / "settings.json").read_text(encoding="utf-8"))
        block = data.get("env", {}) if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}
    if not isinstance(block, dict):
        return {}
    return {
        k: v for k, v in block.items()
        if k in _AGENT_SETTINGS_ENV_KEYS and isinstance(v, str) and v
    }


def _build_subprocess_env() -> dict[str, str]:
    """Build a minimal env for the spawned Claude.

    Drops anything the listener reads (WEBHOOK_*, second_brain tokens, telegram bot
    tokens) so secrets do not leak into the child process. Allows a small
    POSIX baseline + an opt-in CLAUDE_/ANTHROPIC_ prefix passthrough.
    """
    env: dict[str, str] = {}
    for key in _SUBPROCESS_ENV_ALLOW:
        val = os.environ.get(key)
        if val is not None:
            env[key] = val
    for key, val in os.environ.items():
        if key.startswith(_SUBPROCESS_ENV_PREFIX):
            env[key] = val
    # Явно заданное в окружении listener важнее settings.json (оператор мог переопределить).
    for key, val in _agent_settings_env(AGENT_WORKSPACE).items():
        env.setdefault(key, val)
    env.setdefault("HOME", str(Path.home()))
    return env


def _build_codex_env() -> dict[str, str]:
    """Окружение для `codex exec`: базовый allowlist, CODEX_HOME агента и его AGENT_BEARER.

    Из секретов в дочерний процесс попадает только AGENT_BEARER из agent.env агента: на
    него ссылаются MCP-серверы second-brain в config.toml (bearer_token_env_var). Префиксы
    CLAUDE_/ANTHROPIC_ и env из settings.json — это настройки claude, codex их не получает:
    модель и pii-proxy он берёт из своего config.toml.
    """
    env: dict[str, str] = {}
    for key in _SUBPROCESS_ENV_ALLOW:
        val = os.environ.get(key)
        if val is not None:
            env[key] = val
    env.setdefault("HOME", str(Path.home()))
    env["CODEX_HOME"] = str(CODEX_HOME)
    bearer = _read_env_file_value(AGENT_WORKSPACE / "agent.env", "AGENT_BEARER")
    if bearer and bearer != AGENT_BEARER_PLACEHOLDER:
        env["AGENT_BEARER"] = bearer
    else:
        log.warning("AGENT_BEARER not set in agent.env — codex runs without second_brain")
    return env


def _headless_command(prompt: str, direct: bool = False) -> tuple[list[str], dict[str, str]]:
    """argv и окружение headless-запуска агента под харнес роя.

    Args:
        prompt: Текст задачи.
        direct: pii-proxy не отвечает — запуск напрямую, мимо прокси. При False (норма) argv и
            окружение прежние.

    Returns:
        argv и окружение дочернего процесса.
    """
    if HARNESS == HARNESS_CODEX:
        # Без подтверждений и без песочницы codex работает по config.toml агента
        # (approval_policy=never, sandbox_mode=danger-full-access), флагами это не дублируем.
        # Рабочая папка агента — не git-репозиторий, отсюда --skip-git-repo-check.
        argv = [CODEX_BIN, "exec", "--skip-git-repo-check"]
        if direct:
            argv += ["-c", f'model_providers.{PII_MODEL_PROVIDER}.base_url="{DIRECT_BACKEND_URL}"']
        return [*argv, prompt], _build_codex_env()
    env = _build_subprocess_env()
    if direct:
        env.pop("ANTHROPIC_BASE_URL", None)
    return [CLAUDE_BIN, "-p", prompt, "--dangerously-skip-permissions"], env


def _codex_pii_proxy_url(config_path: Path) -> str:
    """Корень pii-proxy агента из config.toml codex (пусто — прокси у агента нет).

    Берётся base_url провайдера, указанного в model_provider, — то же, что делает
    pii_agent_base_url в agent-architecture/orchestration/lib/pii.sh.
    """
    try:
        with config_path.open("rb") as fh:
            cfg = tomllib.load(fh)
        providers = cfg.get("model_providers", {})
        url = providers.get(cfg.get("model_provider", ""), {}).get("base_url", "")
    except (OSError, tomllib.TOMLDecodeError, AttributeError):
        return ""
    match = _PII_LOCAL_URL.match(url if isinstance(url, str) else "")
    return match.group(1) if match else ""


async def _pii_proxy_healthy(base_url: str) -> bool:
    """Отвечает ли pii-proxy на GET /health кодом 2xx."""
    import aiohttp
    try:
        async with aiohttp.ClientSession() as session:
            async with session.get(
                f"{base_url.rstrip('/')}/health",
                timeout=aiohttp.ClientTimeout(total=PII_HEALTH_TIMEOUT_SEC),
            ) as resp:
                return 200 <= resp.status < 300
    except Exception:  # noqa: BLE001 — любой сбой сети значит «не отвечает»
        return False


def _pii_proxy_url() -> str:
    """Корень pii-proxy агента под харнес роя (пусто — прокси у агента нет).

    codex — base_url провайдера из config.toml; claude — ANTHROPIC_BASE_URL, который получит
    `claude -p` (из окружения listener или из settings.json агента). Считается прокси только
    локальный адрес, как в pii_agent_base_url (lib/pii.sh).
    """
    if HARNESS == HARNESS_CODEX:
        return _codex_pii_proxy_url(CODEX_HOME / "config.toml")
    url = _build_subprocess_env().get("ANTHROPIC_BASE_URL", "")
    match = _PII_LOCAL_URL.match(url)
    return match.group(1) if match else ""


async def _pii_direct_needed() -> bool:
    """Нужно ли запускать задачу напрямую: прокси у агента настроен, но не отвечает на /health.

    Раньше codex при этом не запускался (503, задача оставалась pending), а claude уходил в
    мёртвый прокси. Теперь задача выполняется напрямую (решение владельца 23.11.2026).
    """
    url = _pii_proxy_url()
    if not url:
        return False
    return not await _pii_proxy_healthy(url)


def _direct_warn_due(now: float) -> bool:
    """Пора ли предупреждать владельца о задаче напрямую (и запомнить, что предупредили).

    Молчим, если watchdog уже перевёл агента в режим напрямую (он сам предупредил), и если с
    прошлого предупреждения listener не прошло PII_DIRECT_WARN_COOLDOWN_SEC. Метку пишем до
    отправки: сбой Telegram не должен превращаться в сообщение на каждую задачу.
    """
    try:
        if PII_MODE_FILE.read_text(encoding="utf-8").strip() == PII_MODE_DIRECT:
            return False
    except OSError:
        pass
    try:
        last = float(PII_DIRECT_WARN_STAMP.read_text(encoding="utf-8").strip() or 0)
    except (OSError, ValueError):
        last = 0.0
    if now - last < PII_DIRECT_WARN_COOLDOWN_SEC:
        return False
    try:
        PII_DIRECT_WARN_STAMP.parent.mkdir(parents=True, exist_ok=True)
        PII_DIRECT_WARN_STAMP.write_text(f"{now:.0f}\n", encoding="utf-8")
    except OSError as exc:
        log.warning("pii direct warn stamp not written: %s", exc)
    return True


async def _send_owner_text(text: str) -> None:
    """Отправить владельцу агента простой текст в Telegram (без разметки). Сбой — в журнал."""
    if not OWNER_CHAT_ID:
        log.debug("owner message skip — WEBHOOK_OWNER_CHAT_ID not set")
        return
    try:
        import aiohttp
        token = TG_BOT_TOKEN_FILE.read_text().strip()
        async with aiohttp.ClientSession() as session:
            async with session.post(
                f"https://api.telegram.org/bot{token}/sendMessage",
                json={"chat_id": OWNER_CHAT_ID, "text": text},
                timeout=aiohttp.ClientTimeout(total=10),
            ) as resp:
                if resp.status != 200:
                    log.warning("owner message HTTP %d: %s", resp.status, (await resp.text())[:200])
    except Exception as exc:  # noqa: BLE001 — предупреждение не должно ронять приём задачи
        log.warning("owner message failed: %s", exc)


async def _warn_direct(task_id: str) -> None:
    """Задача пойдёт напрямую: запись в журнал всегда, владельцу — с троттлингом."""
    log.warning(
        "pii-proxy of agent %s is not answering /health — task_id=%s runs DIRECT "
        "(personal data is not masked)", AGENT_NAME, task_id,
    )
    if _direct_warn_due(time.time()):
        await _send_owner_text(PII_DIRECT_WARN_TEXT.format(agent=AGENT_NAME))


def _kill_process_group(proc: asyncio.subprocess.Process) -> None:
    """Убить процесс и всю его группу (codex запускает команды и MCP-серверы детьми)."""
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    except OSError:
        proc.kill()


async def _spawn_headless(prompt: str, task_id: str, direct: bool = False) -> None:
    ts = int(time.time())
    safe_id = _sanitize_task_id(task_id)
    log_path = LOG_DIR / f"{ts}_{safe_id}.log"

    argv, env = _headless_command(prompt, direct=direct)

    log.info("spawning %s for task_id=%s%s, log=%s",
             HARNESS, task_id, " (direct, no pii-proxy)" if direct else "", log_path.name)
    log_fh = log_path.open("w")
    # stdin закрыт обязательно: codex exec при открытом stdin ждёт из него ввод.
    proc = await asyncio.create_subprocess_exec(
        *argv,
        cwd=str(AGENT_WORKSPACE),
        env=env,
        stdin=asyncio.subprocess.DEVNULL,
        stdout=log_fh,
        stderr=asyncio.subprocess.STDOUT,
        # codex — в своей группе процессов, чтобы по таймауту убить и его детей.
        # Запуск claude прежний.
        **({"start_new_session": True} if HARNESS == HARNESS_CODEX else {}),
    )

    async def _wait_and_close() -> None:
        try:
            await asyncio.wait_for(proc.wait(), timeout=INVOCATION_TIMEOUT_SEC)
            log.info("%s task_id=%s exited rc=%s", HARNESS, task_id, proc.returncode)
        except asyncio.TimeoutError:
            log.warning("%s task_id=%s timed out, killing", HARNESS, task_id)
            if HARNESS == HARNESS_CODEX:
                _kill_process_group(proc)
                await proc.wait()
            else:
                proc.kill()
        finally:
            log_fh.close()

    asyncio.create_task(_wait_and_close())


async def _fetch_pending_task(agent: str) -> dict | None:
    """Pull freshest pending delivery from second_brain agent_router. Returns enriched dict or None.

    second_brain agent_router list_my_pending derives the agent from the Bearer token via
    AuthCaptureMiddleware, so the `agent` argument is informational/logging
    only — it must match the token's owner.
    """
    if not SECOND_BRAIN_AGENT_ROUTER_URL:
        log.debug("fetch_pending skip — WEBHOOK_SECOND_BRAIN_AGENT_ROUTER_URL not set")
        return None
    try:
        import aiohttp
        import json as _json
        token = SECOND_BRAIN_TOKEN_PATH.read_text().strip()
        body = {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {
                "name": "list_my_pending",
                "arguments": {"limit": 5},
            },
        }
        headers = {
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        }
        async with aiohttp.ClientSession() as session:
            async with session.post(
                SECOND_BRAIN_AGENT_ROUTER_URL,
                json=body,
                headers=headers,
                timeout=aiohttp.ClientTimeout(total=10),
            ) as resp:
                raw = await resp.text()
                if resp.status != 200:
                    log.warning("fetch_pending HTTP %d: %s", resp.status, raw[:200])
                    return None
        # Extract JSON from SSE-wrapped response
        envelope = None
        for line in raw.splitlines():
            line = line.strip()
            if line.startswith("data:"):
                line = line[5:].strip()
            if not line or line.startswith(":") or line.startswith("event:"):
                continue
            try:
                envelope = _json.loads(line)
                break
            except Exception:
                continue
        if envelope is None:
            try:
                envelope = _json.loads(raw)
            except Exception:
                log.warning("fetch_pending unparseable: %s", raw[:200])
                return None
        result = envelope.get("result") or {}
        # FastMCP wrap_result: structuredContent.result is the actual list
        structured = result.get("structuredContent") or {}
        deliveries = structured.get("result")
        if deliveries is None:
            # Fallback: content[0].text contains JSON
            contents = result.get("content") or []
            if contents:
                text_payload = contents[0].get("text", "")
                try:
                    parsed = _json.loads(text_payload)
                    if isinstance(parsed, list):
                        deliveries = parsed
                    elif isinstance(parsed, dict):
                        deliveries = (
                            parsed.get("result")
                            or parsed.get("deliveries")
                            or parsed.get("items")
                            or []
                        )
                except Exception:
                    log.warning("fetch_pending inner parse failed: %s", text_payload[:200])
                    return None
        if not deliveries:
            return None
        if not isinstance(deliveries, list):
            log.warning(
                "fetch_pending unexpected deliveries type: %s",
                type(deliveries).__name__,
            )
            return None

        def _sort_key(d):
            # Prefer ISO timestamp over id. created_at is sortable as a
            # string when it is ISO-8601 (which second_brain emits); fall back to
            # a numeric id if present, else string id.
            ts = d.get("created_at")
            if isinstance(ts, str) and ts:
                return (1, ts)
            raw_id = d.get("id")
            if isinstance(raw_id, int):
                return (0, f"{raw_id:020d}")
            if isinstance(raw_id, str) and raw_id.isdigit():
                return (0, f"{int(raw_id):020d}")
            return (0, str(raw_id or ""))

        deliveries.sort(key=_sort_key, reverse=True)
        top = deliveries[0]
        inner = top.get("payload") or {}
        return {
            "from_agent": top.get("from_agent") or inner.get("from_agent") or "unknown",
            "task_id": str(
                inner.get("_task_id")
                or inner.get("task_id")
                or top.get("task_id")
                or top.get("id")
                or "no-id"
            ),
            "title": inner.get("title") or top.get("title") or "(no title)",
            "body": inner.get("body") or top.get("body") or "",
            "delivery_id": top.get("id"),
        }
    except Exception as exc:
        log.warning("fetch_pending failed: %s", exc)
        return None


_NOTIFY_DEDUP: dict[tuple[str, str, str], float] = {}


async def _notify_owner(from_agent: str, task_id: str, title: str) -> None:
    """Send Telegram pre-ack to the agent owner. Skips degraded payloads + 5-min dedup."""
    if not OWNER_CHAT_ID:
        log.debug("notify_owner skip — WEBHOOK_OWNER_CHAT_ID not set")
        return
    import time as _time
    # Skip 3-way degraded payloads (residual swarm worker retries, not real tasks).
    if from_agent == "unknown" and task_id == "no-id" and "degraded" in title.lower():
        log.info("notify_owner skip 3-way-degraded payload (silent retry)")
        return
    key = (from_agent, task_id, title)
    now = _time.time()
    last = _NOTIFY_DEDUP.get(key, 0.0)
    if now - last < NOTIFY_TTL_SEC:
        log.info(
            "notify_owner dedup skip from=%s task_id=%s (last %.0fs ago)",
            from_agent, task_id, now - last,
        )
        return
    if len(_NOTIFY_DEDUP) > 100:
        cutoff = now - NOTIFY_TTL_SEC
        for k in [kk for kk, ts in _NOTIFY_DEDUP.items() if ts < cutoff]:
            del _NOTIFY_DEDUP[k]
    _NOTIFY_DEDUP[key] = now
    try:
        import aiohttp
        token = TG_BOT_TOKEN_FILE.read_text().strip()
        safe_from = html.escape(str(from_agent), quote=False)
        safe_task_id = html.escape(str(task_id), quote=False)
        safe_title = html.escape(str(title), quote=False)
        text = (
            f"<b>Task accepted.</b>\n\n"
            f"From: <b>{safe_from}</b>\n"
            f"task_id: <code>{safe_task_id}</code>\n"
            f"Title: <b>{safe_title}</b>\n\n"
            f"Working on it. Will report when done."
        )
        async with aiohttp.ClientSession() as session:
            async with session.post(
                f"https://api.telegram.org/bot{token}/sendMessage",
                json={"chat_id": OWNER_CHAT_ID, "text": text, "parse_mode": "HTML"},
                timeout=aiohttp.ClientTimeout(total=10),
            ) as resp:
                if resp.status != 200:
                    log.warning(
                        "notify_owner HTTP %d: %s",
                        resp.status,
                        (await resp.text())[:200],
                    )
                else:
                    log.info(
                        "notified owner about task_id=%s from=%s", task_id, from_agent
                    )
    except Exception as exc:
        log.warning("notify_owner failed: %s", exc)


async def handle_webhook(request: web.Request) -> web.Response:
    body = await request.read()

    if not _verify_bearer(request):
        log.warning("auth failed from %s", request.remote)
        return web.Response(status=401, text="auth failed")

    try:
        payload = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        log.warning("bad payload: %s", exc)
        return web.Response(status=400, text="invalid JSON body")

    task_id = payload.get("task_id") or payload.get("_task_id") or "no-id"
    from_agent = payload.get("from_agent") or payload.get("from") or "unknown"

    # P0.5 swarm worker degraded-payload case: the worker sends task_id="no-id"
    # (and typically from_agent="unknown" + "degraded" in title). Title-only
    # missing is NOT a degraded signal — a real task with no title would be
    # silently dropped. Gate strictly on task_id.
    if task_id == "no-id":
        enriched = await _fetch_pending_task(AGENT_NAME)
        if enriched:
            from_agent = enriched["from_agent"]
            task_id = _sanitize_task_id(str(enriched["task_id"]))
            # Write enriched values back into payload so _build_prompt embeds
            # the real task_id (otherwise step 7 tells Claude to ack "no-id").
            payload["from_agent"] = from_agent
            payload["task_id"] = task_id
            payload.setdefault("title", enriched["title"])
            payload.setdefault("body", enriched["body"])
            payload["_enriched_from"] = "second_brain.list_my_pending"
            if enriched.get("delivery_id"):
                payload["_delivery_id"] = enriched["delivery_id"]
            log.info(
                "webhook enriched from second_brain: task_id=%s title=%s",
                task_id, enriched["title"],
            )
        else:
            log.info("webhook degraded and second_brain list_my_pending empty — silent ack")
            return web.json_response({"status": "empty_inbox"})
    else:
        # Non-degraded payload: still normalize task_id so downstream uses
        # the sanitized form.
        task_id = _sanitize_task_id(str(task_id))
        payload["task_id"] = task_id

    direct = await _pii_direct_needed()
    if direct:
        await _warn_direct(task_id)

    title = payload.get("title") or "(no title)"
    await _notify_owner(from_agent, task_id, title)

    prompt = _build_prompt(payload)
    # В норме вызов прежний, побайтно: флаг передаётся только в режиме напрямую.
    if direct:
        await _spawn_headless(prompt, task_id, direct=True)
    else:
        await _spawn_headless(prompt, task_id)

    log.info("webhook accepted: from=%s task_id=%s", from_agent, task_id)
    return web.json_response({"status": "accepted", "task_id": task_id})


async def handle_healthz(_: web.Request) -> web.Response:
    # Liveness probe only. Intentionally does not echo workspace path,
    # claude binary path, or any other server-side configuration — those
    # are useful only for the operator and leak deployment shape if the
    # listener is ever exposed beyond loopback.
    return web.json_response({"status": "ok"})


def make_app() -> web.Application:
    app = web.Application()
    app.router.add_post("/hooks/agent", handle_webhook)
    app.router.add_get("/healthz", handle_healthz)
    return app


def main() -> None:
    log.info(
        "starting labops-plugin-webhook on %s:%d (agent=%s workspace=%s harness=%s)",
        BIND_HOST, PORT, AGENT_NAME, AGENT_WORKSPACE, HARNESS,
    )
    web.run_app(make_app(), host=BIND_HOST, port=PORT, access_log=None)


if __name__ == "__main__":
    main()
