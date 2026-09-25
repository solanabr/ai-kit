---
name: pitch-deck
description: Build a pitch deck for a crypto project. Use when the user says "pitch deck", "demo day", "investor presentation", "grant application slides", "accelerator application", "help me pitch", or needs slides for a hackathon final.
user-invocable: true
---

<!-- Adapted from sendaifun/solana-new (create-pitch-deck), MIT © 2026 SendAI and Superteam. Telemetry removed. -->

# Pitch Deck

Interview → detect audience → pick narrative → build slides with speaking notes → self-score → objection prep.

## Context handoff

At start, read `.claude/context/idea.md` and `.claude/context/build.md` if present — pre-fill problem, wedge, traction, and stack from them; only ask what's missing.

## Workflow

### 1. 12-question interview

Blunt, one at a time, skipping anything already answered by context files:

1. What does it do, in one sentence a non-crypto person understands?
2. Who exactly has the problem, and how painful is it (evidence)?
3. Why does this need a blockchain?
4. Why Solana specifically?
5. What works *today* (demo-able) vs. roadmap?
6. Traction numbers — users, volume, TVL, signups, waitlist?
7. Who is the team and what's the unfair edge?
8. Competitors and your moat?
9. Business model — who pays, when?
10. Who is the audience for this deck (judges, VCs, grant committee, accelerator)?
11. The ask — prize, check size, grant amount, admission?
12. Biggest weakness you're afraid they'll ask about?

### 2. Audience detection → slide set

Q10 decides the slide set — full breakdown in [investor-audience-guide.md](../ext/solana-new/skills/launch/create-pitch-deck/references/investor-audience-guide.md) (install first: `bash .claude/bin/skills.sh add solana-new`):

| Audience | Emphasis | Length |
|----------|----------|--------|
| Hackathon judges | working demo, technical novelty, why-Solana | 5–7 slides |
| VC | market size, traction slope, team, moat, ask | 10–12 |
| Grant committee | ecosystem benefit, public-good angle, milestones, budget | 8–10 |
| Accelerator | team velocity, learning rate, wedge → expansion path | 8–10 |

Slide-by-slide order per audience: [pitch-structure.md](../ext/solana-new/skills/launch/create-pitch-deck/references/pitch-structure.md) (install first: `bash .claude/bin/skills.sh add solana-new`).

### 3. Narrative framework

Pick one backbone and state why — PAS (obvious pain, hackathons), 6-Part Investor Arc (VC), BAB (before/after/bridge), Hero's Journey (founder-story-driven), Pixar (narrative momentum). Definitions, slide mappings, and crypto examples: [storytelling-frameworks.md](../ext/solana-new/skills/launch/create-pitch-deck/references/storytelling-frameworks.md) (install first: `bash .claude/bin/skills.sh add solana-new`).

### 4. Build slides + speaking notes

For each slide: headline (a claim, not a label), 3–5 supporting points, visual suggestion, and 30–60s speaking notes. Use:

- [slide-templates.md](../ext/solana-new/skills/launch/create-pitch-deck/references/slide-templates.md) — per-slide-type templates (install first: `bash .claude/bin/skills.sh add solana-new`)
- [deck-design-system.md](../ext/solana-new/skills/launch/create-pitch-deck/references/deck-design-system.md) — typography, layout, color rules (`bash .claude/bin/skills.sh add solana-new`)
- [crypto-pitch-examples.md](../ext/solana-new/skills/launch/create-pitch-deck/references/crypto-pitch-examples.md) — real decks that worked (`bash .claude/bin/skills.sh add solana-new`)
- [pitch-reference-sources.md](../ext/solana-new/skills/launch/create-pitch-deck/references/pitch-reference-sources.md) — primary sources (`bash .claude/bin/skills.sh add solana-new`)

### 5. Self-score vs audience rubric

Score the draft against the audience's actual criteria (clarity, credibility, demo strength, ask specificity) and against [crypto-pitch-mistakes.md](../ext/solana-new/skills/launch/create-pitch-deck/references/crypto-pitch-mistakes.md) (install first: `bash .claude/bin/skills.sh add solana-new`) — flag every mistake the deck still commits, fix, re-score. Don't present a deck you'd score below 8/10.

### 6. Objection-prep Q&A

From Q12 + the weakest scored dimension, draft the 8–10 hardest questions this audience will ask, each with a tight 30-second answer. Hostile-question drilling beats slide polish.

## Output

- Deck outline (markdown, one section per slide: headline / points / visual / speaking notes)
- Framework choice + one-line rationale
- Self-score with the fixes applied
- Objection Q&A sheet

Need an actual rendered deck file (.pptx)? Hand the outline to the pptx skill if available.
