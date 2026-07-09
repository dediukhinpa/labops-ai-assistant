#!/usr/bin/env python3
"""Send a task-board heartbeat for one or more agents.

Usage: second_brain-heartbeat.py <agent> [<agent> ...]

For each agent it reads that agent's bearer token and calls the task-mcp
`agent_heartbeat` tool (port 5003) via a proper MCP client. The old boot-script
approach (raw curl to :5000) never worked — FastMCP streamable-http rejects it
("must accept both application/json and text/event-stream"), which is why the
agents table stayed empty. Fail-safe: any error for one agent is logged and
skipped; the process never raises, so the cron driver stays quiet on success.
"""
import asyncio
import sys

from fastmcp import Client
from fastmcp.client.transports import StreamableHttpTransport

TASK_MCP_URL = "http://localhost:5003/mcp"
TOKEN_PATH = "/home/agent/.claude-lab/{agent}/.claude/secrets/second_brain-bearer"
TIMEOUT_S = 10.0


async def _beat(agent: str) -> bool:
    try:
        with open(TOKEN_PATH.format(agent=agent), encoding="utf-8") as fh:
            token = fh.read().strip()
    except OSError as exc:
        print(f"[heartbeat] {agent}: no token ({exc})", file=sys.stderr)
        return False
    transport = StreamableHttpTransport(
        TASK_MCP_URL, headers={"Authorization": f"Bearer {token}"}
    )
    try:
        async with Client(transport) as client:
            await asyncio.wait_for(
                client.call_tool("agent_heartbeat", {"status": "online"}),
                timeout=TIMEOUT_S,
            )
        return True
    except Exception as exc:  # noqa: BLE001 - heartbeat is best-effort
        print(f"[heartbeat] {agent}: failed ({exc!r})", file=sys.stderr)
        return False


async def _main(agents: list[str]) -> None:
    results = await asyncio.gather(*(_beat(a) for a in agents))
    ok = sum(results)
    if ok != len(agents):
        print(f"[heartbeat] {ok}/{len(agents)} ok", file=sys.stderr)


if __name__ == "__main__":
    names = sys.argv[1:]
    if names:
        asyncio.run(_main(names))
