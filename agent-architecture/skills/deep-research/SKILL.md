---
name: deep-research
description: Use when a question needs research across several sources — comparing options, understanding a market, a technology or a topic's history, checking a claim — and the result must be a cited report with stated confidence and gaps. Not for a single quick fact lookup.
---

# Deep Research

A cited, cross-checked answer built from several independent sources. The goal is a report
the operator can trust: every claim traceable, every gap named.

## Before you search

1. **Recall first.** `memory_router(query)` -- a teammate may already have researched this.
   Reuse what is there and say what is new.
2. **Pin the question down.** One sentence for the question, one for what the answer will be
   used for, the time horizon, the region/language of sources. If any of it is unclear, ask the
   operator before spending effort.
3. **Split into 3-7 sub-questions** that together answer the main one. Write them down.

## Sources and tools

Use what this workspace actually has; check before assuming.

- Web search and page fetch built into the session for the broad sweep.
- `perplexity-research` skill for sourced answers, only if its API key is configured.
- `markdown-new` skill to get clean text from a page, `transcript` for YouTube talks.
- Paid APIs and anything that costs money are a red-zone action: ask the operator first.

Prefer primary sources (official docs, filings, papers, the vendor's own pages) over articles
about them. Note the publication date of each source; for fast-moving topics, drop anything old.

## Method

1. For each sub-question collect at least **two independent sources**. Several articles that
   repeat one press release count as one source.
2. Read the page, not just the snippet. Quote the exact passage you rely on.
3. Where sources disagree, keep both claims, say who says what, and judge which is stronger and
   why. Do not average them into a claim nobody made.
4. Separate **fact** (sourced), **estimate** (derived, show the arithmetic) and **assumption**
   (nobody confirmed). Label each in the report.
5. Stop when new sources stop changing the answer, not after a fixed number of searches.
6. Independent sub-questions may go to background subagents when the operator allows it; the
   conclusions stay with you.

## Report

Write the result in the operator's language (see `core/USER.md`), in this order:

1. **Answer** -- two or three sentences, the conclusion first.
2. **Findings** -- one short section per sub-question, each claim followed by its source link
   and the source date.
3. **Disagreements and uncertainty** -- what is contested, what rests on one source.
4. **Gaps** -- what could not be found or verified, and what would settle it.
5. **Sources** -- the full list with links and dates.

Rules for the text: never invent a source, a number or a quote; a claim you could not source
is written as an assumption or left out; no filler about the research process.

## After

- Save the report as a file the operator can open and tell them where it is, then answer
  through the channel with the conclusion and the path.
- A durable finding other agents will need goes to second_brain as a knowledge note, following
  `SECONDBRAIN_WRITE_RULES.md` (recall before write, write to your own scope).
