# Final Review Fix Report — install.sh

**Branch:** main  
**Base commit:** d426442  
**Date:** 2026-07-08

---

## Finding 1 — Correctness: `--test-only` ran the full clone+install-siblings block

### Problem
The `[ "$MODE" = "test" ] && exit 0` guard was at line 181, **after** the sibling clone+install block (lines 135–171). Running `./install.sh --test-only` would still clone `labops-second-brain` and `labops-tg-plugin` from GitHub and run their full `install.sh` scripts before ever checking the mode.

### Fix
Wrapped the SB/TG variable assignments, `clone_repo()` invocations, and sibling installer calls (old lines 135–171) in:

```bash
if [ "$MODE" != "test" ]; then
  ...
fi  # [ "$MODE" != "test" ]
```

The `clone_repo()` function **definition** (lines 104–134) was intentionally left outside the guard — it is harmless to define without calling, and keeping it unguarded avoids any future confusion about scope.

`SB` and `TG` variables are only referenced after the guard block at lines 200–201 (`[ -n "$SB" ] && export ...`), which are inside the full-mode-only section that is already unreachable in test mode (the script exits at line 185 `[ "$MODE" = "test" ] && exit 0`).

### Changed lines
- Added `if [ "$MODE" != "test" ]; then` before `SB="${SECOND_BRAIN_DIR:-...}"` (after line 135 in original, now line 136)
- Added `fi  # [ "$MODE" != "test" ]` after the closing `fi` of the SB install block (after original line 171, now line 176)

---

## Finding 2 — Docs accuracy: stale "pre-install siblings" comment

### Problem
Lines 9–11 told the operator to manually pre-install `labops-second-brain` and `labops-tg-plugin`, contradicting the `clone_repo()` function which clones them automatically.

### Fix
Replaced:
```
# Зависимости (поставьте сначала):
#   • labops-second-brain — общий мозг (для токена агента)
#   • labops-tg-plugin    — Telegram-канал (бот, голос)
```
with:
```
# Ставит сам: tmux/git/curl/jq/unzip, Claude Code (нативно, без Node.js),
# и клонирует+ставит соседние репозитории:
#   • labops-second-brain — общий мозг (для токена агента)
#   • labops-tg-plugin    — Telegram-канал (бот, голос)
```

---

## Verification

### 1. Syntax check
```
$ bash -n /home/myaiagent/labops-agent-architecture/install.sh
exit_code=0
```
No output — syntax is valid.

### 2. Dry-run of guarded block with MODE="test"
Extracted the guarded section with stub functions (`clone_repo`, `say`, `ok`, `warn`, `die`) and ran with `MODE="test"`:

```
clone_repo calls: 0
sibling install calls: 0
PASS: test mode correctly skips all clone+install-siblings calls
dry_run_exit=0
```

`clone_repo` was never called, no sibling `install.sh` was invoked — confirming the guard works correctly.

---

## Commit hash
`f4fcd24` — fix(install.sh): --test-only теперь пропускает клонирование/установку соседних репо; обновлён заголовочный комментарий
