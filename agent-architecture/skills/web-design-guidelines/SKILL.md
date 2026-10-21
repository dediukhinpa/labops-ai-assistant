---
name: web-design-guidelines
title: Web Interface Review
description: Use when asked to review UI code, audit a page's UX or accessibility, or check a site against web interface best practices.
category: design
requiresTools: [web_fetch]
status: ready
origin: dot-claude/skills/web-design-guidelines
---

# Web interface review

Review UI code against web interface guidelines and report findings terse and actionable.

## Input

You cannot read the client's files. Ask them to paste the component/page code (or upload it to the knowledge base — `knowledge_read`), or give you a public URL to fetch with `web_fetch`. If they paste code, ask them to keep the original line numbers or paste whole files so references are meaningful.

Optionally refresh the public Web Interface Guidelines with `web_fetch` on `https://raw.githubusercontent.com/vercel-labs/web-interface-guidelines/main/command.md` and apply the current rules. If the fetch fails or is unavailable, review against the checklist below.

## Output format

One finding per line, terse, worst first:

```
src/components/Modal.tsx:42 — focus is not trapped in the dialog; Tab reaches the page behind it
src/components/Modal.tsx:55 — Escape does not close the dialog
styles/buttons.css:18 — focus-visible outline removed with `outline: none` and no replacement
```

Then: a 3–5 line summary (what is systematically wrong), and the fix for each finding as a short code snippet if it is not obvious. Do not rewrite the whole file unless asked. Separate blocking problems (accessibility and interaction failures) from polish.

## Checklist

**Interaction**
- Every interactive element is reachable and operable by keyboard; tab order follows visual order; no positive `tabindex`.
- `:focus-visible` styling is present and visible against the background; focus is never removed without a replacement.
- Dialogs/menus: focus moves in, is trapped, returns to the trigger on close; Escape closes; background scroll locked; `aria-modal`/`role="dialog"` set.
- Hit targets ≥ 24 px (≥ 44 px on touch); no reliance on hover alone — touch users need an equivalent.
- Clicks are idempotent: buttons disable during submit; no double submission; destructive actions confirm or offer undo.
- Forms: real `<label>` per field (not placeholder-as-label), correct `type`/`inputmode`/`autocomplete`, errors tied with `aria-describedby`, validation on blur/submit not on every keystroke, Enter submits, the form survives a failed request with its values intact.
- Links are `<a href>` and buttons are `<button>`; never a div with an onClick.

**Structure and semantics**
- One `<h1>`; heading levels not skipped; landmarks (`header`/`nav`/`main`/`footer`) present.
- Lists as list elements, tables for tabular data with `<th scope>`; icon-only controls have `aria-label`.
- Images have meaningful `alt` (empty `alt=""` for decoration); `<html lang>` set; `<title>` describes the page.
- ARIA only where semantics are missing; no redundant or conflicting roles.

**Visual**
- Text contrast ≥ 4.5:1 (≥ 3:1 for large text and UI borders); state is never conveyed by color alone.
- Consistent spacing scale and type scale; optical alignment of adjacent elements; no 1-px jitter between similar cards.
- Layout holds at 320 px width and at 200% zoom; no horizontal page scroll; text wraps instead of truncating without a title.
- Dark mode (if present) defines its own background and contrast, not just inverted colors.
- Long text lines capped (~65–80 characters); table numbers right-aligned with consistent decimals; tabular figures for numeric columns.

**Feedback and state**
- Loading, empty, error and success states exist for anything asynchronous; skeletons match the final layout to avoid jumps.
- Optimistic updates roll back visibly on failure; errors say what happened and what to do next.
- Async status changes announced to assistive tech (`aria-live` region) when they are not focused.
- Nothing shifts layout after load (reserve space for images, ads, banners); `content-visibility`/fixed aspect ratios where relevant.

**Motion and performance**
- `prefers-reduced-motion: reduce` honored; no parallax or auto-playing motion without a way to stop it.
- Animate `transform`/`opacity` only; durations 150–300 ms for UI feedback; no animation on scroll-blocking paths.
- Images sized and lazy-loaded below the fold; fonts with `display: swap`; no layout-thrashing scroll handlers.

**Content**
- Sentence case, active voice, consistent vocabulary for the same action across the flow.
- Labels name what the user controls, not the system's implementation.
- Dates, currency and numbers localized; timezone stated when it matters (`{{profile.timezone}}`).

## Tone of the review

Report problems, not praise. Be specific about the rule broken and the user-visible consequence. If the code is good, say so in one line and list only the polish items.
