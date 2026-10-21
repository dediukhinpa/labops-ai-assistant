---
name: meeting-summarizer
description: Use when user has a meeting transcript, notes, or recording summary and needs a structured output: protocol, action items, owners, and deadlines.
---

# Meeting Summarizer

## Overview

Converts raw meeting transcript or notes into a structured protocol with tasks, owners, and deadlines.

## When to Use

- User pastes meeting transcript or rough notes
- User asks to "summarize the meeting" or "make a protocol"
- User needs to extract action items from a conversation
- User wants to share meeting outcomes with team

## Core Pattern

### Step 1 — Identify meeting type

- Operational (standup, weekly sync) → short format
- Strategic / decision → full format with decisions section
- Client / external → add participants section, formal tone

### Step 2 — Extract structure

Scan transcript for:
- Decisions made (explicit: "we decided...", implicit: agreement)
- Action items (who does what by when)
- Open questions (no resolution yet)
- Key facts / numbers mentioned

### Step 3 — Format output

```markdown
## Meeting Protocol

**Date:** [date]
**Participants:** [names/roles]
**Topic:** [one line]

### Decisions
- [Decision 1]
- [Decision 2]

### Action Items
| # | Task | Owner | Deadline |
|---|------|-------|----------|
| 1 | ... | ... | ... |

### Open Questions
- [Question] — responsible: [name]

### Next meeting
[date/trigger if mentioned]
```

## Handling Missing Info

- No date in transcript → mark as [date not specified]
- Owner unclear → mark as [owner TBD], flag for user
- Deadline not mentioned → mark as [no deadline], ask user if needed
- Multiple tasks for one person → group them

## Output Format

Full protocol in markdown. If user needs plain text (for Telegram/email), strip markdown on request.

## Common Mistakes

- Don't fabricate deadlines — only extract what was said
- Don't merge separate decisions into one
- Don't omit open questions — they're as important as decisions
