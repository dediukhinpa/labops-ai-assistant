# Customer research — source guides

## Reddit
Find where the ICP spends time (not where the product is discussed): `site:reddit.com "[job title] tools"`, `site:reddit.com "[problem category] software"`, subreddit search, subreddits mentioned in competitor reviews.
Examples: B2B — r/sales, r/marketing, r/entrepreneur, r/startups, r/smallbusiness; dev — r/programming, r/devops, r/webdev; data — r/analytics, r/dataengineering, r/BusinessIntelligence; marketing — r/PPC, r/SEO, r/emailmarketing, r/content_marketing; HR — r/recruiting, r/humanresources; finance/ops — r/accounting, r/projectmanagement.
Operators:
```
site:reddit.com/r/[subreddit] "[keyword]"
site:reddit.com "[problem]" "recommend" OR "suggestion" OR "alternative"
site:reddit.com "[competitor]" "vs" OR "alternative" OR "switched"
```
High-signal posts: "What tools do you use for X?" (alternatives, vocabulary); "Frustrated with [competitor]" (pain, switching triggers); "How do you handle X?" (workflows, workarounds); "Is [category] worth it?" (objections, criteria); competitor complaint threads.
Extract: the exact problem, top-voted solutions, complaints about existing tools, specific wording, consensus vs controversy. Archive search: Pullpush.io.

## Review sites (G2, Capterra, Trustpilot, AppSumo)
Own reviews, reading order: 3★ (most honest) → 1★ (failure modes; split product vs support/onboarding) → 5★ (love language, proof points) → 4★ ("the only thing I wish…").
Extract: what they use it for (JTBD), hardest/most frustrating, comparisons ("coming from X"), role/industry signals.
Competitors: 4★ reviews are gold. G2 fields: "like best" = their strengths (battlecard); "dislike" = their weaknesses (your opening); "problems solving" = JTBD. Trustpilot skews B2C; AppSumo useful for SMB/prosumer.
Template per competitor: JTBD | top praise | top complaint | switching context | unmet need ("I wish it could…").

## Indie Hackers, Product Hunt
IH (founders/SMB): "Ask IH" posts, milestone posts (stacks and pains), launch comments. `site:indiehackers.com "[problem]"`.
Product Hunt discussion tabs: questions = pre-sales objections; comments = early reactions; "Alternatives to X" collections = the competitive set as users see it.

## Hacker News
Technical/developer ICP; builders and skeptics. `site:news.ycombinator.com "[competitor or category]"`, "Ask HN: best tools for X", skeptical comments on competitors' "Show HN". Expect critiques of architecture, business model and subscription pricing — first-principles objections.

## LinkedIn
Posts: "[role] at [company size]" + problem; "We used to [old way], now [new way]" stories; recommendation requests (active buyers in comments).
Job postings = admitted pain: required vs nice-to-have tools (stack), metrics named, where time goes (JTBD). `site:linkedin.com/jobs "[role]" "[tool or category]"`.

## YouTube
Tutorials for the problem, "Best tools for X [year]" roundups, competitor demos. Comments: "Does this work for [use case]?" (edge cases), "I tried this but…" (failure points), "What about [competitor]?" (active evaluation), timestamped questions (confusion points).

## X / Twitter
```
"[competitor]" -filter:replies min_faves:10
"[problem keyword]" "anyone know" OR "recommend" OR "alternative"
"[category] is broken" OR "frustrated with [category]"
```
Real-time competitor complaints, practitioners' stacks, influencers the ICP follows.

## Blogs, forums, niche communities
`"[competitor 1] vs [competitor 2]"`, `"best [category] software [year]"` — read comments (active evaluators). Slack communities ("[industry] Slack community"), Discord, Facebook Groups (SMB, e-commerce, agencies, coaches), Circle/Mighty Networks paid communities.

## B2C / consumer
- App stores: 1–2★ (failure, frustration) → 3★ (tradeoffs) → 5★ (love language). Extract: job hired for ("I use this to…"), moment it stopped working, what they switched from, emotional words. Sort Most Recent, then Most Critical.
- Amazon: 3★ first. Trustpilot, Sitejabber for consumer SaaS.
- Vertical subreddits (fitness: r/running, r/loseit; finance: r/personalfinance, r/ynab; productivity: r/productivity, r/Notion, r/ObsidianMD; travel: r/solotravel, r/digitalnomad; parenting: r/Parenting). `site:reddit.com/r/[community] "[app OR problem]"`.
- TikTok/Instagram: "[product] review", "is [product] worth it"; top 5–10 videos, read all comments; Instagram tagged posts from real users. Extract questions (unmet needs), "does this work for…", "I switched from X", complaints on price/features/broken promises.
- YouTube: "honest review", "after 6 months", comparisons, unboxing/setup.
- Facebook Groups, Discord, Nextdoor (local services), Quora (decision anxiety).

## SparkToro (audience intelligence)
Aggregated clickstream/search/social: what the audience reads, watches, listens to, follows, searches. Use it first to learn *where* the ICP spends time; then mine those places manually for language and the *why*.
Queries: people who follow @competitor; who visit competitor.com; who talk about [topic]; whose bio contains [job title]; who visit your domain (compare to competitors).
Outputs → use: top websites (partnerships, guest posts), podcasts (guesting, sponsorship), YouTube channels (video strategy, ads), subreddits (community, Reddit ads), search keywords (SEO), AI prompt topics, followed accounts (influencers), demographics (personas).
Confidence: high for behavior, medium for demographics, no substitute for qualitative. Limits: free tier 5 reports/month, shallow; no public API; English/US skew. The client runs it and shares results.

## Organizing
Tags: #pain #trigger #outcome #language #alternative #objection #competitor. Running table: Source | Date | Quote | Tags | Notes. After 20–30 entries patterns emerge; quotes echoed in unrelated sources = highest confidence.

## Source weighting
| Source | Signal | Bias |
|---|---|---|
| Interviews (unprompted) | Very high | Small sample, engaged customers |
| Win/loss | High | Recent memory, rationalization |
| App store / G2 reviews | High | Strong opinions |
| Reddit / communities | Medium-high | Technical, skeptical, vocal minority |
| Support tickets | Medium | Problems only |
| Survey open-ended | Medium | Primed by question |
| Survey multiple choice | Low-medium | Artifacts of options |
| NPS verbatims | Medium | Tied to score/moment |
| YouTube/TikTok comments | Medium | Engaged viewers, performance |
| SparkToro | Medium-high | "What" not "why" |
| Job postings | Low-medium | Aspirational |

Confidence labels in practice:
```
[HIGH] Customers feel overwhelmed by manual reporting — 12 of 20 interviews, 4 Reddit threads, #1 complaint in 3★ G2 reviews; consistent across SMB and mid-market.
[MEDIUM] Customers compare us to spreadsheets more than to competitors — 6 interviews, 3 threads; not yet in reviews.
[LOW] Enterprise buyers may have procurement concerns — 2 interviewees at 500+ companies; needs more signal.
```
Recency: <12 months primary; 12–24 caution; 2+ years baseline only. Themes consistent across old and new data are durable.
