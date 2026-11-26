#!/usr/bin/env bash
# shellcheck disable=SC2012
set -euo pipefail

# ============================================================
# install.sh -- One-click agent workspace setup
#
# Creates a complete Claude Code agent workspace at
#   ~/.claude-lab/<agent-id>/.claude/
# wired to a second_brain MCP server (memory / recall / swarm).
#
# Assumes you already deployed the second_brain server (see ../README.md and
# ../scripts/install-vps.sh) and issued an agent token with
# ../scripts/issue-agent-token.py.
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES_DIR="${SCRIPT_DIR}/templates"
SCRIPTS_DIR="${SCRIPT_DIR}/scripts"
HOOKS_DIR="${SCRIPT_DIR}/hooks"
# CLAUDE_LAB держим общим с new-agent.sh: там путь уже брался из этой
# переменной, а здесь был прошит жёстко. Из-за расхождения скаффолд с
# заданной CLAUDE_LAB уезжал в ЖИВУЮ лабораторию, после чего вызывающая
# сторона падала с «воркспейс не создан» уже по другому пути.
LAB_DIR="${CLAUDE_LAB:-${HOME}/.claude-lab}"
GLOBAL_DIR="${HOME}/.claude"
DISTRO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SHARED_SKILLS_SRC="${DISTRO_ROOT}/skills"

# Значки и цвета — общие для всей установки (orchestration/lib/ui.sh): этот
# скрипт зовёт new-agent.sh посреди установки, и его «[+]»/«[!]» выбивались из
# остального вывода. «Skipping (exists)» — не проблема, а штатный повторный
# прогон, поэтому идёт через note, а не warn.
# shellcheck source=../orchestration/lib/ui.sh
. "${DISTRO_ROOT}/orchestration/lib/ui.sh"
# shellcheck source=../orchestration/lib/skills.sh
. "${DISTRO_ROOT}/orchestration/lib/skills.sh"
# shellcheck source=../orchestration/lib/skills-external.sh
. "${DISTRO_ROOT}/orchestration/lib/skills-external.sh"
# shellcheck source=../orchestration/lib/harness.sh
. "${DISTRO_ROOT}/orchestration/lib/harness.sh"
# Харнес роя (claude|codex) выбран первым вопросом установки и записан в shared/swarm.env;
# здесь только читается. Для claude всё ниже работает как раньше, побайтно.
HARNESS="$(harness_current)" || exit 1
CODEX_TEMPLATES_DIR="${TEMPLATES_DIR}/codex"
CODEX_WORKSPACE_PY="${SCRIPT_DIR}/codex_workspace.py"
log()   { ok "$1"; }
ask()   { printf "${UI_INFO}[?]${UI_RESET} %s: " "$1"; }

# Cross-platform sed in-place (macOS BSD vs GNU)
sed_i() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "$@"
    else
        sed -i "$@"
    fi
}

# prompt VARNAME "label" "default"
# Scriptable: if VARNAME is already set in the environment, use it (no prompt).
# In NONINTERACTIVE=1 mode, fall back to the default without prompting.
# This lets the create-agent skill drive this installer end-to-end.
prompt() {
    local __var="$1" __label="$2" __def="${3:-}" __input
    if [ -n "${!__var:-}" ]; then return; fi
    if [ "${NONINTERACTIVE:-0}" = "1" ]; then printf -v "$__var" '%s' "$__def"; return; fi
    ask "$__label"
    read -r __input
    printf -v "$__var" '%s' "${__input:-$__def}"
}

# ============================================================
# Step 1: Prerequisites
# ============================================================

echo ""
echo "============================================"
echo "  $( [ "$HARNESS" = "codex" ] && echo "Codex" || echo "Claude Code" ) Agent -- Workspace Installer"
echo "============================================"
echo ""

if [ "$HARNESS" = "codex" ]; then
    # Где ищет codex оркестрация (lib/codex-watch.sh codex_bin): CODEX_BIN, копия установщика
    # в ~/.local/bin, затем PATH.
    if ! { [ -x "${CODEX_BIN:-}" ] || [ -x "$HOME/.local/bin/codex" ] || command -v codex &>/dev/null; }; then
        warn "Codex CLI not found (the swarm installer puts it in place before agents start)."
        warn "Continuing anyway (workspace will be ready when you install the CLI)."
    fi
elif ! command -v claude &>/dev/null; then
    warn "Claude Code CLI not found. Install: curl -fsSL https://claude.ai/install.sh | bash"
    warn "Continuing anyway (workspace will be ready when you install the CLI)."
fi

for cmd in jq python3 curl; do
    if ! command -v "$cmd" &>/dev/null; then
        warn "${cmd} not installed; some features (second_brain recall, JSON parsing) won't work until you install it."
    fi
done

if [ ! -d "$TEMPLATES_DIR" ]; then
    err "Templates directory not found: $TEMPLATES_DIR"
    err "Run this script from the cloned agent-template/ root."
    exit 1
fi

# ============================================================
# Step 2: Gather parameters
# ============================================================

[ "${NONINTERACTIVE:-0}" = "1" ] || { echo "Answer a few questions to set up your agent."; echo ""; }

prompt AGENT_NAME              "Agent name (e.g. Homer, Friday, Developer)" "MyAgent"
# Имя — как его назвал оператор (хоть «Игорь»): оно в заголовке идентичности. Служебный id
# (папки, юнит, порт) — только латиница; new-agent.sh передаёт его в NEW_AGENT_ID, если из
# имени он не получается. Не AGENT_ID: внутри сессии агента там лежит id РОДИТЕЛЯ (общий
# env tmux), и новый воркспейс лёг бы поверх чужого. Раньше id всегда выводился из имени,
# и кириллическое имя не проходило.
AGENT_ID="${NEW_AGENT_ID:-$(echo "$AGENT_NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')}"

if [[ ! "${AGENT_ID}" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]]; then
    err "Agent id must contain only latin letters, numbers, and hyphens (max 31 chars); pass NEW_AGENT_ID for a non-latin name"
    exit 1
fi
case "$AGENT_NAME" in
    *'|'*|*'&'*|*'\'*|*$'\n'*)
        err "Agent name must not contain | & \\ or line breaks"
        exit 1 ;;
esac

# Роль и зелёная зона идентичности. developer — первый агент роя (как было всегда: код, git,
# деплой); custom — агенты, которых он заводит: роль из NEW_AGENT_ROLE (что оператор сказал при
# создании), а без неё — заготовка «роль не задана», чтобы агент не выдавал себя за
# программиста. По умолчанию developer: прямой запуск установщика рендерит как раньше.
AGENT_PROFILE="${AGENT_PROFILE:-developer}"
case "$AGENT_PROFILE" in
    developer|custom) ;;
    *) err "AGENT_PROFILE must be developer or custom (got: $AGENT_PROFILE)"; exit 1 ;;
esac
IDENTITY_PARTS_DIR="${SCRIPT_DIR}/templates/identity"
if [ -n "${NEW_AGENT_ROLE:-}" ]; then
    AGENT_ROLE_TEXT="$(printf '%s' "$NEW_AGENT_ROLE" | tr -d '\r')"
else
    AGENT_ROLE_TEXT="$(cat "${IDENTITY_PARTS_DIR}/role-${AGENT_PROFILE}.md")"
fi
AGENT_GREEN_ZONE_TEXT="$(cat "${IDENTITY_PARTS_DIR}/green-zone-${AGENT_PROFILE}.md")"

# Роль, описание и характер не спрашиваются: они пишутся в личный CLAUDE.md уроком курса
# 07-claude-md, а ответ установщика ложился туда же второй, расходящейся версией.

if [ "$HARNESS" = "codex" ]; then
    # Модель агентов на Codex по умолчанию — решение владельца (lib/harness.sh).
    CODEX_DEFAULT_MODEL="$(harness_default_model codex)"
    prompt PRIMARY_MODEL      "Primary model [${CODEX_DEFAULT_MODEL}]" "$CODEX_DEFAULT_MODEL"
else
# Алиасы, а не версии: см. комментарий в skills/create-agent/new-agent.sh.
[ "${NONINTERACTIVE:-0}" = "1" ] || { echo ""; echo "  Aliases resolve to the latest model of their tier: fable / opus (code+review) / sonnet (subagents+research). A full model name pins a version."; }
prompt PRIMARY_MODEL          "Primary model [sonnet]" "sonnet"
fi
# Имя модели уходит в settings.json как есть: с посторонними байтами агент молчит
# при зелёной установке (см. orchestration/lib/model-choice.sh). Этот установщик
# запускается и отдельно, поэтому проверка своя; new-agent.sh уже переспросил.
if [ -z "$PRIMARY_MODEL" ] || [ -n "$(printf '%s' "$PRIMARY_MODEL" | LC_ALL=C tr -d 'A-Za-z0-9._[]-')" ]; then
    err "Invalid model name: $(printf '%q' "$PRIMARY_MODEL") -- use Latin letters, digits and . _ - [ ] (e.g. opus, sonnet)"
    exit 1
fi
# Haiku не вызывает reply канала — агент молчит в Telegram; в выборе его нет
# (см. orchestration/lib/model-choice.sh). Правило про модели Claude: у codex своих haiku нет.
[ "$HARNESS" = "codex" ] || case "${PRIMARY_MODEL,,}" in
    *haiku*)
        err "Model ${PRIMARY_MODEL} is not supported: a Haiku agent does not answer in Telegram -- use fable, opus or sonnet"
        exit 1
        ;;
esac
prompt RESEARCH_MODEL         "Research model [Perplexity Sonar]" "Perplexity Sonar (web search only, no code)"
prompt MAX_SUBAGENTS          "Max simultaneous subagents [5]" "5"

[ "${NONINTERACTIVE:-0}" = "1" ] || { echo ""; echo "--- Operator (you) ---"; }
prompt LANGUAGE               "Response language (e.g. English, Russian)" "English"
prompt COMMIT_LANGUAGE        "Commit language (e.g. English, Russian)" "English"
# Порога трат нет: любые траты агента -- через владельца (общая красная зона).
# Раньше здесь спрашивали лимит, но в обычной установке (через new-agent.sh, без
# вопросов) он не показывался, и в красную зону молча уезжали $50, которые никто
# не выбирал.
prompt GITHUB_USERNAME        "GitHub username (or skip)" "your-username"

[ "${NONINTERACTIVE:-0}" = "1" ] || { echo ""; echo "--- second_brain MCP server ---"; }
prompt MCP_HOST               "second_brain host (IP/domain, no protocol or port -- e.g. 127.0.0.1 for a colocated install)" "127.0.0.1"
MCP_HOST="${MCP_HOST%/}"  # strip trailing slash
prompt AGENT_BEARER          "Agent bearer token (issued by scripts/issue-agent-token.py)" "CHANGE_ME"
prompt AGENT_SCOPES          "Agent scopes [decisions,knowledge,inbox]" "decisions,knowledge,inbox"

# Direct per-service host:port URLs (no reverse-proxy needed for the
# default colocated setup). Override SECOND_BRAIN_*_URL directly for a
# reverse-proxy-fronted remote deployment (e.g. https://mcp.example.com/memory/mcp).
: "${MCP_MEMORY_PORT:=5001}"
: "${MCP_MEMORY_ROUTER_PORT:=5002}"
: "${MCP_AGENT_ROUTER_PORT:=5000}"
: "${MCP_TASKS_PORT:=5003}"
: "${SECOND_BRAIN_MEMORY_URL:=http://${MCP_HOST}:${MCP_MEMORY_PORT}/mcp}"
: "${SECOND_BRAIN_MEMORY_ROUTER_URL:=http://${MCP_HOST}:${MCP_MEMORY_ROUTER_PORT}/mcp}"
: "${SECOND_BRAIN_AGENT_ROUTER_URL:=http://${MCP_HOST}:${MCP_AGENT_ROUTER_PORT}/mcp}"
: "${SECOND_BRAIN_TASKS_URL:=http://${MCP_HOST}:${MCP_TASKS_PORT}/mcp}"

# ============================================================
# Step 3: Confirm
# ============================================================

echo ""
echo "============================================"
echo "  Setup Summary"
echo "============================================"
echo ""
echo "  Agent:       ${AGENT_NAME} (${AGENT_ID})"
echo "  Model:       ${PRIMARY_MODEL}"
echo "  Language:    ${LANGUAGE}"
echo "  Workspace:   ${LAB_DIR}/${AGENT_ID}/.claude/"
echo "  second_brain memory:        ${SECOND_BRAIN_MEMORY_URL}"
echo "  second_brain memory_router: ${SECOND_BRAIN_MEMORY_ROUTER_URL}"
echo "  second_brain agent_router:  ${SECOND_BRAIN_AGENT_ROUTER_URL}"
echo "  second_brain tasks:         ${SECOND_BRAIN_TASKS_URL}"
echo "  Scopes:      ${AGENT_SCOPES}"
echo ""
CONFIRM=""
ask_yn CONFIRM "Proceed?" y
if [ "$CONFIRM" = "n" ]; then
    echo "Cancelled."
    exit 0
fi

# ============================================================
# Step 4: Directory structure
# ============================================================

WORKSPACE="${LAB_DIR}/${AGENT_ID}/.claude"
SHARED="${LAB_DIR}/shared"

log "Creating directory structure..."

mkdir -p "${WORKSPACE}/core/passive"
mkdir -p "${WORKSPACE}/core/active/pre-compact"
mkdir -p "${WORKSPACE}/core/archived"
mkdir -p "${WORKSPACE}/tools"
mkdir -p "${WORKSPACE}/agents"
mkdir -p "${WORKSPACE}/scripts"
mkdir -p "${WORKSPACE}/hooks"
mkdir -p "${WORKSPACE}/logs"
mkdir -p "${SHARED}/secrets"
if [ "$HARNESS" = "codex" ]; then
    # CODEX_HOME агента: config.toml, общие правила (AGENTS.md), нити и вход ChatGPT.
    CODEX_HOME_DIR="${LAB_DIR}/${AGENT_ID}/.codex"
    mkdir -p "${CODEX_HOME_DIR}/rules"
    chmod 700 "${CODEX_HOME_DIR}"
else
mkdir -p "${GLOBAL_DIR}/rules"
fi
# Не создаём core/active/archived, shared/skills, shared/scripts и handoff.md: в них
# никто не писал и никто их не читал. Скиллы -- ссылка на репозиторий, архив дневника --
# core/archived/episodic, итог сессии уходит в общий мозг (brain-flush.sh).

# ============================================================
# Step 5: Render templates (envsubst-style {{VAR}} and ${VAR})
# ============================================================

fill_template() {
    local src="$1"
    local dst="$2"

    if [ -f "$dst" ]; then
        note "Skipping (exists): $dst"
        return
    fi

    cp "$src" "$dst"

    # {{VAR}} placeholders
    sed_i "s|{{AGENT_NAME}}|${AGENT_NAME}|g" "$dst"
    sed_i "s|{{AGENT_ID}}|${AGENT_ID}|g" "$dst"
    sed_i "s|{{PRIMARY_MODEL}}|${PRIMARY_MODEL}|g" "$dst"
    sed_i "s|{{RESEARCH_MODEL}}|${RESEARCH_MODEL}|g" "$dst"
    sed_i "s|{{MAX_SUBAGENTS}}|${MAX_SUBAGENTS}|g" "$dst"
    sed_i "s|{{LANGUAGE}}|${LANGUAGE}|g" "$dst"
    sed_i "s|{{COMMIT_LANGUAGE}}|${COMMIT_LANGUAGE}|g" "$dst"
    sed_i "s|{{GITHUB_USERNAME}}|${GITHUB_USERNAME}|g" "$dst"
    sed_i "s|{{INSTALL_DATE}}|$(date -u +%Y-%m-%d)|g" "$dst"
    # URL локального pii-proxy агента (его выдаёт orchestration/pii-setup.sh через new-agent.sh).
    # Пусто - прокси отключён (SKIP_PII_PROXY=1) либо шаблон рендерится вне new-agent.sh.
    sed_i "s|{{PII_PROXY_URL}}|${PII_PROXY_URL:-}|g" "$dst"

    # ${VAR} placeholders (for .mcp.json template and tools.md, settings.json)
    sed_i "s|\${MCP_HOST}|${MCP_HOST}|g" "$dst"
    sed_i "s|\${SECOND_BRAIN_MEMORY_URL}|${SECOND_BRAIN_MEMORY_URL}|g" "$dst"
    sed_i "s|\${SECOND_BRAIN_MEMORY_ROUTER_URL}|${SECOND_BRAIN_MEMORY_ROUTER_URL}|g" "$dst"
    sed_i "s|\${SECOND_BRAIN_AGENT_ROUTER_URL}|${SECOND_BRAIN_AGENT_ROUTER_URL}|g" "$dst"
    sed_i "s|\${SECOND_BRAIN_TASKS_URL}|${SECOND_BRAIN_TASKS_URL}|g" "$dst"
    sed_i "s|\${AGENT_BEARER}|${AGENT_BEARER}|g" "$dst"

    # Sweep any unsubstituted {{TODO}} placeholders
    sed_i 's|{{[A-Z_0-9]*}}|TODO: fill in|g' "$dst"

    render_identity_blocks "$dst"

    log "Created: $dst"
}

# render_identity_blocks <файл> — строки-метки роли и зелёной зоны заменяются текстом как есть.
# После всех sed: текст оператора может содержать $, &, |, {{…}} — sed бы его исказил или
# принял за плейсхолдер. awk берёт текст из окружения, без экранирования.
render_identity_blocks() {
    local dst="$1" tmp
    grep -qxE '<!-- labops:(agent-role|green-zone) -->' "$dst" || return 0
    tmp="$(mktemp)"
    ROLE_TEXT="$AGENT_ROLE_TEXT" GREEN_TEXT="$AGENT_GREEN_ZONE_TEXT" awk '
        $0 == "<!-- labops:agent-role -->" { print ENVIRON["ROLE_TEXT"]; next }
        $0 == "<!-- labops:green-zone -->" { print ENVIRON["GREEN_TEXT"]; next }
        { print }' "$dst" > "$tmp" && cat "$tmp" > "$dst"
    rm -f "$tmp"
}

# Управляющие документы РЯДОМ с CLAUDE.md, а не только в репозитории.
# До этого их не копировал никто: SECONDBRAIN_WRITE_RULES.md (красная зона --
# правила записи в общий мозг) и AGENT_ROUTER.md (как получать и закрывать
# задачи с доски) существовали только в дереве репозитория. Агент их не видел,
# хотя поллер в тексте доставки прямо пишет «См. AGENT_ROUTER.md», а SKILL.md
# утверждал, что правила записи «уже подключены».
copy_doc() {
    local src="$1" dst="$2"
    if [ ! -f "$src" ]; then
        warn "Нет документа $src -- пропускаю"
        return
    fi
    if [ -f "$dst" ]; then
        note "Skipping (exists): $dst"
        return
    fi
    cp "$src" "$dst"
    log "Created: $dst"
}

REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
copy_doc "${REPO_ROOT}/SECONDBRAIN_WRITE_RULES.md" "${WORKSPACE}/SECONDBRAIN_WRITE_RULES.md"
copy_doc "${REPO_ROOT}/AGENT_ROUTER.md"            "${WORKSPACE}/AGENT_ROUTER.md"

log "Filling templates..."

if [ "$HARNESS" = "codex" ]; then
    # Агент на Codex без псевдонимизации не ставится (решение владельца 22.11.2026): все
    # запросы к модели идут через pii-proxy, его адрес — model_provider в config.toml.
    if [ -z "${PII_PROXY_URL:-}" ]; then
        err "Codex agent needs pii-proxy: PII_PROXY_URL is empty (run through new-agent.sh)"
        exit 1
    fi
    if [ ! -f "${WORKSPACE}/AGENTS.src.md" ]; then
        # Промежуточный рендер — в личном каталоге mktemp -d (права 700): fill_template не пишет
        # в существующий файл, а удалить файл от mktemp и писать по тому же имени в общем /tmp
        # значит дать подменить его ссылкой. Строку «Created» про временный файл не печатаем.
        CODEX_IDENTITY_DIR="$(mktemp -d)"
        CODEX_IDENTITY_TMP="${CODEX_IDENTITY_DIR}/identity.md"
        fill_template "${TEMPLATES_DIR}/CLAUDE.md.template" "$CODEX_IDENTITY_TMP" >/dev/null
        python3 "$CODEX_WORKSPACE_PY" identity --agent-id "$AGENT_ID" \
            --channel-section "${CODEX_TEMPLATES_DIR}/channel-section.md" \
            "$CODEX_IDENTITY_TMP" "${WORKSPACE}/AGENTS.src.md"
        rm -rf "$CODEX_IDENTITY_DIR"
    else
        note "Skipping (exists): ${WORKSPACE}/AGENTS.src.md"
    fi
else
fill_template "${TEMPLATES_DIR}/CLAUDE.md.template"    "${WORKSPACE}/CLAUDE.md"
fi
fill_template "${TEMPLATES_DIR}/agents.md.template"    "${WORKSPACE}/core/AGENTS.md"
# В шаблоне только поля, которые спрашивает установщик (язык). Обращение, имя, часовой
# пояс, профиль, стиль и нужды оператор дописывает уроком курса 08-user-md, характер --
# уроком 07-claude-md: имя и пояс никто не спрашивал, и агенту доставались «Operator»/UTC; заготовки под них раньше доезжали
# до агента строками «TODO: fill in» и читались в каждом разговоре.
fill_template "${TEMPLATES_DIR}/USER.md.template"      "${WORKSPACE}/core/USER.md"
fill_template "${TEMPLATES_DIR}/rules.md.template"     "${WORKSPACE}/core/rules.md"
fill_template "${TEMPLATES_DIR}/tools.md.template"     "${WORKSPACE}/tools/TOOLS.md"
fill_template "${TEMPLATES_DIR}/decisions.md.template" "${WORKSPACE}/core/passive/decisions.md"
fill_template "${TEMPLATES_DIR}/episodic.md.template"    "${WORKSPACE}/core/active/episodic.md"
# preferences.md создаём сразу, хотя пишет в него только memory-consolidate: файл
# импортирован в CLAUDE.md, и у свежего агента импорт должен на что-то указывать.
fill_template "${TEMPLATES_DIR}/preferences.md.template" "${WORKSPACE}/core/passive/preferences.md"
if [ "$HARNESS" = "codex" ]; then
    # Общие тексты те же, что у claude; меняются только упоминания, которые у Codex другие.
    python3 "$CODEX_WORKSPACE_PY" adapt --agent-id "$AGENT_ID" \
        "${WORKSPACE}/core/AGENTS.md" "${WORKSPACE}/core/USER.md" "${WORKSPACE}/core/rules.md" \
        "${WORKSPACE}/tools/TOOLS.md"
    fill_template "${CODEX_TEMPLATES_DIR}/config.toml.template" "${CODEX_HOME_DIR}/config.toml"
    chmod 600 "${CODEX_HOME_DIR}/config.toml"
    # Общие правила агентов: у Codex это AGENTS.md в CODEX_HOME (аналог ~/.claude/CLAUDE.md).
    if [ ! -f "${CODEX_HOME_DIR}/AGENTS.md" ]; then
        fill_template "${TEMPLATES_DIR}/global-CLAUDE.md.template" "${CODEX_HOME_DIR}/AGENTS.md"
        python3 "$CODEX_WORKSPACE_PY" adapt --agent-id "$AGENT_ID" "${CODEX_HOME_DIR}/AGENTS.md"
    else
        note "Skipping (exists): ${CODEX_HOME_DIR}/AGENTS.md"
    fi
else
fill_template "${TEMPLATES_DIR}/mcp.json.template"     "${WORKSPACE}/.mcp.json"
fill_template "${TEMPLATES_DIR}/settings.json.template" "${WORKSPACE}/settings.json"
# Пустой ANTHROPIC_BASE_URL claude прочёл бы как «адрес не задан» неоднозначно: если прокси
# не выдан, ключ убираем целиком (агент пойдёт на API напрямую, а install.sh/new-agent.sh уже
# громко предупредили об отключении).
python3 - "${WORKSPACE}/settings.json" <<'PY' || warn "не удалось почистить пустой ANTHROPIC_BASE_URL"
import json, sys
path = sys.argv[1]
d = json.load(open(path))
env = d.get("env", {})
if env.get("ANTHROPIC_BASE_URL", None) == "":
    del env["ANTHROPIC_BASE_URL"]
    with open(path, "w") as f:
        json.dump(d, f, indent=2, ensure_ascii=False)
        f.write("\n")
PY

# Общие правила всех агентов (git, безопасность, смена модели, принципы) живут
# ТОЛЬКО в ~/.claude/CLAUDE.md -- из агентских файлов их убрали, чтобы одно правило
# не лежало в трёх местах и не расходилось. Поэтому чужой глобальный файл
# (пользователь пришёл уже настроенным) больше нельзя молча пропустить: агент
# остался бы без этих правил вовсе. Свой файл владельца не трогаем -- кладём наши
# правила рядом и прямо говорим, что их нужно перенести.
# Шаблон не повторяет того, что оператор сам вписывает уроками курса «Своя ИИ-команда»
# (07-claude-md, 08-user-md): план перед работой, копия перед изменением, удаление
# только с разрешения, секреты вне репозитория, без переписывания истории, проверка
# по первоисточнику. Иначе одно правило лежит дважды в разных формулировках.
GLOBAL_MD="${GLOBAL_DIR}/CLAUDE.md"
GLOBAL_MARKER='# Global Rules -- All Agents'
if [ -f "$GLOBAL_MD" ] && ! grep -qxF "$GLOBAL_MARKER" "$GLOBAL_MD"; then
    fill_template "${TEMPLATES_DIR}/global-CLAUDE.md.template" "${GLOBAL_MD}.labops-new"
    warn "В ${GLOBAL_MD} уже лежат чужие правила -- общие правила агентов НЕ подключены."
    warn "Перенесите ${GLOBAL_MD}.labops-new в ${GLOBAL_MD}, иначе агент останется без"
    warn "правил git, безопасности и смены модели."
else
    fill_template "${TEMPLATES_DIR}/global-CLAUDE.md.template" "$GLOBAL_MD"
fi
fi

# ============================================================
# Step 6: Copy scripts and hooks (not symlinked, so each agent owns them)
# ============================================================

log "Copying memory-management scripts..."
# task_poller.py -- тело поллера рядом с обёрткой task-poller.sh: обёртка ищет
# его в своём каталоге и без него молча выходит, а доставка задач умирает.
for script in active-writer.sh reflect-nudge.sh decay-sweep.sh archive-roll.sh brain-flush.sh task-poller.sh task_poller.py mcp-call.sh; do
    if [ -f "${SCRIPTS_DIR}/${script}" ]; then
        if [ ! -f "${WORKSPACE}/scripts/${script}" ]; then
            cp "${SCRIPTS_DIR}/${script}" "${WORKSPACE}/scripts/${script}"
            chmod +x "${WORKSPACE}/scripts/${script}"
            log "Copied: scripts/${script}"
        else
            note "Skipping (exists): scripts/${script}"
        fi
    else
        warn "Script not found in distro: ${script}"
    fi
done

log "Copying hooks..."
for hook in heartbeat-hook.sh session-start-hook.sh stop-hook.sh precompact-hook.sh; do
    if [ -f "${HOOKS_DIR}/${hook}" ]; then
        if [ ! -f "${WORKSPACE}/hooks/${hook}" ]; then
            cp "${HOOKS_DIR}/${hook}" "${WORKSPACE}/hooks/${hook}"
            chmod +x "${WORKSPACE}/hooks/${hook}"
            log "Copied: hooks/${hook}"
        else
            note "Skipping (exists): hooks/${hook}"
        fi
    else
        warn "Hook not found in distro: ${hook}"
    fi
done

# ============================================================
# Step 7: Per-agent rc file with second_brain env (sourced before `claude`)
# ============================================================

AGENT_RC="${WORKSPACE}/agent.env"
if [ ! -f "$AGENT_RC" ]; then
    cat > "$AGENT_RC" <<RC
# ${AGENT_NAME} runtime env
# Source this before launching $( [ "$HARNESS" = "codex" ] && echo "Codex" || echo "Claude Code" ):  source ${AGENT_RC}
export AGENT_ID="${AGENT_ID}"
export AGENT_WORKSPACE="${WORKSPACE}"
export MCP_HOST="${MCP_HOST}"
export SECOND_BRAIN_MEMORY_URL="${SECOND_BRAIN_MEMORY_URL}"
export SECOND_BRAIN_MEMORY_ROUTER_URL="${SECOND_BRAIN_MEMORY_ROUTER_URL}"
export SECOND_BRAIN_AGENT_ROUTER_URL="${SECOND_BRAIN_AGENT_ROUTER_URL}"
export SECOND_BRAIN_TASKS_URL="${SECOND_BRAIN_TASKS_URL}"
export AGENT_BEARER="${AGENT_BEARER}"
export AGENT_SCOPES="${AGENT_SCOPES}"
export SUMMARY_LANGUAGE="${LANGUAGE}"
RC
    chmod 600 "$AGENT_RC"
    log "Created: ${AGENT_RC} (chmod 600)"
fi

# ============================================================
# Step 8: Shared skills (optional, interactive)
# ============================================================

if [ -d "$SHARED_SKILLS_SRC" ]; then
    echo ""
    echo "--- Shared skills ---"
    echo "Available in ${SHARED_SKILLS_SRC}:"
    ls -1 "$SHARED_SKILLS_SRC" | sed 's/^/  - /'
    # ENABLE_ALL=y|n из окружения отвечает без вопроса, как и раньше.
    ask_yn ENABLE_ALL "Copy the shared skills into ${LAB_DIR}/shared/skills and link the workspace to them?" y
    if [ "$ENABLE_ALL" != "n" ]; then
        # Копия, а не ссылка в репозиторий: удалённый или перенесённый клон
        # не должен уносить скиллы у всех агентов (см. orchestration/lib/skills.sh).
        # Без force: общая папка — одна на всех агентов, и источник здесь выбран
        # не оператором, а поиском в new-agent.sh. Из устаревшего клона такая
        # синхронизация откатывала скиллы всему рою (ревью 2026-09-20).
        skills_rc=0
        sync_shared_skills "$SHARED_SKILLS_SRC" "$LAB_DIR" || skills_rc=$?
        if [ "$skills_rc" -eq 3 ]; then
            note "Shared skills kept: they come from another checkout (see above)"
        elif [ "$skills_rc" -ne 0 ]; then
            warn "Shared skills not updated (code $skills_rc)"
        fi
        # Внешние скиллы (docx, pdf, research и др.) скачиваются по манифесту с
        # закреплёнными коммитами. Только если свои скиллы встали: при коде 3 общая
        # папка принадлежит другому клону, и дописывать в неё чужие скиллы нечего.
        # Сбой сети установку не роняет: догнать можно через sync-skills.sh.
        if [ "$skills_rc" -eq 0 ]; then
            ext_rc=0
            sync_external_skills "${SHARED_SKILLS_SRC}/external-skills.manifest" "$LAB_DIR" || ext_rc=$?
            [ "$ext_rc" -eq 0 ] || warn "External skills incomplete (code $ext_rc). Later: bash ${DISTRO_ROOT}/orchestration/sync-skills.sh"
        fi
        link_rc=0
        link_workspace_skills "$WORKSPACE" "$LAB_DIR" || link_rc=$?
        case "$link_rc" in
            0) log "skills/ -> $(shared_skills_dir "$LAB_DIR")" ;;
            2) note "Skipping: skills/ is the agent's own directory" ;;
            3) note "Skipping: skills/ is pinned by .labops-keep-skills" ;;
            *) warn "skills/ not linked (code $link_rc)" ;;
        esac
        # Codex ищет навыки в .agents/skills рабочей папки (область repo). Свой каталог
        # навыков CODEX_HOME/skills не подходит: туда Codex пишет системные навыки.
        if [ "$HARNESS" = "codex" ] && [ -e "${WORKSPACE}/skills" ] \
            && [ ! -e "${WORKSPACE}/.agents/skills" ]; then
            mkdir -p "${WORKSPACE}/.agents"
            ln -s ../skills "${WORKSPACE}/.agents/skills"
            log ".agents/skills -> skills (Codex)"
        fi
    else
        warn "Skills not linked. Later: bash ${DISTRO_ROOT}/orchestration/sync-skills.sh"
    fi
else
    warn "Shared skills dir not found at ${SHARED_SKILLS_SRC}; skipping."
fi

# ============================================================
# Step 9: Language rules in ~/.claude/rules/
# ============================================================

log "Setting up language rules..."

# Codex не читает ~/.claude/rules: правила ложатся в CODEX_HOME/rules и вклеиваются в его
# общий AGENTS.md (ниже). Для claude каталог прежний.
RULES_DIR="${GLOBAL_DIR}/rules"
[ "$HARNESS" = "codex" ] && RULES_DIR="${CODEX_HOME_DIR}/rules"
for rule_file in bash.md python.md typescript.md; do
    if [ ! -f "${RULES_DIR}/${rule_file}" ]; then
        case "$rule_file" in
            bash.md)
                cat > "${RULES_DIR}/${rule_file}" << 'RULE'
# Bash rules
- set -euo pipefail at the start
- Quote variables: "$VAR"
- Check file existence before operations
- Log actions with echo
RULE
                ;;
            python.md)
                cat > "${RULES_DIR}/${rule_file}" << 'RULE'
# Python rules
- Type hints required for all functions
- Docstrings in Google style
- pathlib instead of os.path
- f-strings instead of .format()
- dataclasses or pydantic instead of dict
- Imports: stdlib, blank line, third-party, blank line, local
- Logging via logging module, not print
RULE
                ;;
            typescript.md)
                cat > "${RULES_DIR}/${rule_file}" << 'RULE'
# TypeScript rules
- strict: true always
- Never any, use unknown + type guard
- interface over type for objects
- Zod for runtime validation
- Barrel exports (index.ts) for modules
RULE
                ;;
        esac
        log "Created: ${RULES_DIR}/${rule_file}"
    else
        note "Skipping (exists): ${RULES_DIR}/${rule_file}"
    fi
done

# ============================================================
# Step 10: Permissions on secrets dir
# ============================================================

chmod 700 "${SHARED}/secrets" 2>/dev/null || true
chmod 600 "${WORKSPACE}/.mcp.json" 2>/dev/null || true

if [ "$HARNESS" = "codex" ]; then
    # Правила языков — в общий AGENTS.md Codex, один раз (по метке).
    CODEX_RULES_MARK="<!-- labops: language rules -->"
    if ! grep -qxF "$CODEX_RULES_MARK" "${CODEX_HOME_DIR}/AGENTS.md"; then
        {
            printf '\n%s\n\n## Language rules\n' "$CODEX_RULES_MARK"
            for rule_file in bash.md python.md typescript.md; do
                printf '\n'
                sed 's/^# /### /' "${RULES_DIR}/${rule_file}"
            done
        } >> "${CODEX_HOME_DIR}/AGENTS.md"
        log "Language rules -> ${CODEX_HOME_DIR}/AGENTS.md"
    fi
    # Идентичность для Codex: AGENTS.src.md с развёрнутыми @-импортами. Драйвер пересобирает
    # её перед каждым стартом нити своей копией скрипта (рабочая папка не зависит от клона).
    cp "$CODEX_WORKSPACE_PY" "${WORKSPACE}/scripts/codex_workspace.py"
    python3 "${WORKSPACE}/scripts/codex_workspace.py" agents-md "${WORKSPACE}"
    log "Created: ${WORKSPACE}/AGENTS.md"
fi

# ============================================================
# Step 11: Summary
# ============================================================

echo ""
echo "============================================"
echo "  Setup Complete"
echo "============================================"
echo ""
echo "  Workspace:    ${WORKSPACE}/"
echo "  Shared:       ${SHARED}/"
if [ "$HARNESS" = "codex" ]; then
echo "  Codex home:   ${CODEX_HOME_DIR}/"
else
echo "  Global:       ${GLOBAL_DIR}/"
fi
echo ""

FILE_COUNT=$(find "${WORKSPACE}" -type f | wc -l | tr -d ' ')
echo "  ${FILE_COUNT} files in workspace"
echo ""
if [ "$HARNESS" != "codex" ] && [ -f "${GLOBAL_MD}.labops-new" ]; then
    warn "Общие правила агентов ждут переноса: ${GLOBAL_MD}.labops-new -> ${GLOBAL_MD}"
    echo ""
fi
echo "  Next steps:"
echo ""
echo "    1. Fill in the agent's identity (the one file you must personalize):"
if [ "$HARNESS" = "codex" ]; then
echo "       - ${WORKSPACE}/AGENTS.src.md (SOUL; AGENTS.md is assembled from it — do not edit AGENTS.md)"
else
echo "       - ${WORKSPACE}/CLAUDE.md (SOUL)"
fi
echo "       (core/USER.md is copied from the first agent — no need to fill it in.)"
echo ""
# Раньше тут предлагался одиночный curl с tools/list. Транспорт MCP сессионный:
# без initialize сервер отвечает 400 «Missing session ID» при любом токене, и
# проверка выглядела как поломка. Доктор делает рукопожатие и проверяет всё сразу.
echo "    2. Verify second_brain connectivity (handshake, token, recall, hooks):"
echo "       python3 ${WORKSPACE}/skills/second_brain-doctor/scripts/second_brain_doctor.py --agent ${AGENT_ID}"
echo ""
if [ "$HARNESS" = "codex" ]; then
echo "    3. The agent runs under its systemd unit (Codex driver), not by hand."
else
echo "    3. Launch agent (settings.json wires Stop/SessionStart/PreCompact hooks):"
echo "       source ${AGENT_RC} && claude --project ${WORKSPACE}"
fi
echo ""
# Крон на уборку памяти больше не предлагаем: decay-sweep и archive-roll раз в
# сутки запускает сам Stop-хук, а крон поверх него гонял бы их дважды.
echo "    4. Housekeeping needs no cron: the Stop hook runs decay-sweep.sh and"
echo "       archive-roll.sh at most once a day; consolidation is nudged in-session."
echo ""
echo "    5. (Optional) Add more agents:"
echo "       bash install.sh   # run again with a different agent name"
echo ""
echo "============================================"
echo "  Done."
echo "============================================"
