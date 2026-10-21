---
name: customer-research
title: Customer Research
description: Use when analyzing interviews, surveys, reviews or tickets, mining forums/review sites for voice of customer, building personas or JTBD maps, or finding why customers buy or churn.
category: research
requiresTools: [web_fetch]
status: ready
origin: dot-claude/skills/customer-research
---

# Customer Research

Uncover what customers actually think, feel, say and struggle with, so positioning, product and copy rest on evidence, not assumptions.

Start from known context ({{company.description}}, {{audience.icp}}, {{products.list}}, {{competitors.list}}; `memory_search` for earlier research). Ask first: **goal** (messaging, personas, product gaps, churn?) and **what they already have** (transcripts, surveys, tickets, reviews, nothing). Then, as needed: target segment (all, a tier, churned, lost prospects), product, desired deliverable. Don't ask everything at once.

## Two modes
- **Mode 1 — analyze existing assets** the client sends (paste, file content, or links to `web_fetch`).
- **Mode 2 — go find research** online. Use `web_search` if available; otherwise propose search queries, ask the client for the result links or exports, and read public pages with `web_fetch`. Logged-in/JS-heavy sites (LinkedIn, TikTok, app stores) may not load — ask for screenshots or copy-paste.
Most engagements combine both.

## Mode 1: assets
- **Interview / sales-call transcripts**: pains, triggers, desired outcomes, language, objections, alternatives; the moment they decided to look, what they tried before, what success looks like.
- **Surveys**: segment (tier, use case, tenure) before concluding; open-ended vs multiple choice often conflict; find the 20% of answers with most signal.
- **Support tickets**: categorize first; separate bugs / confusion / missing features / expectation mismatch; capture "I wish it could…".
- **Win/loss & churn**: wins — what tipped it, what almost lost it; losses — price, features, fit, timing, other. Segment by reason; never average across causes.
- **NPS**: passives and detractors carry more improvement signal; pair scores with verbatims.

### Extraction (per asset)
1. **Jobs to be done** — functional (task), emotional (how they want to feel), social (how they want to be seen).
2. **Pain points** — prioritize unprompted, emotionally charged ones.
3. **Trigger events** — team growth, new hire, missed target, embarrassing incident, competitor move.
4. **Desired outcomes** — exact quotes.
5. **Language** — exact phrases ("we were drowning in spreadsheets" > "manual process inefficiency").
6. **Alternatives** — incl. doing nothing, hiring, building in-house.

### Synthesis
Cluster by theme → score frequency × intensity → segment by profile (size, role, use case, tenure) → pick 5–10 verbatim "money quotes" per theme → flag contradictions (say vs do).

### Quality guardrails
| Confidence | Criteria |
|---|---|
| High | 3+ independent sources, unprompted, consistent across segments |
| Medium | 2 sources, or prompted only, or one segment |
| Low | Single source; possible outlier; validate |
- Recency: last 12 months primary; 12–24 months with caution; older only as baseline.
- Sample bias: reviewers skew power users/strong opinions; tickets skew problems; Reddit skews technical/skeptical.
- No personas or messaging conclusions from <5 independent data points per segment.
- Never invent quotes, sources or numbers. Every quote keeps its source and date.

## Mode 2: digital watering holes

| ICP | Primary sources |
|---|---|
| B2B SaaS / technical | Role subreddits, G2/Capterra, Hacker News, LinkedIn, Indie Hackers, SparkToro |
| SMB / founders | r/entrepreneur, r/smallbusiness, Indie Hackers, Product Hunt, Facebook Groups |
| Developers | r/devops, r/programming, HN, Stack Overflow, Discord |
| B2C | App store 1–3★ reviews, hobby subreddits, YouTube/TikTok/Instagram comments |
| Enterprise | LinkedIn, analyst reports, G2 enterprise filter, job postings |

Quick guide: product category → G2/Capterra (own + competitors); where audience hangs out → SparkToro; raw language → Reddit, YouTube comments; triggers → LinkedIn posts, job postings, "Ask HN"; competitive intel → competitors' 4★ reviews, Product Hunt discussions.
Adapt to {{audience.geo}}: local review sites, forums and messengers matter more outside the US.

Capture per item: source (platform, URL, date) | verbatim quote | context | sentiment | theme tag (pain/trigger/outcome/alternative/language/objection/competitor) | profile signals.
Per-platform playbooks, search operators, review reading order, source weighting: `skill_read("customer-research", "references/source-guides.md")`.

### Synthesis template
```
## Top themes (frequency × intensity)
### Theme 1: [Name]
Summary: [1–2 sentences]
Frequency: X of Y sources | Intensity: High/Med/Low | Confidence: High/Med/Low
Quotes:
- "[exact quote]" — [source, date]
Implications: messaging / product / positioning
```

## Personas
Only from research: ≥5–10 data points from a consistent segment.
```
## [Persona] — [Role]
Profile: title range; company size/stage; industry; reports to; team size
Primary job to be done: [one sentence]
Trigger events: - …
Top pains (their words): 1. … 2. … 3. …
Desired outcomes: success looks like; how measured; how it makes them look
Objections and fears: - …
Alternatives: competitor / DIY / do nothing / hire
Key vocabulary: "…", "…"
How to reach: channels; content consumed; trusted influencers/communities
```
Anti-patterns: cute names ("Marketing Mary") that distract; averaging across segments; inventing details (leave blank); not revisiting quarterly.

## Deliverables (ask which)
1. Research synthesis report. 2. VOC quote bank by theme. 3. 1–3 personas. 4. JTBD map by segment. 5. Competitive intel (what customers say about them vs us). 6. Research gap analysis (what's unknown, how to find it).
Inline for short outputs; `deliver_file` (MD/CSV) or `document_render` (DOCX/XLSX) for long ones. Save key findings with `memory_write`; propose ICP updates via `profile_propose_update` if available.

Related: copywriting, cro, competitor-profiling, content-strategy, product-marketing, pricing.
