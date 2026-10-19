---
name: social
title: Social Media Content
description: Use when creating, repurposing or planning social content for LinkedIn, X, Instagram, TikTok or Facebook, writing short-form video scripts, or doing social listening and engagement triage.
category: marketing
requiresTools: [web_fetch, memory_write]
status: ready
origin: dot-claude/skills/social
---

# Social Content

Create content that builds an audience, drives engagement and serves business goals.

## Before creating
Use known context: {{brand.tone_of_voice}}, {{audience.icp}}, {{channels.list}}, {{content.pillars}}, {{content.publishing_rules}}, {{products.primary_offer}}. Ask for gaps:
1. **Goals** — awareness, leads, traffic, community; desired action; personal brand, company brand or both.
2. **Audience** — who, which platforms, what they engage with.
3. **Voice** — tone, topics to avoid, terminology and style rules.
4. **Resources** — weekly time, existing content to repurpose, can they film video.

The agent writes and plans; the client (or their scheduler) publishes. Deliver ready-to-post text with platform-correct formatting, or a calendar file via `deliver_file`.

## Platform quick reference
| Platform | Best for | Frequency | Key format |
|---|---|---|---|
| LinkedIn | B2B, thought leadership | 3–5x/week | Carousels, stories |
| X | Tech, real-time, community | 3–10x/day | Threads, takes |
| Instagram | Visual brands, lifestyle | 1–2 posts + Stories daily | Reels, carousels |
| TikTok | Awareness, younger audience | 1–4x/day | Short video |
| Facebook | Communities, local business | 1–2x/day | Groups, native video |
Per-platform strategy, algorithm notes, character/hashtag limits: `skill_read("social", "references/platforms.md")`. Adapt to the networks actually used in {{audience.geo}} — where local messengers or regional networks dominate, the same pillars and hooks apply with local formats.

## Content pillars
3–5 pillars aligned with expertise and audience interest. Example split for a founder: industry insights 30%, behind the scenes 25%, educational 25%, personal 15%, promotional 5%.
Per pillar ask: what unique perspective exists? what does the audience ask? what performed before? what can be produced consistently? what serves business goals?

## Hooks
First line decides everything.
- **Curiosity**: "I was wrong about [belief]." · "The real reason [outcome] happens isn't what you think." · "[Result] — and it took only [time]."
- **Story**: "Last week, [unexpected thing] happened." · "I almost [failure]." · "3 years ago I [past]. Today [present]."
- **Value**: "How to [outcome] (without [pain]):" · "[N] [things] that [outcome]:" · "Stop [mistake]. Do this instead:"
- **Contrarian**: "Unpopular opinion: [statement]" · "[Common advice] is wrong. Here's why:" · "I stopped [practice] and [result]."
- **Social proof**: "We [result] in [time]. Here's the story:" — only with real numbers.
Post templates per platform + full hook library: `skill_read("social", "references/templates-and-hooks.md")`.

## Repurposing
One pillar piece → many posts. Extract 5–10 **content atoms** (self-contained moments), adapt per platform, write standalone captions (each post works without context), spread over the week, reshare evergreen every 3–6 months.

| Atom | Look for | Best platform |
|---|---|---|
| Quotable moment | Bold claim or memorable line (15–60 s) | X, LinkedIn, TikTok |
| Story arc | Setup → conflict → resolution (60–90 s) | Reels, TikTok, Shorts |
| Tactical tip | Specific how-to or framework (30–60 s) | LinkedIn, Shorts |
| Controversial take | Debate starter | X, LinkedIn |
| Data callout | Surprising number | LinkedIn carousel, X |
| Behind the scenes | Unpolished authenticity | Stories, TikTok |

- **Blog post** → LinkedIn insight (link in comments), LinkedIn carousel, X thread, Instagram carousel, Reel summary.
- **Podcast/video** → transcript (client's transcription tool, or `youtube_transcript` for a link) → mark 5–10 best moments → clips → standalone captions → subtitles → schedule over 1–2 weeks. Per episode: 3–5 clips, 1–2 LinkedIn posts, 1 X thread, 1 carousel, 1 newsletter/blog section.
- **Webinar** → carousel from key slides, Q&A thread, quote graphics, poll-result posts, clips.
- **Newsletter** → LinkedIn post from the main insight, X thread of curated links, stat graphic, hot take.

## Calendar and batching
Weekly grid (example): Mon insight / thread / carousel · Tue behind-scenes / engagement / Story · Wed educational / tips / Reel · Thu story post / thread / educational · Fri hot take / engagement / Story.
Batch in 2–3 hours weekly: review pillar topics → 5 LinkedIn posts → 3 threads + daily posts → carousel + Reel ideas → schedule → leave room for real-time posts. Offer `reminder_create` for the batching slot.

## Engagement (30 min/day)
Reply to all comments on own posts (5 min) → comment on 5–10 posts from target accounts (15 min) → share with added insight (5 min) → 2–3 DMs to new connections (5 min).
Quality comments add new insight, a related experience, a thoughtful question or respectful disagreement — never "Great post!". Relationships: pick 20–50 accounts, engage consistently, share their work with credit, then collaborate.
Choosing *which* posts to comment on (daily top-10, brand and competitor monitoring, intent signals, scoring rubric, public sources the agent can fetch): `skill_read("social", "references/listening.md")`.

## Analytics
Awareness: impressions, reach, follower growth rate. Engagement: engagement rate, comments (worth more than likes), shares, saves. Conversion: link clicks, profile visits, DMs, attributed leads.
Weekly review: top 3 posts (why?), bottom 3 (lesson), follower trend, engagement trend, best times from data. The client exports the numbers; the agent analyzes and adjusts the plan.
If engagement is low: new hooks, different times, other formats, more engagement with others. If reach declines: no external links in the post body, higher frequency, more comment activity, test video/visuals.

## Situational ideas
Starting out: document the journey, share what you're learning, curate and comment on industry content, engage with established accounts. Stuck: repurpose past winners, ask the audience, comment on industry news, share a failure or lesson.

## Scheduling
Schedule core posts, threads, carousels, evergreen. Post live for real-time commentary, reactions to news, engagement. Keep 1–2 weeks queued, review weekly for relevance, leave gaps, adjust timing from data.

## Reverse engineering what works
Find 10–20 high-engagement creators → collect their posts → rank by engagement → codify hooks, formats, CTAs → layer the client's authentic voice → convert attention to action. Full framework, voice principles and checklist: `skill_read("social", "references/reverse-engineering.md")`.

## Short-form video (TikTok, Reels, Shorts)
Specs: TikTok 15–60 s, trending sounds, raw feel · Reels 15–30 s, polished, rewards saves/shares · Shorts 30–60 s, searchable titles. All 9:16.
**3-second rule**: visual hook + verbal hook + text overlay all land in the first second.
Structures:
- Problem-solution (15–30 s): 0–3 s problem · 3–10 s why it matters · 10–25 s solution · 25–30 s CTA.
- List (30–60 s): hook "X things that [outcome]" · one item every 5–8 s · CTA.
- Tutorial (30–60 s): show the result first · "here's how" · quick steps · result + CTA.
Captions: max 2 lines on screen, 3–5 words per line, bold sans-serif with outline, key words highlighted, timed to speech (captions often lift watch time; check the client's own analytics).
Mistakes: slow hooks, no text overlay, bad audio, too long, no CTA, ignoring comments in the first hour.
The agent writes the script, shot list, overlay text and caption; the client films/edits (CapCut, Descript, Captions.ai) — or `video_render` from a composition if available, `image_generate` for frames and covers. Hook library, scripting template, audio and posting strategy: `skill_read("social", "references/short-form-video.md")`.

## Output
Ready-to-post text per platform (with hook, body, CTA, hashtags within platform limits), a weekly calendar table, and a short "why this works" note. Save winning formats via `memory_write`.

Related: content-strategy, copywriting, reels, twitter, threads-content, carousel-generator, humanizer, content-pipeline.
