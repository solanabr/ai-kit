---
name: hackathon
description: Prepare a winning hackathon submission. Use when the user says "hackathon submission", "submit to hackathon", "demo script", "demo video", "which track should I enter", "Colosseum", "help me win the hackathon", or asks about hackathon grants and Superteam Earn.
user-invocable: true
---

<!-- Adapted from sendaifun/solana-new (submit-to-hackathon, apply-grant), MIT © 2026 SendAI and Superteam. Telemetry removed. -->

# Hackathon Submission

Track choice → scannable description → <3-min demo script → checklist. Optimize for a judge who has 90 seconds, not a reader who has 10 minutes.

## Context handoff

At start, read `.claude/context/idea.md` and `.claude/context/build.md` if present — pull the pitch, wedge, and what actually works from them instead of asking again.

## Workflow

### 1. Pick the least-crowded track

Winning a thin track beats placing in a fat one. Per candidate track: estimate entry volume, fit with what's actually built, and judge appetite (sponsor tracks often have the fewest serious entries).

- Winner patterns + track history: [hackathon-winners.md](../ext/solana-new/skills/data/colosseum/hackathon-winners.md) — every Colosseum grand champion and track winner, with what they built (install first: `bash .claude/bin/skills.sh add solana-new`)
- Live crowdedness check: [ext/colosseum](../ext/colosseum/skills/colosseum-copilot/SKILL.md) — query 5,400+ past submissions for cluster density and gaps (requires `COLOSSEUM_COPILOT_PAT`; install first: `bash .claude/bin/skills.sh add colosseum`)

### 2. Write a scannable description

**Judges read 100+ submissions.** Yours gets one skim deciding whether it gets a real read:

- Tagline: what it does, one sentence, no jargon
- First paragraph: problem + who has it
- Bold the one thing that's novel
- "What works today" list — demo-able claims only, never roadmap dressed as product
- Why Solana (one concrete reason: speed, fees, composability with X)

Full structure (200–500 words, paragraph-by-paragraph): [hackathon-submission-guide.md](../ext/solana-new/skills/launch/submit-to-hackathon/references/hackathon-submission-guide.md). Score the draft against [judging-criteria.md](../ext/solana-new/skills/launch/submit-to-hackathon/references/judging-criteria.md) before submitting (install first: `bash .claude/bin/skills.sh add solana-new`).

### 3. Demo script (<3 minutes)

| Time | Beat |
|------|------|
| 0:00–0:20 | Problem — one user, one pain, no market-size slides |
| 0:20–0:40 | What you built, one sentence + UI first appears |
| 0:40–2:10 | The demo — one happy path, real data, on-chain proof (explorer tx) |
| 2:10–2:40 | The novel part — the thing competitors don't have |
| 2:40–3:00 | Traction/team one-liner + the ask |

Shot-by-shot template and recording tips: [demo-video-script.md](../ext/solana-new/skills/launch/submit-to-hackathon/references/demo-video-script.md) (install first: `bash .claude/bin/skills.sh add solana-new`). Rule: if the demo can fail live, record it.

### 4. Submission checklist

- [ ] Track chosen by crowdedness, not vanity
- [ ] Tagline passes the "non-crypto friend" test
- [ ] Description scannable in 90 seconds (bold claims, short paragraphs)
- [ ] Demo video <3 min, real transaction shown
- [ ] Repo public, README quickstart actually works from clone
- [ ] Deployed link (devnet OK) + program ID listed
- [ ] Team and contact info complete
- [ ] Pitch deck attached if track requires one — use [pitch-deck](../pitch-deck/SKILL.md)

## After the hackathon: grants

Losing the track doesn't mean losing the funding. Same artifacts (description, demo, deck) feed grant applications:

- **Superteam Earn** (earn.superteam.fun) — bounties + grants up to ~$10k USDC equivalent, fast cycles, regional Superteams
- **Solana Foundation grants** — milestone-based, public-good angle; reuse the scannable description with an ecosystem-benefit paragraph
- Grant-shaped ideas dataset: [superteam-ideas.json](../ext/solana-new/skills/data/ideas/superteam-ideas.json) (install first: `bash .claude/bin/skills.sh add solana-new`)
