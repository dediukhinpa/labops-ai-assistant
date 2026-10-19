# Social listening and engagement triage

Goal: a short scored list ("your top 10 posts to comment on today"), not an endless feed. Use this when the aim is commenting and relationships; use the rest of the social skill for creating.

Typical asks: "top 10 posts to comment on today" · "who is complaining about [competitor] right now?" · "find people asking for a tool like ours" · "posts from our 20 target accounts in the last 24h" · "what's the conversation around [topic] this week?"

## Daily loop (≈20 min)
1. **Pull** new posts from the defined sources.
2. **Filter** — drop >24h old, low signal, off-topic.
3. **Score** with the rubric; keep the top 10.
4. **Draft** a comment per post, matched to its tier.
5. **Client posts** after review (never auto-post).
6. **Log** what was commented on and what got replies (`memory_write`) — that log is the engagement dataset.

Output format:
```
TOP 10 POSTS — [date]
1. [Score 9/10] @author — LinkedIn — 2h ago
   "We just rolled out X and the team is loving it…"
   Why: ICP fit (B2B SaaS, 50–200 employees), buying-intent signal
   Suggested comment: [draft]
   Link: https://…
```

## Scoring rubric (1–10 each, weighted, summed)
| Dimension | Measures | Weight |
|---|---|---|
| ICP fit | Is the author a target customer or influencer? | 2x |
| Intent signal | Problem, question or shopping behavior? | 2x |
| Reach potential | Is the post gaining traction? | 1x |
| Comment opportunity | Can you say something genuinely useful? | 2x |
| Recency | Posted in the last 1–4h (early comments win) | 1x |

High-value intent: "looking for a tool that does X" · "why is [category] so painful?" · "we just switched from [competitor] because…" · "anyone use [competitor] — worth it?" · a complaint about a known competitor.
Drop when: author is neither ICP nor influencer; post >24h with 50+ comments (yours buries); generic motivational/AI-slop; self-promo thread where comments get no reach; nothing to add beyond "Great post!".

## Comment tiers
**Tier 1 — relationship builder** (target accounts, ICP, high intent): specific insight or counter-example, own experience with numbers/outcomes, a thoughtful follow-up question. 2–4 sentences, no link.
**Tier 2 — visibility play** (high-reach, adjacent topic): one sharp insight — "Agreed — and the part most miss is [X]". 1–2 sentences.
**Tier 3 — light touch**: a specific reaction to a specific line. 1 sentence.
Never: "Great post!", emoji-only, "+1", "This is gold 🔥".

## Sources the agent can read
Public JSON and RSS endpoints work with `web_fetch` (no login, no keys). Replace KEYWORD with real terms; keep multi-word phrases quoted.
- **Reddit new posts**: `https://www.reddit.com/r/SUBREDDIT/new.json?limit=25`
- **Reddit keyword search (last day)**: `https://www.reddit.com/search.json?q=KEYWORD&sort=new&t=day&limit=25`
- **Hacker News stories**: `https://hn.algolia.com/api/v1/search_by_date?query=KEYWORD&tags=story`
- **Hacker News comments**: same URL with `&tags=comment`
- **Bluesky search**: `https://public.api.bsky.app/xrpc/app.bsky.feed.searchPosts?q=KEYWORD&limit=25&sort=latest`
- **YouTube channel feed**: `https://www.youtube.com/feeds/videos.xml?channel_id=CHANNEL_ID`
- **Blog/newsletter RSS**: the site's `/feed/` URL.
Useful keywords: "alternative to [competitor]", "looking for a [category] tool", "recommend a [category]", "switching from [competitor]", "frustrated with [competitor]", brand name and misspellings, competitor names.

**LinkedIn, X, Instagram, TikTok** have no usable public endpoints — the agent cannot read them. Ask the client to paste post text or links from: `linkedin.com/in/HANDLE/recent-activity/all/` (one person's posts without the algorithm), `linkedin.com/feed/hashtag/TOPIC/`, `x.com/search?q=QUERY&f=live` (chronological), `x.com/i/lists/LIST_ID` (a private list of target accounts — far cleaner than the feed). Paid helpers they may already use: Sales Navigator saved searches, X Pro columns, scheduling/engagement tools. Instagram and TikTok: native saved searches and hashtag follows only.

## Per-platform notes
**LinkedIn** — first-hour comments matter most; prioritize posts <2h old from target accounts; comments of 5+ words beat reactions; replying to other commenters exposes you to their network; tag the author only when it adds context.
**X** — reply within 30 min for max reach on big accounts; quote-tweet when adding substantial value; a threaded reply signals effort; don't pile on dunks.
**Reddit** — read subreddit rules (many ban self-promotion); earn karma before linking to anything you own; long specific answers win; "help me decide" threads are gold; never lead with the product.
**Hacker News** — high quality bar; founders commenting about their own product are welcome if transparent; old threads about the category are dormant gold mines.
**Bluesky** — smaller volume, high engagement-to-follower ratio, active tech/indie communities.

## Source list to maintain
Keep it in memory (`memory_write`, one note "Listening sources", refreshed as it changes) and re-read with `memory_search`:
- Brand/product and category; the goal of listening.
- ICP for scoring: role, company stage, industry, fit signals ({{audience.icp}}).
- Target accounts (20–50 max) per platform, plus RSS feeds and YouTube channel IDs.
- Intent keywords: high-intent, problem signals, brand mentions incl. misspellings, competitor names ({{competitors.list}}, {{competitors.social_accounts}}).
- Subreddits and communities to pull daily.
- Saved-search URLs the client checks manually.
- **Do not engage**: bad-faith accounts, brands that would screenshot, off-limits topics ({{content.publishing_rules}}).
Default lookback 24h. Always output drafts for approval — the client posts.

## Common workflows
- **Top 10 today**: pull target-account feeds + relevant subreddits + HN last 24h → score → output 10 with drafted comments.
- **Complaints about a competitor**: Reddit search for the name sorted new, HN comment search, Bluesky search → score by switching language ("moving from", "alternatives to", "frustrated with").
- **Brand mentions this week**: Reddit + HN (stories and comments) + Bluesky for brand name and handle → output reply needed (y/n), tone, suggested response.
- **Missed target-account posts**: fetch each source's recent items, filter to 24h, sort by score.
