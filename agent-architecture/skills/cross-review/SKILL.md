---
name: cross-review
description: Cross-review PRs between agents. Use when reviewing a PR written by another agent, preparing a PR that needs cross-review, or checking change levels and merge rules.
---

# Cross-Review

Review of pull requests between agents of one team: the author of a change is never its
reviewer.

## Rule

- A PR by agent A is reviewed by agent B, and the other way round.
- Nobody approves their own PR.
- Top-level changes (L3) are merged only by the owner.

Who reviews whom comes from the team roster in `~/.claude-lab` and the task board in
second_brain; if the pairing is not obvious, ask the owner before reviewing.

## Change levels

| Level | What | Review | Merge |
|-------|------|--------|-------|
| L0 | Typo, docs | Any agent | Reviewer |
| L1 | Scripts, configs, agent instructions, skills | Cross-reviewer | Reviewer |
| L2 | Deploy, auth, CI, multi-server | Cross-reviewer + green CI | Reviewer |
| L3 | Rules shared by all agents, adding or removing an agent | Cross-reviewer + owner | Owner |

## How to review

1. Fetch the diff and the changed files with `gh api` or `gh pr diff`.
2. Decide the change level (L0-L3).
3. Check logic, security, style, tests, breaking changes.
4. Answer APPROVE, REQUEST_CHANGES or COMMENT, each with reasoning.
5. Merge only if APPROVE, CI is green and the level is below L3.

For high-risk changes (P0/P1 bugs, security, several servers, financial code) ask the
owner for an additional independent review instead of merging on one approval.

Deploying after a merge is a red-zone action: it always goes through the owner.

---
Adapted from `cross-review` in https://github.com/qwwiwi/agentos-skills-public (MIT,
commit 3a8efdcaa8dce35ebaafd389e4b98ac79a0b0802): the author's repository, agent names,
servers and rollout commands are removed.
