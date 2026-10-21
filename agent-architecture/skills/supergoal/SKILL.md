---
name: supergoal
title: Big Goal, Phased to Done
description: >-
  Use when the client wants something big driven to completion — "plan it all out", "every aspect", "until it's done", a major project, migration or redesign.
category: productivity
requiresTools: [memory_search, memory_write]
status: ready
origin: dot-claude/skills/supergoal
---

# Big Goal, Phased to Done

For work too big for one plan and too important to drift: research it properly, cut it into independently verifiable phases with measurable criteria, get **one** approval, then execute phase by phase with a self-audit at the end.

Use for: a site rebuild, a market entry, a CRM migration, a hiring round for a whole department, a product launch, a large software feature or refactor.
Don't use for: anything under a few hours of work — just do it, or use `writing-plans`.

## What "every aspect is perfect" means

Translate the client's bar into measurable criteria, never vibes:

- **Functional** — it works for the main path and the obvious edge cases.
- **Quality** — the checks pass: numbers reconcile, copy matches the brand ({{brand.tone_of_voice}}), builds/tests are green, no new warnings.
- **Polish** — wording, error and empty states, the experience of whoever receives it.
- **Hardening** — security, privacy, validation, no regressions in what already worked.
- **Evidence** — every phase produces something the client can see and check.

If a phase can't be measured, it isn't a phase. Rewrite it until it can.

## The flow

0. **Context** — `memory_search` for prior decisions, preferences and the project's history; read the company profile and any knowledge-base documents (`knowledge_search`). List what you're inheriting: "Applied from memory: …". Resume, don't re-plan, if this goal already has a saved plan and status.
1. **Intake** — restate the goal in one sentence, classify it, then close every material gap:
   - **New from scratch:** you have only the client's words. Walk the checklist below and ask about every category the prompt and memory don't answer, in batches of up to 4 questions. Two batches is normal.
   - **Changing something that exists:** 0-2 questions. Study the current state first; it answers most structural questions.
2. **Recon** — study the current state: existing materials, systems, numbers, the code or documents involved, constraints. Ask the client for exports, access-free copies or screenshots of what you can't reach. Report a 5-line summary so they can see you understood it before you plan.
3. **Deep think** — the top 3 risks, the non-obvious dependencies, and current best practice for anything you shouldn't plan from memory (`web_search` / `web_fetch`). Write a short thinking note (1-2 pages max): goals, constraints, risks, dependencies, assumptions taken, what you researched.
4. **Decompose** — as many phases as the work needs (see the reference). Each independently verifiable, explicitly dependent on the ones before, with the last one always **Polish & Harden**.
5. **Write the roadmap** — the plan document (format below) plus one spec per phase.
6. **Self-critique, then one approval gate** (below). Wait for an explicit go.
7. **Execute** phase by phase (below), then the **final audit**, then report done.

### Intake checklist (for work from scratch)

| Category | Why it shapes the plan |
|---|---|
| Surface / platform | Where the thing lives: web, mobile, print, in-person, internal system — the biggest fork |
| Stack / tooling | Which systems and tools will be used; affects every phase |
| Direction / style | Visual and tonal direction ({{brand.visual_style}}); determines the polish phase |
| Anchors | Vendors and integrations locked in up front: payments, CRM, hosting, analytics, email |
| Scope cut-line | MVP this week vs the full thing; what is explicitly out of scope |
| Audience / use case | Who this is for ({{audience.icp}}); drives tone, flows, error tolerance |
| Performance / scale | Volumes, deadlines, peak load — only if non-trivial |
| Data | Shape of the data involved, if the goal implies any |

Process: for each category, check the prompt and memory first; surface what you found ("From your prompt: …", "Applied from memory: …"); ask only about real gaps; lead each batch with the highest-leverage choice.

Don't: ask one batch then silently assume the rest; pad questions with things you already know; ask micro-details (naming, exact wording, minor versions) — those go into the roadmap as assumptions for the approval gate.

## Phase anatomy

Each phase has: **name** (≤5 words, action-first, no "and"), **why** (one sentence), **deliverables** (concrete artifacts that will exist), **acceptance criteria** (5-10 measurable items), **mandatory checks** (the commands or verifications that must pass), **evidence** (what you'll show the client), **dependencies** (which phases must be done first).

## Roadmap format

```markdown
# Roadmap: <goal>

**Goal:** <one sentence>   **Type:** <new | change | fix | redesign>
**Created:** <date>   **Phases:** <N>

## Context
Current state · tools/systems · checks that must pass · risky areas

## Assumptions
<non-blocking decisions taken so we could proceed; correct any that are wrong>

## Top 3 risks
1. <risk> — likelihood <H/M/L> — mitigation <...>

## Phase map
| # | Phase | Depends on | Deliverable |
|---|---|---|---|
| 1 | <name> | — | <deliverable> |
| N | Polish & Harden | 1..N-1 | Every aspect verified |

## Phase 1 — <name>
**Why:** … **Deliverables:** … **Acceptance criteria:** [ ] … **Mandatory checks:** … **Evidence:** … **Dependencies:** …
```

Save the roadmap and the live status with `memory_write` (goal, phase list, current phase, decisions) so the work survives across conversations. Deliver the roadmap as a file (`deliver_file`) or inline.

## Approval gate (hard)

**Self-critique first** — one pass, three questions:
1. **Falsifiability** — is every criterion a yes/no test? Flag any "works", "good", "ready" without a measurable predicate, and rewrite them in place.
2. **Atomicity** — is any phase two phases in disguise (a name with "and", deliverables that don't share one check)?
3. **Weakest dependency** — where would a partial failure cascade worst?

Record either specific findings (1-3, with the rewrites applied) or "clean" — this pass must produce one or the other.

**Then present:** phase list with one-line deliverables · what was applied from memory · key assumptions to correct · top risks and mitigations · self-critique result · where the artifacts are.

Then ask one question with concrete options:
1. **Start now**
2. **Change an assumption** (which one)
3. **Tweak a phase** (criteria, scope, checks)
4. **Restructure phases** (merge, split, add, remove)

Apply changes, re-show the summary, ask again. **Never start on silence.**

**Pre-flight:** before phase 1, run the checks that must pass at the end (current build/test status, the current numbers, the current state of the page) to confirm the baseline isn't already broken. Broken baseline → surface it and ask: fix it as phase 1, or proceed knowingly.

## Execution loop

Per phase: do the work, then send one report that carries the phase header (number, name, criteria count) with the evidence and each criterion pass/fail → note anything learned worth keeping (`memory_write`) → mark the phase done and update the saved status → next phase. Never send a message that only announces a phase.

**Failure recovery, 3 strikes:**
1. First failure — state what failed, what you tried, your root-cause hypothesis (`systematic-debugging`); retry the phase once with that insight.
2. Second — write a focused fix spec for the failing criterion only (no scope creep) and execute it, then re-verify the phase.
3. Third — stop. Report: the failing criterion, the full history, three things tried, your recommended next move. The client takes the wheel. Don't keep trying.

**Interruption:** a client message between phases can change the plan: apply it to the affected phase spec before continuing, and say what changed.

**Steps you can't do** (publishing, paying, deploying, system access, running code): hand the client the exact instruction and the evidence you need back; the phase isn't done until they send it. This includes mandatory checks that are commands (a build, a test run): the client, or their developer, runs them and sends the output; never report such a check as passed without it.

## Final audit (before claiming done)

Per-phase checks are self-reports; a later phase can silently break an earlier one. After the last phase:

1. Re-read the **original** roadmap — pull every criterion fresh, don't trust your own summaries.
2. Every phase has a completion record? Name any that don't.
3. Re-run the aggregated mandatory checks once each; show the results.
4. Spot-check verifiable criteria (file exists, number matches, link works, config set). Non-deterministic ones (visual judgment, a manual smoke test) are marked "trust earlier verification" and not re-run.
5. Check each deliverable actually exists — don't accept "done" without the artifact.
6. Gaps → write a focused fix spec, execute, re-audit. Cap at 3 audit rounds; on the third failure, hand off with the full history.
7. Clean → report: phases verified, checks re-run, criteria passed vs trusted-from-earlier, deliverables present. If more than ~30% of criteria are "trusted from earlier", say so plainly: "audit coverage X re-verified / Y trusted — review the visual/subjective parts before shipping."

## Operating principles

- Frictionless is the goal: memory + prompt + recon should answer most questions. Zero clarifying questions on a well-described goal is a win.
- Adapt to what you have; degrade gracefully when a tool or a source isn't available, and say which assumption you're planning against.
- "Perfect" is not a stopping condition — criteria are.
- Two human gates only: clarifying gaps and plan approval. Between and after them, keep moving.
- The loop self-heals: retry once, then a fix spec, then escalate.
- Every phase is independently shippable in spirit.
- The Polish & Harden phase is mandatory — without it this is just a multi-step plan.

## Deviating

- Very small goal → say it doesn't need this machinery.
- Client pushes back during intake → collapse, re-plan, continue.
- Mid-run change → update the affected phase spec, then resume from the current phase, not from phase 1.

How many phases, phase shapes, criteria quality, and the handoff brief for a coding agent or dev team: `skill_read("supergoal", "references/phase-design.md")`
