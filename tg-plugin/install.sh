#!/usr/bin/env bash
#
# labops-tg-plugin — установщик.
# Идемпотентен: доустанавливает недостающие зависимости, ставит зависимости
# плагина, регистрирует хуки Claude Code и в конце ПРОГОНЯЕТ тесты репозитория.
# Установка считается успешной только при зелёных тестах.
#
# Использование:
#   ./install.sh            # полная установка + тесты
#   ./install.sh --no-tests # без финального прогона (не рекомендуется)

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$REPO_DIR/plugin"
RUN_TESTS=1
[ "${1:-}" = "--no-tests" ] && RUN_TESTS=0

say()  { printf '\n\033[1;36m▶ %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m⚠ %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# Накопитель degraded/пропущенных шагов — чтобы зелёный финал не скрыл дыры.
SKIPPED=()
skip() { warn "$*"; SKIPPED+=("$*"); }

REQUIRED_CLAUDE="2.1.80"
# ver_ge A B → истина, если версия A >= версии B.
ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]; }

# root не нуждается в sudo, а на голых серверах его вообще может не быть.
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  command -v sudo >/dev/null 2>&1 && SUDO="sudo"
fi

# Ставит системный пакет через доступный пакетный менеджер.
# Linux → apt-get (sudo, если не root). macOS → brew.
install_via_pkgmgr() {
  local pkg="$1"
  if command -v apt-get >/dev/null 2>&1; then
    warn "$pkg не найден — устанавливаю через apt-get${SUDO:+ (sudo)}"
    $SUDO apt-get update -y
    $SUDO apt-get install -y "$pkg"
  elif command -v brew >/dev/null 2>&1; then
    warn "$pkg не найден — устанавливаю через brew"
    brew install "$pkg"
  else
    die "$pkg не найден и не найден ни apt-get, ни brew — установите $pkg вручную."
  fi
}

# ─── 1. Зависимости окружения (доустанавливаем при отсутствии) ───
say "Проверка окружения"

# bun-installer сам требует unzip — ставим заранее, иначе он падает с
# "unzip is required to install bun".
if ! command -v unzip >/dev/null 2>&1; then
  install_via_pkgmgr unzip
fi

if ! command -v bun >/dev/null 2>&1; then
  warn "bun не найден — устанавливаю (curl -fsSL https://bun.sh/install | bash)"
  curl -fsSL https://bun.sh/install | bash
  export PATH="$HOME/.bun/bin:$PATH"
fi
command -v bun >/dev/null 2>&1 || die "Установка bun не удалась — установите вручную: curl -fsSL https://bun.sh/install | bash"
ok "bun $(bun --version)"

if ! command -v tmux >/dev/null 2>&1; then
  install_via_pkgmgr tmux
fi
command -v tmux >/dev/null 2>&1 || die "Установка tmux не удалась — установите вручную."
ok "tmux $(tmux -V 2>/dev/null | awk '{print $2}')"

if ! command -v claude >/dev/null 2>&1; then
  warn "claude не найден — устанавливаю (curl -fsSL https://claude.ai/install.sh | bash)"
  curl -fsSL https://claude.ai/install.sh | bash
  export PATH="$HOME/.local/bin:$PATH"
fi
command -v claude >/dev/null 2>&1 || die "Установка Claude Code не удалась — установите вручную: https://docs.claude.com/en/docs/claude-code"

CLAUDE_VER="$(claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
if [ -n "$CLAUDE_VER" ] && ! ver_ge "$CLAUDE_VER" "$REQUIRED_CLAUDE"; then
  warn "claude $CLAUDE_VER ниже требуемой v$REQUIRED_CLAUDE — пробую обновить (claude update)"
  claude update || true
  CLAUDE_VER="$(claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
fi

if [ -z "$CLAUDE_VER" ]; then
  skip "не удалось определить версию claude (требуется ≥ v$REQUIRED_CLAUDE) — проверьте вручную"
elif ver_ge "$CLAUDE_VER" "$REQUIRED_CLAUDE"; then
  ok "claude $CLAUDE_VER (требуется ≥ v$REQUIRED_CLAUDE)"
else
  die "claude $CLAUDE_VER ниже требуемой v$REQUIRED_CLAUDE даже после попытки обновления. Обновите Claude Code вручную."
fi

# ─── 2. Зависимости плагина ──────────────────────────────────────
say "Установка зависимостей плагина (bun install)"
( cd "$PLUGIN_DIR" && bun install )
ok "зависимости установлены"

# ─── 3. Хуки Claude Code ─────────────────────────────────────────
say "Регистрация хуков Claude Code"
if [ -x "$PLUGIN_DIR/scripts/install-hooks.sh" ]; then
  # install-hooks.sh требует --settings/--chat-id/--webhook-url, которых на
  # этапе установки ещё нет (channel.env не заполнен). В АГЕНТСКОМ флоу хуки и
  # так приходят из settings.json воркспейса (agent-template), поэтому провал
  # здесь ожидаем и безвреден — НЕ печатаем ложное "зарегистрированы".
  if ( cd "$PLUGIN_DIR" && ./scripts/install-hooks.sh >/dev/null 2>&1 ); then
    ok "хуки зарегистрированы"
  else
    skip "хуки сейчас не зарегистрированы (install-hooks.sh требует --settings/--chat-id/--webhook-url). В агентском флоу они берутся из settings.json воркспейса; для standalone-деплоя запустите скрипт вручную с этими аргументами после настройки channel.env (docs/06)"
  fi
else
  skip "scripts/install-hooks.sh не найден или не исполняемый — хуки НЕ зарегистрированы"
fi

# ─── 4. Конфиг ───────────────────────────────────────────────────
say "Конфигурация"
echo "  Скопируйте examples/channel.env.example → /etc/labops-plugin/<agent>/channel.env"
echo "  и заполните TELEGRAM_BOT_TOKEN / allowlist / workspace (см. README → Переменные окружения,"
echo "  пошагово — docs/telegram-setup.md)."

# Best-effort валидация channel.env: если знаем путь — проверяем наличие токена,
# но НЕ печатаем его значение. Путь можно задать через CHANNEL_ENV=...
CHANNEL_ENV_CANDIDATES=()
[ -n "${CHANNEL_ENV:-}" ] && CHANNEL_ENV_CANDIDATES+=("$CHANNEL_ENV")
[ -n "${AGENT_ID:-}" ] && CHANNEL_ENV_CANDIDATES+=("/etc/labops-plugin/$AGENT_ID/channel.env")

FOUND_ENV=""
for c in "${CHANNEL_ENV_CANDIDATES[@]:-}"; do
  [ -n "$c" ] && [ -f "$c" ] && { FOUND_ENV="$c"; break; }
done

if [ -n "$FOUND_ENV" ]; then
  if grep -Eq '^[[:space:]]*TELEGRAM_BOT_TOKEN=[^[:space:]].+' "$FOUND_ENV"; then
    ok "channel.env найден и TELEGRAM_BOT_TOKEN задан ($FOUND_ENV)"
  else
    die "channel.env найден ($FOUND_ENV), но TELEGRAM_BOT_TOKEN не задан — заполните перед запуском."
  fi
else
  skip "channel.env не найден/не проверен — создайте его и задайте TELEGRAM_BOT_TOKEN (CHANNEL_ENV=/path для проверки)"
fi

# ─── 5. Тесты (обязательный финальный шаг) ───────────────────────
if [ "$RUN_TESTS" -eq 1 ]; then
  say "Прогон тестов репозитория"

  echo "— TypeScript/Bun —"
  ( cd "$PLUGIN_DIR" && bun test ) || die "bun test провалился — установка НЕ подтверждена."
  ok "bun test зелёный"

  echo "— Python (supervisor/webhook/доки) —"
  if ! command -v python3 >/dev/null 2>&1; then
    install_via_pkgmgr python3
  fi
  if command -v python3 >/dev/null 2>&1; then
    VENV="$REPO_DIR/.venv"
    # python3 -m venv нуждается в пакете python3-venv (на Debian/Ubuntu его нет
    # по умолчанию → "ensurepip is not available"). В штатном флоу его ставит
    # agent-architecture/install.sh под root заранее; здесь — запасная попытка
    # (сработает только если у пользователя есть sudo на apt).
    if [ ! -d "$VENV" ] && ! python3 -m venv "$VENV" 2>/dev/null; then
      PYVER="$(python3 -c 'import sys;print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || true)"
      [ -n "$PYVER" ] && { install_via_pkgmgr "python${PYVER}-venv" || true; }
      python3 -c 'import ensurepip, venv' >/dev/null 2>&1 || install_via_pkgmgr "python3-venv" || true
      python3 -m venv "$VENV" 2>/dev/null || true
    fi
    if [ -d "$VENV" ] && [ -x "$VENV/bin/python" ]; then
      "$VENV/bin/pip" install -q --upgrade pip >/dev/null 2>&1 || true
      "$VENV/bin/pip" install -q pytest >/dev/null 2>&1
      [ -f "$REPO_DIR/webhook-listener/requirements.txt" ] && \
        "$VENV/bin/pip" install -q -r "$REPO_DIR/webhook-listener/requirements.txt" >/dev/null 2>&1 || true
      ( cd "$REPO_DIR" && "$VENV/bin/python" -m pytest tests/ -q ) || die "pytest провалился — установка НЕ подтверждена."
      ok "pytest зелёный"
    else
      # venv создать не удалось (нет python3-venv и нет прав доставить его).
      # Это ОПЦИОНАЛЬНЫЙ Python-листенер, не роняем всю установку канала.
      skip "python venv не создан (нет пакета python3-venv) — Python-часть (webhook/supervisor) пропущена; поставьте: sudo apt install python3-venv"
    fi
  else
    skip "python3 не найден и не удалось установить — python-тесты (supervisor/webhook/доки) НЕ прогнаны"
  fi
else
  skip "тесты пропущены (--no-tests) — установка НЕ подтверждена тестами"
fi

# ─── 6. Финальный статус (degraded-шаги видны явно) ──────────────
if [ "${#SKIPPED[@]}" -gt 0 ]; then
  printf '\n\033[1;33m⚠ Установка ЗАВЕРШЕНА, но с пропущенными/degraded шагами:\033[0m\n'
  for s in "${SKIPPED[@]}"; do printf '   • %s\n' "$s"; done
  printf '\033[1;33m  Зелёный финал НЕ означает полностью рабочий сетап — закройте пункты выше.\033[0m\n'
else
  printf '\n\033[1;32m✅ Установка подтверждена: все проверки и тесты прошли, ничего не пропущено.\033[0m\n'
fi

cat <<'NEXT'

Дальше:
  • docs/02-where-to-place-plugin.md — куда класть плагин (критично)
  • docs/03-installation-linux.md / -macos.md — автостарт (systemd/launchd)
  • README.md → Связанные репозитории — second-brain и agent-architecture
NEXT
