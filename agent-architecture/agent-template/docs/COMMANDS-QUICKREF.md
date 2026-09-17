# Commands Quick Reference

Essential commands for daily work with Claude Code. Organized by workflow.

> **NOTE:** Skills are copied from `agent-architecture/skills` into
> `~/.claude-lab/shared/skills`, which every workspace links to -- nothing extra to install.
> After `git pull`: `bash orchestration/sync-skills.sh`.

## Core Workflow

Built into Claude Code:

| Command | What it does | When to use |
|---------|-------------|-------------|
| Plan mode (`Shift+Tab`) | Plan before touching files | Before any non-trivial feature or fix |
| `/code-review` | Quality + security review | After writing code, before commit |
| `/compact` | Compress conversation context | When the agent starts forgetting or slowing down |
| `/clear` | Reset conversation (free, instant) | Between unrelated tasks |
| `/cost` | Token usage of the session | Checking where tokens go |

`/tdd`, `/verify`, `/fix`, `/refactor` are **not** built in: they exist only if you add
a plugin or your own skill that defines them (see *Superpowers Commands* below).

In an agent driven from Telegram these commands are typed in the tmux session, not in
the chat; the chat has its own commands (`/reset force`, `/status`, `/doctor`).

## Decision Tree: What Command Do I Need?

```
Starting a task?
  └── plan mode (plan first)

Code is written?
  ├── Review it → /code-review
  ├── Run tests → the project's own test command
  └── Ready to merge → commit and open a PR

Context issues?
  ├── Agent is confused → /compact
  ├── Switching tasks → /clear
  └── Check token usage → /cost
```

## Session Management

| Command | What it does | When to use |
|---------|-------------|-------------|
| `/compact` | Summarize old messages, free context | At logical breakpoints (auto-compact handles 400K limit) |
| `/clear` | Full reset -- new conversation | Between unrelated tasks |
| `/cost` | Show token usage and cost | Monitor spending |
| `/model opus` | Switch to Opus | Complex architecture decisions |
| `/model sonnet` | Switch to Sonnet | Routine coding, bulk work |

## Git Workflow

| Command | What it does | When to use |
|---------|-------------|-------------|
| `git status` | Check what changed | Before committing |
| `git diff` | See exact changes | Review before commit |
| `/commit` | Create commit (if skill installed) | After verified chunk of work |

## Superpowers Commands (optional plugin)

These come from the third-party Superpowers plugin. The installer does **not** install
it, so agents do not have these commands unless you add the plugin yourself:

| Command | What it does | When to use |
|---------|-------------|-------------|
| `/plan` | Structured implementation plan | Before any non-trivial work |
| `/tdd` | Test-driven development scaffold | New features |
| `/brainstorm` | Explore ideas before implementation | Creative or ambiguous tasks |
| `/debug` | Systematic debugging workflow | When something breaks |

## Tips for Beginners

1. **Plan first** -- even for "quick" tasks. Plans catch issues before they cost time.

2. **Use /clear between tasks** -- it's free and prevents context pollution.

3. **Use /compact at logical breakpoints** -- after research (before implementation), after implementation (before testing).

4. **Pick the model per role.** `create-agent` defaults to `sonnet`; choose `opus` or `fable` for agents that write a lot of code. Changing a model is the operator's call.

5. **Check /cost regularly** -- understand where tokens go.

## Command vs Skill vs Agent

| When you want to... | Use |
|---------------------|-----|
| Run a quick action | **Command** (`/compact`, `/clear`, `/code-review`) |
| Apply specialized knowledge | **Skill** (groq-voice, memory-consolidate, agent-browser) |
| Delegate a complex task | **Agent** (subagent via Agent tool) |

Commands are for **you** (operator). Skills are for **knowledge**. Agents are for **delegation**.
