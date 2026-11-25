#!/usr/bin/env bash
# switch-harness.sh <claude|codex> — перевод ВСЕГО роя на другой харнес одной командой.
#
# Харнес (claude | codex) один на весь рой и хранится в shared/swarm.env. Установщик менять
# его у существующего роя отказывается — это «отдельная процедура». Вот она: команда сама
# делает всё, без ручных доп. настроек оператора:
#   1) бэкап воркспейсов и swarm.env (откат при сбое);
#   2) доустановка рантайма целевого харнеса, если его нет (бинарь CLI и окружение);
#   3) вход в целевую подписку, ВСТРОЕННЫЙ в команду (codex: codex login --device-auth;
#      claude: интерактивный /login) — пропускается, если уже залогинено;
#   4) для codex — поднять pii-proxy (без него codex-агент стартовать откажется);
#   5) пауза роя и остановка процессов текущим стоппером;
#   6) конвертация каждого агента: идентичность CLAUDE.md⇄AGENTS.src.md, модель/MCP
#      settings.json+.mcp.json ⇄ .codex/config.toml — из той же «души» и памяти (core/,
#      channel.env, agent.env/bearer сохраняются как есть);
#   7) переключение swarm.env (harness_switch_swarm);
#   8) перезапуск юнитов и проверка готовности; при сбое — автоматический откат.
#
# Запускать ОТ ПОЛЬЗОВАТЕЛЯ АГЕНТОВ (у него лаборатория и swarm.env), не от root.
#
# Использование:
#   bash switch-harness.sh codex            # перевести рой на Codex (ChatGPT)
#   bash switch-harness.sh claude           # перевести рой на Claude Code
#   bash switch-harness.sh codex --dry-run  # показать план, ничего не меняя
#
# Переменные:
#   PRIMARY_MODEL=<модель>   модель для всех агентов после перехода (умолчание — дефолт
#                            целевого харнеса: sonnet для claude, gpt-6.2-sol для codex)
#   SKIP_LOGIN=1             не выполнять встроенный вход (если подписка уже готова)
#   SKIP_RUNTIME_INSTALL=1   не доустанавливать рантайм (если бинарь целевого харнеса уже есть)
#   SKIP_PII_PROXY=1         не поднимать pii-proxy (codex) — только если он уже настроен
#   CLAUDE_LAB=<путь>        нестандартная лаборатория (по умолчанию ~/.claude-lab)

set -euo pipefail
# Минимальный PATH systemd не включает ~/.local/bin, где живут нативные claude/codex.
export PATH="$HOME/.local/bin:$PATH"

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/agents.sh
source "$HERE/lib/agents.sh"
# shellcheck source=lib/harness.sh
source "$HERE/lib/harness.sh"
# shellcheck source=lib/codex-watch.sh
source "$HERE/lib/codex-watch.sh"
# shellcheck source=lib/codex-install.sh
source "$HERE/lib/codex-install.sh"
# shellcheck source=lib/pii.sh
source "$HERE/lib/pii.sh"
# shellcheck source=lib/harness-convert.sh
source "$HERE/lib/harness-convert.sh"

log()  { printf '[switch-harness] %s\n' "$*"; }
step() { printf '\n[switch-harness] == %s ==\n' "$*"; }
warn() { printf '[switch-harness] ВНИМАНИЕ: %s\n' "$*" >&2; }
die()  { printf '[switch-harness] ОШИБКА: %s\n' "$*" >&2; exit 1; }

# ── Аргументы ─────────────────────────────────────────────────────
TARGET=""
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    claude|codex) TARGET="$arg" ;;
    --dry-run)    DRY_RUN=1 ;;
    -h|--help)    sed -n '2,27p' "$0"; exit 0 ;;
    *)            die "неизвестный аргумент: $arg (ожидается: claude|codex [--dry-run])" ;;
  esac
done
[ -n "$TARGET" ] || die "не указан целевой харнес: claude или codex"
harness_is_known "$TARGET" || die "неизвестный харнес '$TARGET' (ожидается: $HARNESS_KNOWN)"

if [ "$(id -u)" -eq 0 ]; then
  die "запусти от пользователя агентов, не от root (swarm.env лежит в его лаборатории)."
fi

# ── Предполётная проверка ─────────────────────────────────────────
CURRENT="$(harness_current)" || die "не удалось прочитать текущий харнес из swarm.env"
LAB="${CLAUDE_LAB:-$HOME/.claude-lab}"
MODEL="${PRIMARY_MODEL:-$(harness_default_model "$TARGET")}"

mapfile -t AGENTS < <(list_agents)
if [ "${#AGENTS[@]}" -eq 0 ]; then
  die "в лаборатории $LAB нет агентов — переключать нечего (для нового роя просто поставь его на нужном харнесе)."
fi

log "рой: $LAB"
log "агенты (${#AGENTS[@]}): ${AGENTS[*]}"
log "харнес: $CURRENT → $TARGET"
log "модель после перехода: $MODEL"
[ "${SKIP_LOGIN:-0}" = "1" ] && log "встроенный вход: пропущен (SKIP_LOGIN=1)"
[ "$DRY_RUN" = "1" ] && log "режим: --dry-run (ничего не меняется)"

if [ "$CURRENT" = "$TARGET" ]; then
  log "рой уже на $TARGET — делать нечего."
  exit 0
fi

# ── Бэкап (всегда, даже при недоделанных шагах ниже) ──────────────
TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$LAB/shared/backups/harness-switch-$CURRENT-to-$TARGET-$TS"
backup_all() {
  step "Бэкап → $BACKUP_DIR"
  if [ "$DRY_RUN" = "1" ]; then
    log "· (план) бэкап swarm.env, shared/codex и воркспейсов ${AGENTS[*]}"
    return 0
  fi
  mkdir -p "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR"
  # swarm.env и общий вход codex.
  [ -f "$LAB/shared/swarm.env" ] && cp -a "$LAB/shared/swarm.env" "$BACKUP_DIR/"
  [ -d "$LAB/shared/codex" ] && cp -a "$LAB/shared/codex" "$BACKUP_DIR/shared-codex" 2>/dev/null || true
  # Воркспейсы агентов: харнес-специфичные конфиги и идентичность. node_modules не тащим.
  local a
  for a in "${AGENTS[@]}"; do
    [ -d "$LAB/$a" ] || continue
    tar -C "$LAB" \
      --exclude='*/node_modules' --exclude='*/.git' \
      -czf "$BACKUP_DIR/$a.tgz" \
      "$a/.claude" "$a/.codex" 2>/dev/null || tar -C "$LAB" \
        --exclude='*/node_modules' --exclude='*/.git' \
        -czf "$BACKUP_DIR/$a.tgz" "$a/.claude" 2>/dev/null || true
  done
  log "бэкап готов ($(find "$BACKUP_DIR" -type f | wc -l) файлов)"
}

# ── Шаг 2: доустановка рантайма целевого харнеса ──────────────────
# Нативные бинари ставятся под ~/.local (без root). codex_install_pinned идемпотентен; claude
# ставим его же официальным установщиком, только если бинаря ещё нет (при codex→claude его может
# не быть вовсе — требование владельца доустанавливать окружение целевого харнеса).
install_claude_runtime() {
  command -v claude >/dev/null 2>&1 && { log "claude уже установлен: $(command -v claude)"; return 0; }
  log "ставлю Claude Code CLI (нативный бинарь в ~/.local/bin)…"
  local tmp; tmp="$(mktemp)"
  if curl -fsSL https://claude.ai/install.sh -o "$tmp" \
     || curl -fsSL https://downloads.claude.ai/claude-code-releases/bootstrap.sh -o "$tmp"; then
    bash "$tmp"; local rc=$?; rm -f "$tmp"
    [ "$rc" -eq 0 ] || return 1
  else
    rm -f "$tmp"; return 1
  fi
  command -v claude >/dev/null 2>&1
}
ensure_runtime() {
  step "Доустановка рантайма ($TARGET), если нужно"
  if [ "${SKIP_RUNTIME_INSTALL:-0}" = "1" ]; then log "рантайм: доустановка пропущена (SKIP_RUNTIME_INSTALL=1)"; return 0; fi
  if [ "$DRY_RUN" = "1" ]; then
    log "· (план) проверить бинарь $TARGET и доустановить при отсутствии (под ~/.local, без root)"
    return 0
  fi
  case "$TARGET" in
    claude) install_claude_runtime || die "не удалось установить Claude Code CLI" ;;
    codex)  { out="$(codex_install_pinned)" && log "codex готов: $out"; } || die "не удалось установить Codex CLI" ;;
  esac
}

# ── Шаг 3: встроенный вход в целевую подписку ─────────────────────
# Headless-токены для агентского трафика запрещены правилом репо — вход интерактивный, но вшит
# в команду (оператор проходит его один раз здесь же). Пропускается, если уже залогинено.
creds_valid() {  # claude: валиден ли OAuth-токен на диске
  local f="$HOME/.claude/.credentials.json"
  [ -s "$f" ] || return 1
  [ -n "$(jq -r '.claudeAiOauth.accessToken // empty' "$f" 2>/dev/null)" ]
}
login_claude_interactive() {
  command -v tmux >/dev/null 2>&1 || { warn "нет tmux для входа claude"; return 1; }
  local sess="labops-login-$$"
  log "claude: нужен вход. В ДРУГОМ терминале на этом сервере выполни:  tmux attach -t =$sess"  # tmux-target-ok: текст подсказки оператору, не вызов tmux; цель уже точная (=$sess)
  log "       внутри набери /login и пройди вход — окно закроется само."
  tmux new-session -d -s "$sess" "claude --dangerously-skip-permissions" 2>/dev/null || return 1
  local i=0 max="${CLAUDE_LOGIN_WAIT:-300}"
  while [ "$i" -lt "$max" ]; do creds_valid && break; sleep 3; i=$((i + 3)); done
  tmux kill-session -t "=$sess" 2>/dev/null || true
  creds_valid
}
ensure_login() {
  if [ "${SKIP_LOGIN:-0}" = "1" ]; then log "встроенный вход: пропущен (SKIP_LOGIN=1)"; return 0; fi
  step "Встроенный вход в подписку $TARGET"
  if [ "$DRY_RUN" = "1" ]; then
    log "· (план) войти в $TARGET, если не залогинено (codex: login --device-auth; claude: /login в tmux)"
    return 0
  fi
  if [ "$TARGET" = codex ]; then
    local home; home="$(codex_shared_home)"
    mkdir -p "$home"; chmod 700 "$home"
    if [ "$(codex_auth_state_home "$home" 2>/dev/null)" = chatgpt ]; then
      log "codex: уже залогинен в ChatGPT — вход не нужен"; return 0
    fi
    log "codex: вход в ChatGPT (открой ссылку, введи код — один раз):"
    CODEX_HOME="$home" "$(codex_bin)" login --device-auth || die "вход codex не удался"
    [ "$(codex_auth_state_home "$home" 2>/dev/null)" = chatgpt ] || die "после входа codex состояние не 'chatgpt'"
  else
    if creds_valid; then log "claude: уже залогинен — вход не нужен"; return 0; fi
    login_claude_interactive || die "вход claude не удался (нет валидного токена)"
  fi
}

# ── Шаг 4: pii-proxy (только codex; без него codex-агент стартовать откажется) ──
ensure_pii() {
  [ "$TARGET" = codex ] || return 0
  step "Поднять pii-proxy (обязателен для codex)"
  if [ "$DRY_RUN" = "1" ]; then
    log "· (план) pii-setup.sh host + agent <id> для каждого агента (systemctl --user, без root)"
    return 0
  fi
  if [ "${SKIP_PII_PROXY:-0}" = "1" ]; then log "pii-proxy: пропущен (SKIP_PII_PROXY=1)"; return 0; fi
  bash "$HERE/pii-setup.sh" host || die "не удалось поднять host pii-proxy"
  local a
  for a in "${AGENTS[@]}"; do
    bash "$HERE/pii-setup.sh" agent "$a" || die "не удалось настроить pii-proxy для агента $a"
  done
}

# ── Шаг 5: пред-посев идентичности (безопасно, до точки невозврата) ──
# Создаёт файл идентичности целевого харнеса из существующей «души». Инертен до флипа, поэтому
# делаем ДО остановки/флипа: если вход/pii/рантайм упадут — рой не тронут, бэкап на месте.
preseed_all() {
  step "Пред-посев идентичности из «души» ($TARGET)"
  if [ "$DRY_RUN" = "1" ]; then
    log "· (план) создать идентичность $TARGET из существующей, сохранив ручные правки побайтно"
    return 0
  fi
  local a ws
  for a in "${AGENTS[@]}"; do
    ws="$LAB/$a/.claude"
    [ -d "$ws" ] || { warn "$a: нет воркспейса — пропуск"; continue; }
    harness_preseed_identity "$ws" "$TARGET" "$a" || die "$a: посев идентичности не удался"
  done
}

# ── Управление юнитом агента ──────────────────────────────────────
# По умолчанию systemctl (user-юнит, иначе системный через scoped sudo). Тесты переопределяют
# SWITCH_UNITCTL (например =true) — тогда без реального systemd.
agent_unit_cmd() {  # <action> <agent>
  local action="$1" agent="$2"
  local unit="claude-agent-$agent.service"
  if [ -n "${SWITCH_UNITCTL:-}" ]; then $SWITCH_UNITCTL "$action" "$unit"; return $?; fi
  if systemctl --user cat "$unit" >/dev/null 2>&1; then
    systemctl --user "$action" "$unit"
  else
    sudo -n systemctl "$action" "$unit"
  fi
}
agent_ready() {  # <agent>: поднялась ли tmux-сессия агента
  [ -n "${SWITCH_UNITCTL:-}" ] && return 0            # в тестах юниты замоканы
  local a="$1" i=0 max="${SWITCH_READY_WAIT:-60}"
  while [ "$i" -lt "$max" ]; do
    tmux has-session -t "=labops-$a" 2>/dev/null && return 0
    sleep 2; i=$((i + 2))
  done
  return 1
}

# ── Точка невозврата: стоп → флип → конвертация → рестарт ──────────
stop_all() {
  step "Пауза роя и остановка агентов ($CURRENT)"
  [ "$DRY_RUN" = "1" ] && { log "· (план) stop-mark + остановка юнитов всех агентов"; return 0; }
  local a
  for a in "${AGENTS[@]}"; do
    agent_stop_mark "$a" 2>/dev/null || true          # watchdog не перезапустит во время свопа
    agent_unit_cmd stop "$a" || warn "$a: остановка юнита вернула ошибку (возможно уже остановлен)"
  done
  return 0
}
flip_swarm() {
  step "Переключение swarm.env → $TARGET"
  [ "$DRY_RUN" = "1" ] && { log "· (план) harness_switch_swarm $TARGET"; return 0; }
  harness_switch_swarm "$TARGET"
}
convert_all() {
  step "Конвертация воркспейсов → $TARGET (модель: $MODEL)"
  [ "$DRY_RUN" = "1" ] && { log "· (план) рендер конфигов $TARGET поверх воркспейсов (память сохраняется)"; return 0; }
  local a ws
  for a in "${AGENTS[@]}"; do
    ws="$LAB/$a/.claude"
    [ -d "$ws" ] || continue
    harness_render_agent "$a" "$TARGET" "$MODEL" >/dev/null || { warn "$a: рендер конфигов $TARGET не удался"; return 1; }
    if [ "$TARGET" = claude ]; then
      harness_reverse_adapt_core "$ws" "$a" || warn "$a: обратная адаптация доков памяти не удалась"
    fi
  done
  return 0
}
restart_all() {
  step "Перезапуск юнитов и проверка готовности"
  [ "$DRY_RUN" = "1" ] && { log "· (план) перезапуск юнитов + ожидание готовности агентов"; return 0; }
  local a
  for a in "${AGENTS[@]}"; do
    agent_unit_cmd restart "$a" || { warn "$a: перезапуск юнита не удался"; return 1; }
  done
  for a in "${AGENTS[@]}"; do
    agent_ready "$a" || { warn "$a: агент не поднялся за ${SWITCH_READY_WAIT:-60}s"; return 1; }
  done
  return 0
}
rollback() {
  warn "СБОЙ перехода — откат из бэкапа $BACKUP_DIR"
  local a
  harness_switch_swarm "$CURRENT" 2>/dev/null || true
  [ -f "$BACKUP_DIR/swarm.env" ] && cp -a "$BACKUP_DIR/swarm.env" "$LAB/shared/swarm.env"
  for a in "${AGENTS[@]}"; do
    if [ -f "$BACKUP_DIR/$a.tgz" ]; then
      rm -rf "$LAB/$a/.claude" "$LAB/$a/.codex"
      tar -C "$LAB" -xzf "$BACKUP_DIR/$a.tgz" 2>/dev/null || warn "$a: распаковка бэкапа не удалась"
    fi
  done
  for a in "${AGENTS[@]}"; do agent_unit_cmd restart "$a" 2>/dev/null || true; done
  die "переход откатан к $CURRENT. Бэкап сохранён: $BACKUP_DIR"
}

# ── Конвейер перехода ─────────────────────────────────────────────
# Порядок важен: всё до флипа обратимо (при сбое просто die, рой не тронут, бэкап на месте);
# начиная со стопа — точка невозврата, любой сбой запускает автоматический откат.
backup_all
ensure_runtime
ensure_login
ensure_pii
preseed_all

stop_all    || rollback
flip_swarm  || rollback
convert_all || rollback
restart_all || rollback

if [ "$DRY_RUN" = "1" ]; then
  log "dry-run завершён — изменений не внесено."
  exit 0
fi

step "Готово: рой переведён $CURRENT → $TARGET (модель: $MODEL)"
log "диалоговая история не переносится — агенты стартовали свежими сессиями; память в core/ цела, вспомнят через recall."
log "бэкап для отката: $BACKUP_DIR"
