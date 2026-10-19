# Phase design, planning depth, and handoff

## How many phases?

Derived from the work, never chosen to hit a number. Loose orientation:

- **2** — a small change plus a real polish pass. Below that, don't use this machinery.
- **3-4** — small projects, single surface (one page, one route, one report, one migration).
- **5-7** — typical projects (foundation + core + integration + states/edges + polish).
- **8-12** — large projects, full builds from scratch, complex restructurings that need a safety net and staged migration.
- **13+** — major migrations, multi-system rewrites, untangling a mess.

Two tests for the right count:
1. **Each phase is independently verifiable** — it stands on its own and could be shipped as a partial increment. If a phase only makes sense once the next is done, merge them.
2. **Each phase delivers one coherent thing** — if you can't name it in five words without "and", split it.

## Phase shapes that work

**Standard build (5):** 1 Foundation (structures, schemas, scaffolding — builds but no behavior) · 2 Core mechanic (the central thing, main path working) · 3 Integration (wire into existing surfaces, permissions, navigation) · 4 States & edges (loading, empty, error, unauthorized, weird inputs) · 5 Polish & Harden.

**Refactor / restructure existing (5):** 1 Safety net (characterization tests, or a baseline snapshot of current numbers) · 2 Extract (pull out the abstractions without changing behavior) · 3 Migrate (move consumers over, one cluster at a time) · 4 Delete the old · 5 Polish & Harden.

**Redesign (5):** 1 Tokens & primitives · 2 Layout and navigation · 3 Content surfaces, most prominent first · 4 Interactions and transitions · 5 Polish & Harden.

**Business project (example, market entry):** 1 Research & sizing · 2 Offer and pricing · 3 Channels and funnel · 4 Operations and fulfillment readiness · 5 Pilot with measured criteria · 6 Polish & Harden (legal, support, edge cases, reporting).

## Acceptance criteria

Each criterion must be:
- **Observable** in what you show the client — "the build succeeds" is good, "it feels right" is not.
- **Atomic** — one fact per criterion.
- **Falsifiable** — yes or no, not "kind of".
- **Tied to a check or artifact** — command output, a file, a number, a screenshot the client sent.

Bad: "User authentication works."
Good:
- `npm run build` succeeds with 0 errors
- `npm run typecheck` succeeds with 0 errors
- Tests in `tests/auth/*.test.ts` pass
- `/api/auth/signin` returns 200 for valid credentials and 401 for invalid
- Middleware rejects requests without a session cookie

Bad: "The report is correct."
Good:
- Revenue total matches the accounting export to the smallest currency unit ({{finance.currency}})
- Refunds appear once, not twice (spot-check 3 known refunds by id)
- Every region in the source appears in the output, none extra
- The file opens in the client's spreadsheet tool without a format warning

## Mandatory checks per phase

Software, adjust per stack:

```
- build       (must exit 0)
- typecheck   (must exit 0)
- lint        (must exit 0, or only pre-existing warnings)
- test        (must exit 0, or pre-existing failures proven unrelated)
```

Business: the reconciliation, the sample check, the client's sign-off on the artifact, the metric reading — named exactly, with the source.

If the output is too long to show, require a summary line ("Tests: 47 passed, 0 failed") plus the full output saved somewhere the client can open.

## Cleanliness check (software phases)

At verification, check the lines added since the baseline for: debug prints left behind (`console.log`, `print(`, `fmt.Println`, per stack), TODO/FIXME introduced in this run, and unused imports added. Non-zero counts are treated as a failed criterion. If a phase legitimately ships debug output (it *is* the logging feature), declare the exception in the phase spec and report the counts without failing.

## Evidence

The client only sees what you show them. Per phase, name what you'll show:
- Command output excerpts (last ~10 lines, plus exit code)
- The artifact itself (file, document, link) or its key section
- Key changes inline, not full diffs
- Screenshots for visual work (ask the client to capture them if you can't)
- Numbers before/after for anything measured
- The updated status line for the phase

## Dependencies

State them explicitly — "phase 4 depends on 1, 2 and 3", not "the previous ones". Almost always linear. If you want two phases to run in parallel, you probably want sub-steps inside one phase.

## Polish & Harden — non-negotiable last phase

Its job is catching what the earlier phases missed while they were focused on shipping behavior:

1. **Wording & UX** — every visible string reads well; no placeholders, no lorem ipsum, brand tone applied.
2. **States** — empty, loading, error, unauthorized verified for every new surface.
3. **Edges** — empty input, very long input, special characters, slow network, missing data.
4. **Security & privacy** — input validation, access checks, no secrets exposed, personal data handled per {{company.jurisdiction}} rules.
5. **Accessibility** (visual work) — keyboard navigation, focus states, labels, contrast.
6. **Performance** — no obvious inefficiency (N+1 queries, megabyte assets, blocking work).
7. **Diff / change review** — the full change reviewed for debris: debug logs, commented-out code, this-run TODOs.
8. **Regression sweep** — re-run the full check set; exercise one or two adjacent features or reports that should be unaffected.

Each sub-pass produces one short paragraph: what was checked, what was found, what was fixed.

## Planning depth — the bar

A plan clears the bar when a competent stranger reading it cold could:
1. Predict every artifact that will be created or touched, at the right granularity.
2. Name the top 3 things that could go wrong and what's being done about each.
3. Verify each phase without reading the next.
4. Say what "done" looks like in measurable terms.

Weak on any of the four → think more before writing the roadmap.

### What to think about, by type

- **From scratch:** the choice of stack/tools *and why*; initial structure; what's deferred and why that's safe; the first usable output.
- **Changing something existing:** which conventions the new work must match; what it shares with existing parts (extract before adding?); the migration story if data changes; backward compatibility.
- **Fixing:** the actual root cause, not the symptom; what check would have caught it and should now exist; whether the fix belongs in several places; the regression surface.
- **Restructuring:** the concrete current pain (not abstract), the destination, the intermediate states (each must leave things working), and what stays out of scope.
- **Visual work:** reference examples (find them or ask); existing tokens to match, not reinvent; responsive breakpoints in scope; accessibility; empty/loading/error states — these are most of "polish".

### The risk list

Three risks, ranked, each with: what could go wrong, how likely (a gut estimate is fine), and what the plan does about it (mitigation, or accepted risk with a reason). Can't name three plausible risks? The goal is too small for this skill, or you haven't thought hard enough.

### What this is not

Not a 20-page design document (the thinking note fits on two pages). Not a diagram festival. Not where the work gets done. Not where every assumption is validated with the client — most assumptions are recorded and surfaced at the approval gate.

## Handoff brief (when someone else executes)

When the client's developers, a coding agent or contractors will execute, deliver a self-contained brief per phase so they need nothing from this conversation:

```markdown
## Phase <N> of <total> — <name>
**Goal:** <one line>
**Depends on:** <phases, and what must already be true>
**Context:** <where this fits; the conventions to follow; links to the artifacts>
**Work:**
- <bullet>
**Acceptance criteria (all must pass):**
- <criterion>
**Mandatory checks (run each, report output + exit code):**
- <check>
**Evidence to return:**
- <what to send back>
**Out of scope:** <explicitly>
**If blocked:** report what failed, what you tried, and what you need — do not improvise the scope.
```

Plus, once: the roadmap, the assumptions, the risks, and the definition of done. Then ask for the evidence per phase and run the final audit yourself against the original roadmap.
