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

log()  { printf '[switch-harness] %s\n' "$*"; }
step() { printf '\n[switch-harness] == %s ==\n' "$*"; }
warn() { printf '[switch-harness] ВНИМАНИЕ: %s\n' "$*" >&2; }
die()  { printf '[switch-harness] ОШИБКА: %s\n' "$*" >&2; exit 1; }

# not_impl <шаг> — ещё не реализованный шаг. В обычном прогоне останавливает команду ДО
# необратимых действий (флип swarm.env, остановка агентов), чтобы недостроенный скрипт не
# оставил рой в полупереключённом состоянии. В --dry-run просто печатает, что будет сделано.
not_impl() {
  if [ "${DRY_RUN:-0}" = "1" ]; then
    log "· (план) $1"
    return 0
  fi
  die "шаг «$1» ещё не реализован — сборка команды идёт поэтапно. Пока доступен только --dry-run."
}

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

# ── Конвейер перехода ─────────────────────────────────────────────
# Шаги, помеченные not_impl, достраиваются следующими коммитами. Порядок важен: бэкап и
# вход — до любых необратимых изменений; флип swarm.env — только после успешной конвертации.
backup_all
not_impl "доустановка рантайма целевого харнеса ($TARGET), если он не установлен"
[ "${SKIP_LOGIN:-0}" = "1" ] || not_impl "встроенный вход в подписку $TARGET"
[ "$TARGET" = "codex" ] && not_impl "поднять pii-proxy (обязателен для codex)"
not_impl "пауза роя и остановка агентов текущим стоппером ($CURRENT)"
not_impl "конвертация воркспейсов агентов в формат $TARGET (идентичность, модель/MCP)"
not_impl "переключить swarm.env на $TARGET (harness_switch_swarm)"
not_impl "перезапуск юнитов и проверка готовности; откат при сбое"

if [ "$DRY_RUN" = "1" ]; then
  log "dry-run завершён — изменений не внесено."
  exit 0
fi
