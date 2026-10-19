---
name: competitor-profiling
title: Competitor Profiling
description: Use when researching competitors from their URLs — building profiles, dossiers or a competitive landscape summary with positioning, pricing, customers and SEO data.
category: research
requiresTools: [web_fetch]
status: ready
origin: dot-claude/skills/competitor-profiling
---

# Competitor Profiling

Turn a list of competitor URLs into structured, comparable profiles.

## Intake
Use {{competitors.list}} and {{company.description}}. Confirm:
1. **URLs** to profile.
2. **The client's own product** (for the comparison section).
3. **Depth** — quick scan (key facts) or deep profile.
4. **Focus areas** — pricing, positioning, SEO strength, content strategy.
If URLs and context are already known, proceed without asking.

## Principles
1. **Facts over opinions** — every claim traceable to a source (a page read, review data, a metric the client supplied). Label inferences as inferences.
2. **Structured and comparable** — same template for every profile; consistency beats completeness on any single one.
3. **Current data** — profiles are snapshots; always date them and flag staleness ("pricing page looks untouched since 2023").
4. **Honest assessment** — don't exaggerate weaknesses or downplay strengths.
5. **Never invent** a number, customer logo, funding round or rating. If it isn't on the page or in the client's export, write "not found".

## What the agent can gather
`web_fetch` reads one public page at a time. Work through the pages by hand:
- **Homepage** → headline, subheadline, value proposition, primary CTA, social proof claims, audience signals.
- **Pricing** → tiers, prices, per-tier features, billing options, free tier/trial, enterprise signals.
- **Features / product** → categories, key capabilities, their wording, demo signals.
- **About** → founding story, team size, funding, mission, HQ.
- **Customers / case studies** → named logos, industries, outcome themes.
- **Integrations** → count, key integrations, categories.
- **Changelog / what's new** → release velocity, recent focus, product direction.
- **Blog index** → post frequency, content types, topic focus.
Find these by fetching the homepage and following its navigation links, or try `/pricing`, `/features`, `/about`, `/customers`, `/integrations`, `/blog`, `/changelog`. Also try `sitemap.xml` for the page list. JS-only pages may come back empty — ask the client for a screenshot or the text.
- **Reviews** (high value): public G2, Capterra, TrustRadius, Product Hunt pages — often blocked or JS-rendered; if so, ask the client to paste the rating, review count and a few representative quotes. Extract praise themes, complaint themes, 3–5 quotes.

## Quantitative data the agent cannot pull
Domain authority, backlinks, referring domains, organic traffic estimates, ranked keywords, traffic value, keyword overlap and competitor discovery come from paid SEO tools. Ask the client to export from Ahrefs, Semrush or a DataForSEO-based tool and paste/send the numbers:
- Backlinks summary: domain rank, total backlinks, referring domains, spam score; top referring domains.
- Organic overview: keyword count, estimated monthly traffic, traffic value; keywords in top 3 / 10 / 100.
- Ranked keywords with positions, volume and ranking URL (sort by traffic for their money keywords).
- Closest organic competitors by keyword overlap (often reveals competitors nobody listed).
- Keyword intersection between the client's domain and each competitor.
- Highest-traffic pages.
Mark any metric that wasn't supplied as "no data" rather than estimating.

## Storage
There is no filesystem. Persist findings with `memory_write`: one note per competitor titled "Competitor profile — [name] ([date])" plus a landscape summary note; keep the raw quotes and numbers inside the note so a later run can diff them. Re-read with `memory_search` before re-profiling and record what changed. Deliver the profile to the client in chat, or as a file via `deliver_file` (MD) / `document_render` (DOCX/PDF) for sharing.

## Process
1. Read the competitor's key pages (`web_fetch`), extracting the fields above and keeping exact quotes for headlines and pricing.
2. Collect review and SEO data from the client.
3. **Synthesize** — cross-check claims against the evidence (a "10,000 customers" claim against their traffic and backlink profile), then fill the profile template.
4. Repeat per competitor, using identical metrics so profiles compare.
5. Build the landscape summary last.

## Profile structure
`# [Competitor] — Competitor Profile` with URL, generated date, depth, then:
- **At a glance** — tagline, founded, HQ, team size, funding, domain rank, est. organic traffic, referring domains, organic keywords.
- **Positioning & messaging** — primary value proposition (exact headline + subheadline), target audience, positioning angle (simplicity-first / enterprise-grade / all-in-one), key messaging themes with source page.
- **Product & features** — core capabilities, notable differentiators, integrations (count + top 5–10), product direction signals.
- **Pricing** — tier table (tier / price / key inclusions), billing and annual discount, free trial, pricing quirks (per-seat, usage-based, hidden costs).
- **Customers & social proof** — named customers, industries, case-study themes, review ratings with counts.
- **SEO & content strategy** — organic traffic, top-10 keyword count, traffic value; top organic pages with keyword and traffic; blog frequency, content types, focus areas; referring domains, top referring sites, link trend.
- **Strengths & weaknesses** — each with its evidence source.
- **Competitive implications for the client** — where they are stronger, where the client is stronger, opportunities, threats.
- **Raw data sources** — what was read or supplied and when.
Templates (quick scan, comparison table, positioning map, SWOT, change log): `skill_read("competitor-profiling", "references/templates.md")`.

## Landscape summary
1. One-paragraph overview of the field. 2. Side-by-side comparison table of key metrics. 3. Positioning map on the two most relevant axes. 4. Three to five strategic takeaways. 5. Gaps and opportunities where the market is underserved.

## Quick scan vs deep profile
**Quick scan**: homepage + pricing page; whatever domain/keyword numbers the client already has; skip reviews and backlink detail; abbreviated profile. **Deep profile**: all key pages + reviews; full SEO data; content strategy analysis; full template. Default to quick scan unless asked otherwise or there are three or fewer competitors.

## Multiple competitors
Use identical metrics for all; do one competitor end-to-end before the next (each page is a separate fetch); build the summary last; with 10+ competitors suggest the top 5 by market similarity first.

## Updating
Check pricing pages first (most volatile), re-pull SEO metrics, scan the changelog, update the generated date, and append a **Change Log** table noting what changed and how it was seen.

Related: customer-research, content-strategy, seo-audit, pricing, product-marketing.
