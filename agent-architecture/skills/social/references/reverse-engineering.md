# Reverse engineering what performs

Analyze top content in the niche instead of guessing.

## 1. Identify creators
10–20 accounts with high engagement: posting 3+ times/week, high engagement rate relative to followers, audience overlap with the ICP, mix of established and rising.
Find them: search industry keywords on LinkedIn and check "people also viewed"; see who the target audience follows and replies to; audience tools (SparkToro and similar, run by the client); creators featured in industry newsletters. Ask the client for {{competitors.social_accounts}} and reference accounts they admire.

## 2. Collect posts
Aim for a few hundred posts. The agent cannot scrape: ask the client to export from their analytics or scraping tool, paste batches of posts, or send public post links for `web_fetch`. A spreadsheet of 100–200 posts is already enough to see patterns.
Fields: post text, engagement (likes, comments, shares, saves), format (text, carousel, video, image), day/time, first line (hook), CTA, topic.

## 3. Analyze
Quantitative: rank by engagement rate; isolate the top 10%; format patterns (do carousels win?); timing patterns; topic performance.
Qualitative: which hooks do top posts use; typical length; emotional triggers; repeated formats; consistently winning topics.
Answer: average length of top posts; hook types dominating the top 10%; CTAs that drive comments; topics that get saved and shared.

## 4. Codify the playbook
Hook patterns, e.g.
```
Pattern: "I [unexpected action] and [surprising result]"
Example: "I stopped posting daily and my engagement doubled"
Why: curiosity gap + contrarian

Pattern: "[Specific number] [things] that [outcome]:"
Example: "7 pricing mistakes that cost me $50K:"
Why: specificity + loss aversion
```
Format patterns: carousel = hook slide → problem → solution steps → CTA; thread = hook → promise → deliver → recap → CTA; story post = hook → setup → conflict → resolution → lesson.
CTA patterns: "What would you add?" · "Agree or disagree?" · "Tag someone who needs this" · "Save this for later".

## 5. Layer the client's voice
**Smart friend who figured something out**: write like texting advice to a friend; share discoveries, not lectures; "I found that…" rather than "You should…".
**Specific over vague**: "$47,329" not "good revenue"; "47 days" not "a while"; "2,847 people" not "a lot of people" — using the client's real numbers only.
**Short. Breathe. Land.**: one idea per sentence, generous line breaks, important points stand alone, rhythm of short-short-longer.
```
Weak: "I spent three years building my business the wrong way before I finally realized the key was focusing on fewer things and doing them exceptionally well."
Strong: "I built wrong for 3 years.\n\nThen I figured it out.\n\nFocus on less.\nDo it exceptionally well.\n\nEverything changed."
```
**Write from emotion**: start with the feeling, use concrete emotional words (frustrated, terrified, obsessed), be vulnerable where it's genuine, connect feeling to lesson.

## 6. Convert attention
Soft: newsletter signup in bio/comments, free resource in a follow-up comment, DM trigger ("comment {{brand.cta_keyword}} and I'll send it"), optimized profile with a clear CTA. Direct: link in comments (not the LinkedIn post body), contextual product mentions inside valuable content, case-study posts, occasional "DM me if you want help".

## Formula
Find what already works → extract patterns → layer authentic voice → test and iterate on your own data.

## Checklist
10–20 creators identified · enough posts collected · ranked by engagement rate · top 10 hook patterns documented · top 5 format patterns · top 5 CTA patterns · voice guidelines (specificity, brevity, emotion) · template library built · tracking in place for own performance.
