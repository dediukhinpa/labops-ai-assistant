# Token Optimization Guide

How to reduce token usage by 60-70% from day one. Essential for cost control and agent performance.

## Quick Setup: settings.json

Add to `~/.claude/settings.json` (global) or `.claude/settings.json` (project-only):

```json
{
  "env": {
    "CLAUDE_CODE_AUTO_COMPACT_WINDOW": "400000"
  }
}
```

### Auto-compaction window

Set `CLAUDE_CODE_AUTO_COMPACT_WINDOW=400000` in settings.json env block. This is the ONLY env variable you need to change. Recommended by Boris Cherny (Claude Code lead at Anthropic). Auto-compaction triggers at 400K instead of default 800K, giving the agent deeper thinking within the working window.

Do not set MAX_THINKING_TOKENS, SUBAGENT_MODEL, or CLAUDE_AUTOCOMPACT_PCT_OVERRIDE -- leave defaults.

### What this does

| Setting | Default | Recommended | Why |
|---------|---------|-------------|-----|
| `CLAUDE_CODE_AUTO_COMPACT_WINDOW` | ~800000 | **400000** | Default auto-compact triggers at ~800K tokens (80% of 1M context window). Setting to 400K compacts earlier, keeping context fresh and improving thinking depth. Recommendation from Boris Cherny (head of Claude Code at Anthropic) |

## Model Strategy

### Core principle

**The strongest model for code and decisions, a cheaper one for subagents and bulk
work.** The model is the operator's decision; `create-agent` asks for it and
defaults to `sonnet`.

### Model roles

Agents are configured with **aliases**, not version numbers: an alias always points at
the latest model of its tier, a number in a doc silently goes stale. A full model name
in `settings.json` pins a version on purpose.

| Alias | Role | Use for |
|---|---|---|
| **fable** / **opus** | Primary for heavy work | Code writing, review, planning, coordination |
| **sonnet** | Default primary; subagents | Everyday agents, research, search, exploration |
| **haiku** | Subagents only, never primary (installers reject it: a Haiku agent stays silent in Telegram) | Quick lookups, simple transforms |
| Model from another vendor | Optional | Second opinion in a double review |
| Perplexity Sonar | Optional (`RESEARCH_MODEL`) | Web research, fact-checking |

> **Opus via OpenRouter — NEVER.** Use the native Anthropic API or a Claude subscription.

### Cost

Current per-token prices are on the Anthropic pricing page; they change, so they are
not copied here. On a subscription all models are included and the cost is rate-limit
consumption, not money: cheaper subagents mean faster answers and less of the limit
spent.

### Practical model strategy

| Agent role | Model | Why |
|-----------|-------|-----|
| Coordinator | opus / fable | Deep reasoning for routing, planning |
| Coder | opus / fable | Code quality needs the strongest model |
| Code reviewer | opus + a model from another vendor | Two independent opinions |
| Subagents (search, analysis) | sonnet | Fast, cost-effective for bulk work |
| Web research | Perplexity Sonar | Specialized for web search |

## Context Management

### The problem

Claude Code has a base context window of 1,000,000 tokens (1M). However, model quality degrades well before that limit. We set `CLAUDE_CODE_AUTO_COMPACT_WINDOW=400000` to auto-compact at 400K — this is the **working context**. As conversation approaches this limit:
- Agent quality **degrades** past ~50% of working context (~200K tokens)
- Instructions get ignored
- Responses become less focused

### The solution: active context management

| Action | Command | When | Cost |
|--------|---------|------|------|
| **Compact** | `/compact` | At logical breakpoints | Free (conversation summary) |
| **Clear** | `/clear` | Between unrelated tasks | Free (full reset) |
| **Check usage** | `/cost` | Periodically | Free |

### When to compact vs clear

```
Same project, continuing work?
  └── /compact (keeps summary, loses raw messages)

Switching to different project/topic?
  └── /clear (full reset, clean start)

Agent acting weird / ignoring instructions?
  └── /clear (context is probably polluted)
```

## Memory Budget: What Eats Your Context

Every session starts by loading these files:

| File | Typical size | Tokens (~) | Can you reduce? |
|------|-------------|------------|-----------------|
| ~/.claude/CLAUDE.md | 2-7 KB | 900-3,200 | Keep under 200 lines |
| CLAUDE.md (SOUL) | 3-8 KB | 1,300-3,500 | Keep under 200 lines |
| core/AGENTS.md | 2-5 KB | 900-2,400 | On-demand (Read tool), NOT @include |
| core/USER.md | 1-2 KB | 400-765 | Minimal |
| core/rules.md | 2-4 KB | 900-1,935 | Only active rules |
| core/passive/decisions.md + preferences.md | 1-3 KB | 450-1,400 | Consolidated in-session (reflection), decayed by nightly bash |
| **core/active/episodic.md** | **8-30 KB** | **3,600-13,500** | Raw diary, on-demand Read (NOT @include); size-rolled to archive |
| tools/TOOLS.md | 3-6 KB | 1,300-2,565 | On-demand (Read tool), NOT @include |
| **TOTAL** | **22-65 KB** | **9,750-29,700** | |

### How to keep it lean

1. **CLAUDE.md under 200 lines** -- Anthropic's recommendation. Move reference material to skills.
2. **Keep episodic out of context** -- `episodic.md` is the raw diary, loaded on-demand (not @include); `archive-roll.sh` size-rolls it to `archived/episodic/`. What loads is the distilled `decisions.md` and `preferences.md`. See MEMORY.md.
3. **Prune TOOLS.md** -- Remove servers/services you don't actively use.
4. **Don't duplicate rules** -- Global `~/.claude/rules/*.md` apply to all agents. Don't repeat in per-agent rules.

## Output Compression: Terse Mode

The single biggest hidden cost is **output tokens** -- verbose responses eat 3-5x more than necessary. Add this to CLAUDE.md or rules.md to cut output tokens by up to 75%:

```markdown
## Output style
Drop: articles (a/an/the), filler (just/really/basically/actually/simply),
pleasantries (sure/certainly/of course/happy to), hedging.
Fragments OK. Short synonyms (big not extensive, fix not "implement a solution for").
Technical terms exact. Code blocks unchanged. Errors quoted exact.

Pattern: [thing] [action] [reason]. [next step].
```

### Before vs After

| Before | After | Savings |
|--------|-------|---------|
| "Sure! I'd be happy to help you with that. The issue you're experiencing is likely caused by a problem in the authentication middleware." | "Bug in auth middleware. Token expiry check uses `<` not `<=`. Fix:" | ~75% |
| "I've successfully implemented the changes you requested. The function now correctly handles edge cases." | "Done. Edge cases handled." | ~80% |

### Why it works

- **Output tokens cost 5x more than input** (Opus: $15 input vs $75 output per 1M)
- Shorter responses = faster streaming = less rate limit consumed
- Agent still writes full code blocks and exact error messages -- only prose is compressed
- On Max subscription: same quality, 3x faster responses

### How aggressive to go

| Level | Add to rules | Effect |
|-------|-------------|--------|
| **Light** | "Be concise. No filler." | ~30% reduction |
| **Medium** | The full prompt above | ~60% reduction |
| **Heavy** | Add: "Max 2 sentences per response unless code." | ~75% reduction |

## Beginner Mistakes to Avoid

| Mistake | Why it's bad | Fix |
|---------|-------------|-----|
| A light model on a code-heavy agent | Code quality suffers | `opus` / `fable` for agents that write a lot of code (operator's call) |
| Never compacting | Context pollution, quality drops | `/compact` at logical breakpoints |
| CLAUDE.md > 200 lines | Agent ignores instructions | Extract to skills, keep core lean |
| Loading raw episodic into context | episodic diary eats 70% of context | Load only the distilled `passive/` files, keep `episodic.md` on-demand (see MEMORY.md) |
| Running everything in one session | Context fills up | `/clear` between unrelated tasks |
| Not checking /cost | Surprise bills or slow responses | Check periodically |

## Summary: Day 1 Checklist

- [ ] Set `CLAUDE_CODE_AUTO_COMPACT_WINDOW: 400000` in settings.json
- [ ] Use Opus as primary model (code, review, planning)
- [ ] Use Sonnet for subagents (search, research, exploration)
- [ ] Keep CLAUDE.md under 200 lines
- [ ] Use `/compact` at logical breakpoints
- [ ] Use `/clear` between tasks
