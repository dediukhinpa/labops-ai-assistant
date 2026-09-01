#!/usr/bin/env bash
# mcp-call.sh -- вызов инструмента MCP по streamable-HTTP, с рукопожатием.
#
# ЗАЧЕМ ОТДЕЛЬНЫЙ ХЕЛПЕР: FastMCP (на нём построен second_brain) не принимает
# одиночный tools/call. Сначала нужен initialize, сервер отдаёт mcp-session-id,
# и только с этим заголовком вызов проходит. Хуки агента слали один POST без
# рукопожатия и получали "Bad Request: Missing session ID" -- обе точки
# fail-open, поэтому в логе оставалась строка "rejected by backend", а сброс
# памяти в общий мозг и побудка на консолидацию МОЛЧА не доходили
# (обнаружено 2026-09-01 на живом хосте: ни одного успешного flush).
#
# Использование:
#   source "$(dirname "$0")/mcp-call.sh"
#   RESP=$(mcp_tools_call "$URL" "$BEARER" "$TOOLS_CALL_PAYLOAD") || ...
#
# Печатает тело ответа на stdout. Возвращает 1, если сервер недоступен или не
# выдал сессию: вызывающая сторона решает, что делать (все текущие -- fail-open).

MCP_PROTOCOL_VERSION="${MCP_PROTOCOL_VERSION:-2025-06-18}"
MCP_TIMEOUT_S="${MCP_TIMEOUT_S:-10}"

# mcp_open_session <url> <bearer> -- напечатать mcp-session-id или вернуть 1.
mcp_open_session() {
    local url="$1" bearer="$2" headers sid init
    headers="$(mktemp)" || return 1
    init="{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"${MCP_PROTOCOL_VERSION}\",\"capabilities\":{},\"clientInfo\":{\"name\":\"agent-hook\",\"version\":\"1\"}}}"
    # stdout функции — ТОЛЬКО session-id: тело ответа глушим и через -o, и
    # редиректом, иначе оно склеится с идентификатором у вызывающей стороны.
    if ! curl -sS -m "$MCP_TIMEOUT_S" -D "$headers" -o /dev/null -X POST "$url" \
        -H "Authorization: Bearer ${bearer}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json, text/event-stream" \
        --data "$init" >/dev/null 2>/dev/null; then
        rm -f "$headers"
        return 1
    fi
    sid="$(grep -i '^mcp-session-id:' "$headers" | tail -1 | tr -d '\r' | sed 's/^[^:]*:[[:space:]]*//')"
    rm -f "$headers"
    [ -n "$sid" ] || return 1
    printf '%s' "$sid"
}

# mcp_close_session <url> <bearer> <sid> -- завершить сессию (HTTP DELETE).
#
# ЗАЧЕМ: сервер держит состояние сессии, пока клиент её не закроет, и сам её не
# протухает. Брошенная сессия -- утечка на стороне сервера. Замерено на живом
# memory_router 2026-09-01: 56 КБ на каждый initialize без DELETE против 6 КБ с
# ним. Поллер задач открывает сессию каждые 5 секунд на агента, то есть ~24
# сессии в минуту -- около 1.9 ГБ в сутки; за 30 часов сервис вырос до 4.9 ГБ и
# выел весь swap хоста.
mcp_close_session() {
    local url="$1" bearer="$2" sid="$3"
    [ -n "$sid" ] || return 0
    curl -sS -m "$MCP_TIMEOUT_S" -o /dev/null -X DELETE "$url" \
        -H "Authorization: Bearer ${bearer}" \
        -H "mcp-session-id: ${sid}" 2>/dev/null || true
}

# mcp_tools_call <url> <bearer> <payload> -- полный цикл: initialize,
# notifications/initialized, сам вызов и закрытие сессии. Печатает тело ответа.
mcp_tools_call() {
    local url="$1" bearer="$2" payload="$3" sid body rc=0
    sid="$(mcp_open_session "$url" "$bearer")" || return 1

    # Уведомление обязательно по протоколу; ответа у него нет, ошибку глотаем.
    curl -sS -m "$MCP_TIMEOUT_S" -o /dev/null -X POST "$url" \
        -H "Authorization: Bearer ${bearer}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json, text/event-stream" \
        -H "mcp-session-id: ${sid}" \
        --data '{"jsonrpc":"2.0","method":"notifications/initialized"}' 2>/dev/null || true

    body="$(curl -sS -m "$MCP_TIMEOUT_S" -X POST "$url" \
        -H "Authorization: Bearer ${bearer}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json, text/event-stream" \
        -H "mcp-session-id: ${sid}" \
        --data "$payload" 2>/dev/null)" || rc=1

    # Закрываем в любом случае: сессия висит на сервере и после неудачного вызова.
    mcp_close_session "$url" "$bearer" "$sid"

    [ "$rc" -eq 0 ] || return 1
    printf '%s' "$body"
}
