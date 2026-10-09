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

# clear_foreign_modules <plugin_dir> — убрать ссылку node_modules, через которую
# не пройдёт bun install.
#
# Воркспейс агента получает node_modules СИМЛИНКОМ в общий checkout (см. выше),
# и ссылка эта абсолютная. Если такое дерево потом скопировали на другую машину
# или в другой $HOME, она указывает в никуда: `[ -d node_modules ]` отвечает
# «нет», а `bun install` падает с `ENOENT: could not open the "node_modules"
# directory` и битую ссылку сам не убирает — установка встаёт насмерть и
# повторные запуски не помогают (09.10.2026: у клиента ссылка вела в
# /home/labops чужой машины).
#
# Ссылку на ЖИВОЙ каталог не трогаем — она рабочая и экономит ~60 МБ на агента.
clear_foreign_modules() {
  local plugin_dir="$1" link="$1/node_modules" target
  [ -L "$link" ] || return 0
  [ -d "$link" ] && return 0
  target="$(readlink "$link" 2>/dev/null || true)"
  rm -f "$link"
  echo "[plugin] убрана битая ссылка node_modules → ${target:-?}" >&2
}

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

  # Copy sources; only node_modules is excluded (symlinked below).
  # NB: src/state is SOURCE (src/state/store.js), not runtime data — excluding
  # it breaks the server with "Cannot find module './state/store.js'".
  # Per-agent runtime state lives outside the tree, in $TELEGRAM_STATE_DIR.
  # .mcp.json is what registers the `labops-channel` MCP server — without it
  # claude starts and reports "no MCP server configured with that name", so the
  # dotfiles below are load-bearing, not cosmetic.
  local item
  for item in package.json bun.lock tsconfig.json README.md src scripts docs tests \
              .mcp.json .npmrc .gitignore; do
    [ -e "$src_plugin/$item" ] || continue
    cp -a "$src_plugin/$item" "$dest_plugin/"
  done
  [ -f "$dest_plugin/.mcp.json" ] \
    || echo "[plugin] WARN: .mcp.json missing — the channel MCP server will not register" >&2

  # node_modules stays shared — read-only at runtime, 60MB per agent otherwise.
  # Битую или чужую ссылку чиним здесь: provision_plugin зовётся при каждом
  # создании и обновлении агента, а `-e` ниже на битой ссылке даёт «нет» — без
  # этих двух шагов она оставалась на месте навсегда.
  clear_foreign_modules "$dest_plugin"
  if [ -L "$dest_plugin/node_modules" ] \
     && [ "$(readlink "$dest_plugin/node_modules")" != "$src_plugin/node_modules" ]; then
    rm -f "$dest_plugin/node_modules"
    echo "[plugin] ссылка node_modules вела в другой checkout — переставил на $src_plugin" >&2
  fi
  if [ ! -e "$dest_plugin/node_modules" ]; then
    if [ -d "$src_plugin/node_modules" ]; then
      ln -s "$src_plugin/node_modules" "$dest_plugin/node_modules"
    else
      echo "[plugin] WARN: $src_plugin/node_modules missing — run 'bun install' in $src_plugin" >&2
    fi
  fi

  echo "[plugin] provisioned private copy: $dest_plugin"
}
