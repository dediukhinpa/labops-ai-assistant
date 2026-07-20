#!/usr/bin/env bash
# plugin.sh — provision the Telegram channel plugin into an agent workspace.
#
# WHY A REAL DIRECTORY AND NOT A SYMLINK:
# start-agent.sh runs claude with cwd = "$WORKSPACE/labops-tg-plugin/plugin".
# When that path is a symlink to the shared monorepo checkout, claude
# canonicalises it, so EVERY agent ends up with the same project directory.
# Claude Code keys per-project state in ~/.claude.json by that canonical cwd,
# so two agents starting concurrently race on it: the loser comes up with no
# MCP servers at all — a live TUI whose channel never binds its webhook port
# and never writes channel.log. Observed on this host with developer+carmella.
#
# The fix is to give each agent its own real directory, so the canonical cwd
# is per-agent. Source is ~2MB and is copied; node_modules is ~60MB and is
# symlinked to the shared checkout, so the disk cost stays small.
#
# provision_plugin <src_plugin_repo> <workspace>
#   src_plugin_repo — the tg-plugin checkout (contains plugin/)
#   workspace       — the agent's .claude workspace
# Idempotent: refreshes source on every call, leaves per-agent state alone.

provision_plugin() {
  local src="$1" ws="$2"
  local src_plugin="$src/plugin"
  local dest="$ws/labops-tg-plugin"
  local dest_plugin="$dest/plugin"

  [ -d "$src_plugin" ] || { echo "[plugin] source not found: $src_plugin" >&2; return 1; }

  # Migrate the legacy shared symlink — it is the bug described above.
  if [ -L "$dest" ]; then
    rm -f "$dest"
    echo "[plugin] removed legacy shared symlink → provisioning a private copy"
  fi

  mkdir -p "$dest_plugin"

  # Copy sources, never node_modules (symlinked below) and never state
  # (per-agent runtime data that must not be clobbered on refresh).
  local item
  for item in package.json bun.lock tsconfig.json README.md src scripts docs tests; do
    [ -e "$src_plugin/$item" ] || continue
    if [ "$item" = "src" ]; then
      # keep src/state if the agent already accumulated one
      mkdir -p "$dest_plugin/src"
      (cd "$src_plugin/src" && tar cf - --exclude=state .) | (cd "$dest_plugin/src" && tar xf -)
    else
      cp -a "$src_plugin/$item" "$dest_plugin/"
    fi
  done

  # node_modules stays shared — read-only at runtime, 60MB per agent otherwise.
  if [ ! -e "$dest_plugin/node_modules" ]; then
    if [ -d "$src_plugin/node_modules" ]; then
      ln -s "$src_plugin/node_modules" "$dest_plugin/node_modules"
    else
      echo "[plugin] WARN: $src_plugin/node_modules missing — run 'bun install' in $src_plugin" >&2
    fi
  fi

  # Mirror the repo root files the plugin expects one level up (.mcp.json etc).
  for item in .mcp.json package.json; do
    [ -e "$src/$item" ] && cp -a "$src/$item" "$dest/" 2>/dev/null || true
  done

  echo "[plugin] provisioned private copy: $dest_plugin"
}
