#!/usr/bin/env bash
#
# labops-agent-architecture — установщик.
#
# Ставит ПЕРВОГО агента — Developer (Разработчик) — end-to-end: воркспейс + второй
# мозг + Telegram + голос + автостарт, со встроенным скиллом create-agent, которым
# Developer дальше поднимает остальных агентов. В конце — self-test (gate).
#
# Ставит САМУ АРХИТЕКТУРУ: tmux/git/curl/jq/unzip, Claude Code (нативно, без
# Node.js), и клонирует (но НЕ устанавливает) соседние репозитории:
#   • labops-second-brain — общий мозг (для токена агента)
#   • labops-tg-plugin    — Telegram-канал (бот, голос)
# Каждый из соседних репозиториев ставится СВОИМ install.sh отдельной командой
# оператора — см. вывод скрипта после клонирования, либо README → Quickstart.
#
# Если запущен от root — сначала ставит системные пакеты (нужен root/sudo),
# затем предлагает создать отдельного непривилегированного пользователя
# (агенты работают с --dangerously-skip-permissions, под root это опасно) и
# продолжает остальную установку уже от его имени.
#
# Использование:
#   ./install.sh              # ОДНА команда: деплой + клонирование siblings + self-test +
#                             # авторизация Claude Code (реальный вход в браузере, если
#                             # ещё не входили) + создание Developer (интерактивно). Если
#                             # siblings ещё не установлены их собственными install.sh —
#                             # агент стартует в деградированном режиме, см. README → Quickstart.
#   ./install.sh --test-only  # только self-test
#   ./install.sh --no-agent   # подготовить + склонировать siblings, но авторизацию и
#                             # агента не выполнять (для ручного/отложенного запуска:
#                             #  claude --dangerously-skip-permissions && bash skills/create-agent/new-agent.sh)
#
# Env overrides:
#   GITHUB_TOKEN=ghp_xxx      # нужен на чистом VPS для клонирования приватных labops-*
#   SKIP_SECOND_BRAIN=1       # не клонировать labops-second-brain
#   SKIP_TG_PLUGIN=1          # не клонировать labops-tg-plugin
#   SKIP_USER_SETUP=1         # не предлагать создание отдельного пользователя для агентов

set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

C='\033[0;36m'; G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; B='\033[1m'; N='\033[0m'
say()  { printf "\n${C}▶ %s${N}\n" "$*"; }
ok()   { printf "${G}✓ %s${N}\n" "$*"; }
warn() { printf "${Y}⚠ %s${N}\n" "$*"; }
die()  { printf "${R}✗ %s${N}\n" "$*" >&2; exit 1; }

MODE="full"
[ "${1:-}" = "--test-only" ] && MODE="test"
[ "${1:-}" = "--no-agent" ] && MODE="prep"

echo "════════════════════════════════════════════"
echo "  labops-agent-architecture · установка"
echo "════════════════════════════════════════════"

# ── 1. Системные пакеты (нужен root/sudo) ─────────────────────────
# Ставим ДО создания/переключения на отдельного пользователя ниже — после
# переключения sudo у него не будет (агенты работают без sudo, см. deny-
# правило Bash(sudo *) в settings.json.template), apt-get тогда уже не поставить.
say "1. Системные пакеты"
command -v bash >/dev/null || die "нужен bash"

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

for c in git curl jq unzip; do
  command -v "$c" >/dev/null 2>&1 || install_via_pkgmgr "$c"
  command -v "$c" >/dev/null 2>&1 && ok "$c" || die "$c не удалось установить — установите вручную."
done

if ! command -v tmux >/dev/null 2>&1; then
  install_via_pkgmgr tmux
fi
command -v tmux >/dev/null 2>&1 || die "нужен tmux (рантайм агента живёт в tmux-сессии), автоустановка не удалась"
ok "tmux $(tmux -V 2>/dev/null | awk '{print $2}')"

# ── 2. Отдельный пользователь для агентов ────────────────────────
# Агенты работают с claude --dangerously-skip-permissions (без подтверждений
# на каждое действие) — держать их под root опасно: любая ошибка агента
# бьёт по всей машине. Если install.sh запущен от root (типичный чистый
# VPS), предлагаем создать непривилегированного пользователя и продолжить
# установку уже от его имени — агент и его systemd-сервис будут жить под
# ним, без sudo.
if [ "$(id -u)" -eq 0 ] && [ "$MODE" != "test" ] && [ "${SKIP_USER_SETUP:-0}" != "1" ] \
   && command -v useradd >/dev/null 2>&1; then
  say "2. Пользователь для агентов"
  echo "  Сейчас install.sh запущен от root. Рекомендуется отдельный"
  echo "  непривилегированный пользователь — под ним будут жить агенты."
  read -rp "  Создать/использовать такого пользователя? [Y/n] " _ans
  if [ "${_ans:-Y}" != "n" ] && [ "${_ans:-Y}" != "N" ]; then
    AGENT_OS_USER=""
    while [ -z "$AGENT_OS_USER" ]; do
      read -rp "  Имя пользователя для агентов: " AGENT_OS_USER
      [ -z "$AGENT_OS_USER" ] && warn "имя не может быть пустым"
    done
    if id "$AGENT_OS_USER" >/dev/null 2>&1; then
      ok "пользователь $AGENT_OS_USER уже существует"
    else
      useradd -m -s /bin/bash "$AGENT_OS_USER" || die "не удалось создать пользователя $AGENT_OS_USER"
      ok "пользователь $AGENT_OS_USER создан"
      echo "  Задайте ему пароль (нужен вам для su/ssh-входа — самому агенту он не нужен):"
      passwd "$AGENT_OS_USER" || warn "пароль не задан — задайте позже: passwd $AGENT_OS_USER"
    fi

    # Узко-scoped NOPASSWD sudo — ТОЛЬКО управление собственными
    # claude-agent-*.service юнитами (cp юнита в /etc/systemd/system,
    # systemctl daemon-reload, systemctl enable --now claude-agent-*).
    # Больше никаких sudo-прав пользователь не получает: сам агент внутри
    # Claude Code всё равно работает без sudo (deny-правило в settings),
    # это нужно только new-agent.sh для автостарта systemd-юнита без
    # ручного вмешательства оператора на каждом запуске.
    if command -v visudo >/dev/null 2>&1; then
      SUDOERS_FILE="/etc/sudoers.d/labops-agent-systemd-$AGENT_OS_USER"
      SUDOERS_TMP="$(mktemp)"
      cat > "$SUDOERS_TMP" <<SUDOERS
# Автосоздано labops-agent-architecture/install.sh. Разрешает $AGENT_OS_USER
# без пароля устанавливать и включать ТОЛЬКО claude-agent-*.service юниты.
$AGENT_OS_USER ALL=(root) NOPASSWD: /usr/bin/cp /tmp/claude-agent-*.service /etc/systemd/system/claude-agent-*.service
$AGENT_OS_USER ALL=(root) NOPASSWD: /usr/bin/systemctl daemon-reload
$AGENT_OS_USER ALL=(root) NOPASSWD: /usr/bin/systemctl enable --now claude-agent-*.service
SUDOERS
      if visudo -cf "$SUDOERS_TMP" >/dev/null 2>&1; then
        install -m 440 "$SUDOERS_TMP" "$SUDOERS_FILE"
        ok "scoped sudo для $AGENT_OS_USER: только systemd claude-agent-* юниты"
      else
        warn "sudoers-файл для $AGENT_OS_USER не прошёл проверку синтаксиса — автостарт юнита придётся включать вручную"
      fi
      rm -f "$SUDOERS_TMP"
    else
      warn "нет visudo — scoped sudo для автостарта не выдан, юнит придётся ставить вручную"
    fi

    NEW_HOME="$(getent passwd "$AGENT_OS_USER" | cut -d: -f6)"

    # Нативный claude ставится в ~/.local/bin, но сам установщик правит PATH
    # только в ~/.bashrc — при интерактивном входе (su - / ssh) claude не
    # найдётся, пока это не сделано. Дописываем один раз, идемпотентно.
    BASHRC="$NEW_HOME/.bashrc"
    PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'
    if ! grep -qsF '.local/bin' "$BASHRC"; then
      printf '\n# labops-agent-architecture: claude (нативный install) живёт тут\n%s\n' "$PATH_LINE" >> "$BASHRC"
      chown "$AGENT_OS_USER":"$AGENT_OS_USER" "$BASHRC"
      ok "PATH для ~/.local/bin дописан в $BASHRC"
    fi
    DEST_REPO="$NEW_HOME/$(basename "$REPO_DIR")"
    if [ "$REPO_DIR" != "$DEST_REPO" ]; then
      # Пересинхронизируем код в копию под отдельным пользователем при
      # КАЖДОМ запуске — копируем во временную папку рядом и атомарно
      # подменяем ею DEST_REPO. Раньше копия делалась только один раз
      # ("[ -d "$DEST_REPO/.git" ] || cp -a ..."): Ctrl+C посреди cp -a
      # оставлял битый .git прямо на месте DEST_REPO, и повторные запуски
      # install.sh тихо исполняли эту повреждённую/устаревшую копию,
      # полностью игнорируя обновления в $REPO_DIR (git pull там ни на
      # что не влиял).
      TMP_DEST="$(mktemp -d "$NEW_HOME/.$(basename "$REPO_DIR").sync.XXXXXX")"
      trap 'rm -rf "$TMP_DEST"' EXIT
      cp -a "$REPO_DIR/." "$TMP_DEST"
      rm -rf "$DEST_REPO"
      mv "$TMP_DEST" "$DEST_REPO"
      trap - EXIT
      chown -R "$AGENT_OS_USER":"$AGENT_OS_USER" "$DEST_REPO"
    fi
    ok "продолжаю установку от имени $AGENT_OS_USER"
    # -E сохраняет окружение (REUSE_EXISTING=1, SKIP_TG_PLUGIN=0 и т.п. —
    # без него sudo молча сбрасывает все такие "флаги", и они не доходят до
    # реального install.sh под labops). Мы root — sudo -E от root разрешён
    # всегда, независимо от sudoers env_keep. -H всё равно ставит HOME
    # правильно (домашняя папка labops), а не окружение вызывающего root.
    exec sudo -E -u "$AGENT_OS_USER" -H bash "$DEST_REPO/install.sh" "$@"
  else
    warn "продолжаю от root — НЕ рекомендуется для постоянной эксплуатации агентов"
  fi
fi

LAB_DIR="${CLAUDE_LAB:-$HOME/.claude-lab}"

# ── 3. Claude Code и остальное окружение ─────────────────────────
say "3. Claude Code и окружение"
# Нативный установщик claude.ai кладёт бинарник в ~/.local/bin и правит PATH
# только в ~/.bashrc — а install.sh запускается не-login шеллом (sudo -u ... -H
# bash install.sh), rc-файлы не подгружаются. Подмешиваем каталог в PATH ЗАРАНЕЕ,
# иначе уже стоящий claude не находится и install.sh на каждом запуске зря
# дёргает curl | bash (сам установщик идемпотентен и просто ничего не ставит
# повторно, но это лишняя сетевая операция и шумное предупреждение).
export PATH="$HOME/.local/bin:$PATH"
if ! command -v claude >/dev/null 2>&1; then
  warn "claude не найден — устанавливаю (curl -fsSL https://claude.ai/install.sh | bash), без Node.js"
  curl -fsSL https://claude.ai/install.sh | bash
fi
if command -v claude >/dev/null 2>&1; then
  ok "claude найден"
  echo "    Модель подключается через подписку (Max/Pro) — авторизация будет запрошена ниже, перед созданием агента, если ещё не входили."
else
  die "установка Claude Code не удалась — установите вручную: curl -fsSL https://claude.ai/install.sh | bash"
fi

if command -v systemctl >/dev/null 2>&1; then ok "systemd найден"; else
  warn "systemd (systemctl) не найден — автозапуск недоступен (Linux+systemd обязателен для сервиса)."
  warn "на macOS/без systemd агент можно запускать вручную, но не как службу."
fi
command -v python3 >/dev/null 2>&1 && ok "python3" || warn "python3 не найден (часть шагов деградирует)"

# ── 4. Клонирование соседних репозиториев (если их ещё нет) ──────
# GITHUB_TOKEN нужен только для приватного labops-second-brain на чистой
# машине без gh и без настроенного SSH-ключа. Токен передаётся через -c
# http.extraHeader только для ЭТОГО вызова git — не пишется в .git/config
# и не оседает на диске.
say "4. Клонирование соседних репозиториев"
clone_repo() {
  local name="$1" url="$2" dest="$3"
  if [ -d "$dest/.git" ]; then
    ok "$name уже на месте: $dest"
    return 0
  fi
  say "Клонирую $name → $dest"
  local err_log; err_log="$(mktemp)"
  if git clone --depth=1 "$url" "$dest" 2>"$err_log"; then
    ok "$name склонирован"
  elif [ -n "${GITHUB_TOKEN:-}" ]; then
    warn "$name недоступен анонимно (приватный?) — пробую с GITHUB_TOKEN"
    local auth_header
    auth_header="Authorization: basic $(printf 'x-access-token:%s' "$GITHUB_TOKEN" | base64 -w0)"
    if git -c http.extraHeader="$auth_header" clone --depth=1 "$url" "$dest" 2>"$err_log"; then
      ok "$name склонирован (по GITHUB_TOKEN)"
    else
      cat "$err_log" >&2
      die "$name: клонирование не удалось даже с GITHUB_TOKEN — проверьте, что токен выпущен для аккаунта-владельца репозитория и имеет право Contents:Read на $name."
    fi
  else
    cat "$err_log" >&2
    die "$name недоступен анонимно (репозиторий приватный?) и GITHUB_TOKEN не задан.
    На чистом сервере без gh/SSH экспортируйте токен и перезапустите:
      GITHUB_TOKEN=ghp_xxx ./install.sh
    Либо склонируйте вручную и перезапустите install.sh:
      git clone $url $dest"
  fi
  rm -f "$err_log"
}

if [ "$MODE" != "test" ]; then

SB="${SECOND_BRAIN_DIR:-$HOME/labops-second-brain}"
if [ "${SKIP_SECOND_BRAIN:-0}" != "1" ]; then
  clone_repo "labops-second-brain" "https://github.com/dediukhinpa/labops-second-brain.git" "$SB"
else
  warn "labops-second-brain пропущен (SKIP_SECOND_BRAIN=1) — токен агента придётся ввести вручную"
  SB=""
fi

TG="${TG_PLUGIN_DIR:-$HOME/labops-tg-plugin}"
if [ "${SKIP_TG_PLUGIN:-0}" != "1" ]; then
  clone_repo "labops-tg-plugin" "https://github.com/dediukhinpa/labops-tg-plugin.git" "$TG"
else
  warn "labops-tg-plugin пропущен (SKIP_TG_PLUGIN=1) — Telegram-канал будет пропущен"
  TG=""
fi

fi  # [ "$MODE" != "test" ]

# скрипты должны быть исполняемыми
chmod +x "$REPO_DIR"/test.sh "$REPO_DIR"/orchestration/*.sh "$REPO_DIR"/skills/create-agent/*.sh \
         "$REPO_DIR"/agent-template/install.sh 2>/dev/null || true

# ── 5. Self-test (gate) ──────────────────────────────────────────
say "5. Self-test репозитория"
bash "$REPO_DIR/test.sh" || die "self-test провален — установка остановлена."

[ "$MODE" = "test" ] && { ok "только self-test — готово."; exit 0; }

# ── 6. Первый агент — Developer ──────────────────────────────────
if [ "$MODE" = "prep" ]; then
  say "Подготовка завершена (--no-agent). Чтобы создать первого агента:"
  echo "    claude --dangerously-skip-permissions   # один раз, войдите в браузере, затем /exit"
  echo "    bash skills/create-agent/new-agent.sh"
  exit 0
fi

say "6. Первый агент — Developer (Разработчик)"
echo "  Developer — кодер и «прораб»: он же дальше поднимает остальных агентов"
echo "  своим скиллом create-agent. Сейчас проведём его настройку."
echo

# Авторизация Claude Code — нужна ДО создания агента (иначе агент не достучится
# до модели). Все агенты этого пользователя запускаются как персистентная TUI-
# сессия (orchestration/start-agent.sh: "claude --dangerously-skip-permissions",
# БЕЗ -p) — а не headless. TUI-сессия проверяет ТОЛЬКО ~/.claude/.credentials.json
# и не читает CLAUDE_CODE_OAUTH_TOKEN вообще (подтверждено эмпирически: с
# валидным токеном в окружении "claude -p" отвечает, а голый "claude
# --dangerously-skip-permissions" всё равно показывает экран логина). Поэтому
# headless-путь ("claude setup-token" + CLAUDE_CODE_OAUTH_TOKEN) не используется
# нигде в этой архитектуре — единственная авторизация ниже. Файл — на уровне
# $HOME, не на уровне агента: все агенты этого пользователя используют одну и
# ту же сессию, входить нужно один раз на пользователя, не на агента.
# Проверяет не просто наличие файла, а что в нём реально лежит непустой
# accessToken — claude может создать файл раньше, чем допишет в него токен
# (или оставить пустой {} при прерванном логине), простой "-f" это не ловит.
creds_valid() {
  local f="$HOME/.claude/.credentials.json"
  [ -s "$f" ] || return 1
  local token
  token="$(jq -r '.claudeAiOauth.accessToken // empty' "$f" 2>/dev/null)" || return 1
  [ -n "$token" ]
}

if creds_valid; then
  ok "Claude Code уже авторизован (\$HOME/.claude/.credentials.json)"
else
  say "Вход в Claude Code (подписка Max/Pro)"
  echo "  Сейчас подключу вас к сессии логина в этом же терминале."
  echo "  Экран логина сам не появляется: сначала claude спросит про"
  echo "  доверие папке (Yes, I trust this folder) и сразу откроет"
  echo "  обычный рабочий интерфейс — внизу будет мелкая надпись"
  echo "  'Not logged in · Run /login'. Наберите там команду /login и"
  echo "  нажмите Enter — вот тогда появится ссылка для входа в браузере."
  echo "  Как только вход завершится, установщик сам это обнаружит и"
  echo "  закроет сессию — руками жать /exit не нужно."
  read -rp "  Нажмите Enter, чтобы продолжить... " _

  LOGIN_SESSION="installer-login-$$"
  tmux new-session -d -s "$LOGIN_SESSION" \
    "claude --dangerously-skip-permissions; sleep 2"

  # Фоновый вотчер: параллельно с тем, что пользователь сидит внутри
  # tmux attach (см. ниже), следит за появлением валидного токена и сам
  # завершает сессию логина — пользователю не нужен второй терминал.
  (
    LOGIN_TIMEOUT=300
    LOGIN_WAITED=0
    while ! creds_valid; do
      if ! tmux has-session -t "$LOGIN_SESSION" 2>/dev/null; then
        exit 0
      fi
      if [ "$LOGIN_WAITED" -ge "$LOGIN_TIMEOUT" ]; then
        exit 0
      fi
      sleep 3
      LOGIN_WAITED=$((LOGIN_WAITED + 3))
    done
    tmux send-keys -t "$LOGIN_SESSION" "/exit" Enter
    sleep 2
    tmux kill-session -t "$LOGIN_SESSION" 2>/dev/null || true
  ) &
  LOGIN_WATCHER_PID=$!

  tmux attach -t "$LOGIN_SESSION" 2>/dev/null || true
  wait "$LOGIN_WATCHER_PID" 2>/dev/null || true

  if creds_valid; then
    tmux kill-session -t "$LOGIN_SESSION" 2>/dev/null || true
    ok "Claude Code авторизован (\$HOME/.claude/.credentials.json)"
  else
    die "вход не завершён (валидный accessToken в \$HOME/.claude/.credentials.json так и не появился) — перезапустите ./install.sh, когда будете готовы войти."
  fi
fi

[ -n "$TG" ] && [ ! -d "$TG/plugin/node_modules" ] && \
  warn "labops-tg-plugin ещё не установлен ($TG) — Telegram-канал будет недоступен, пока не выполните: cd $TG && ./install.sh"
[ -n "$SB" ] && [ ! -x "$SB/.venv/bin/python" ] && \
  warn "labops-second-brain ещё не установлен ($SB) — токен агента придётся ввести вручную позже, см. вывод выше"
export AGENT_NAME="${AGENT_NAME:-Developer}"
export AGENT_ROLE="${AGENT_ROLE:-Разработчик}"
export AGENT_ROLE_DESCRIPTION="${AGENT_ROLE_DESCRIPTION:-Автономный разработчик: пишет код, ревьюит архитектуру, гоняет тесты и помогает оператору создавать новых агентов.}"
[ -n "$SB" ] && export SECOND_BRAIN_DIR="$SB"
[ -n "$TG" ] && export TG_PLUGIN_DIR="$TG"

bash "$REPO_DIR/skills/create-agent/new-agent.sh"

# убедимся, что у Developer есть скилл create-agent (чтобы ставить следующих)
DEV_WS="$LAB_DIR/$(echo "$AGENT_NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')/.claude"
if [ -d "$DEV_WS" ] && [ ! -e "$DEV_WS/skills/create-agent" ]; then
  mkdir -p "$DEV_WS/skills"
  ln -s "$REPO_DIR/skills/create-agent" "$DEV_WS/skills/create-agent" 2>/dev/null \
    && ok "скилл create-agent подключён в воркспейс Developer"
fi

say "Готово."
printf "  ${G}Developer создан.${N} Напишите ему в Telegram, либо запустите вручную:\n"
printf "    ${B}source %s/agent.env && claude --project %s${N}\n" "$DEV_WS" "$DEV_WS"
echo "  Чтобы добавить следующего агента — попросите Developer «Создай нового агента»"
echo "  (он применит скилл create-agent) или запустите:"
printf "    ${B}bash skills/create-agent/new-agent.sh${N}\n"
