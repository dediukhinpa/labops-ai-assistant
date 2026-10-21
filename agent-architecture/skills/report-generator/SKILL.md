---
name: report-generator
description: Use when user has structured data (numbers, tables, metrics) and needs a formatted report. Applies to weekly/monthly reports, sales summaries, or operational digests. Do NOT use for meeting transcripts -- use meeting-summarizer for that.
---

# Report Generator

## Overview

Takes raw data and a reporting goal, produces a formatted report ready to share or present.

## When to Use

- User pastes numbers/table and says "make a report"
- User needs weekly/monthly operational summary
- User wants to convert spreadsheet data into a readable format
- Preparing report for a client, team, or manager

## Core Pattern

### Step 1 — Clarify report type

Ask if not clear:
- Who reads this? (team, client, management, self)
- What decision does it support?
- Format needed: Telegram message, email, document, presentation slide?

### Step 2 — Identify key metrics

From the data, extract:
- Primary number (the main result)
- Comparison (vs last period, vs target)
- Top 3 contributors or drivers
- 1-2 risks or anomalies

### Step 3 — Format by audience

**For team/operational (short):**
```
[Period] Report — [Area]
✓ [Primary metric]: X (target: Y, Δ +Z%)
Top: [1-2 drivers]
Risk: [if any]
Next: [one focus]
```

**For management/client (full):**
```markdown
## [Report Title] — [Period]

### Summary
[2-3 sentences: what happened, main result]

### Key Metrics
| Metric | Actual | Target | vs Last Period |
|--------|--------|--------|---------------|

### Highlights
- [Positive 1]
- [Positive 2]

### Risks / Issues
- [Issue] — action: [who, what]

### Next period focus
[1-2 priorities]
```

### Step 4 — Add context

Always include:
- Period covered
- Data source (if known)
- Who prepared (if relevant)

## Handling Missing Data

- Missing comparison data → show absolute value, note "no comparison available"
- Incomplete data → show what's available, flag gaps explicitly
- User says "make it look good" → ask what outcome they want to highlight first

## Common Mistakes

- Don't invent numbers or fill gaps with estimates without labeling them
- Don't hide negative results — show them with context
- Don't over-format short reports — a Telegram message doesn't need a table
