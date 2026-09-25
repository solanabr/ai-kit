---
name: idea-sprint
description: Find and validate what to build in crypto. Use when the user asks "what should I build", "validate this idea", "is this worth building", "find me a startup idea", "crypto idea", or wants blunt feedback on a project concept before writing code.
user-invocable: true
---

<!-- Adapted from sendaifun/solana-new (find-next-crypto-idea, validate-idea), MIT © 2026 SendAI and Superteam. Telemetry removed. -->

# Idea Sprint

Interview → necessity gate → 3 candidates → score → go/no-go. Output is a decision, not a brainstorm.

## Context handoff

- At start: read `.claude/context/idea.md` and `.claude/context/build.md` if present — resume from prior state instead of re-interviewing.
- On completion: write/update `.claude/context/idea.md` with the chosen idea, scores, validation evidence, and open risks. Downstream skills (pitch-deck, hackathon) read it.

## Workflow

### 1. Blunt interview

No flattery. Short, pointed questions, one at a time, until three things are explicit:

- **Edge** — what the founder knows/can do that most can't (domain, distribution, tech)
- **Constraint** — time, money, team, chain commitments
- **Wedge** — the niche entry point, not the end-state vision

Push back on vague answers. "DeFi for everyone" is not a wedge. Full question bank: [interview-framework.md](../ext/solana-new/skills/idea/find-next-crypto-idea/references/interview-framework.md) (install first: `bash .claude/bin/skills.sh add solana-new`).

### 2. Crypto-necessity gate

Kill question: **"What gets worse if I remove the blockchain?"** If the answer is vague, aesthetic, or marketing-driven — redirect the idea before scoring it. Pass criteria and redirect patterns: [crypto-necessity-test.md](../ext/solana-new/skills/idea/find-next-crypto-idea/references/crypto-necessity-test.md) (install first: `bash .claude/bin/skills.sh add solana-new`).

### 3. Exactly 3 candidates

Generate three **diverse** candidates (different mechanisms/markets, not three flavors of one idea). For each:

- One-line pitch + target user
- **Winner case** — what's true in 18 months if it works
- **Bear case** — the most likely way it dies

Seed from datasets + live landscape (below), then combine with fresh research. Datasets are inspiration, not constraints.

### 4. Score /15

Each candidate, 0–3 per dimension (full anchors: [scoring-rubric.md](../ext/solana-new/skills/idea/find-next-crypto-idea/references/scoring-rubric.md); install first: `bash .claude/bin/skills.sh add solana-new`):

| Dimension | 3 means |
|-----------|---------|
| Founder fit | unfair advantage |
| MVP speed | shippable in under a week |
| Distribution | first ten users are obvious |
| Market pull | people already paying for bad alternatives |
| Revenue path | clear monetization story |

### 5. Validate + go/no-go

Check demand signals against [customer-signal-rubric.md](../ext/solana-new/skills/idea/validate-idea/references/customer-signal-rubric.md) — manual workarounds, active forks, bounties, on-chain activity = real; likes and "cool idea" replies = noise. Sprint structure: [validation-framework.md](../ext/solana-new/skills/idea/validate-idea/references/validation-framework.md) (install first: `bash .claude/bin/skills.sh add solana-new`).

- **≥ 8/15** → go. Write `idea.md`, suggest `/scaffold` next.
- **6–7** → conditional: name the one dimension to de-risk first.
- **< 6** → strong no-go. **Every no-go gets a pivot suggestion** — use [pivot-or-persist.md](../ext/solana-new/skills/idea/validate-idea/references/pivot-or-persist.md) (install first: `bash .claude/bin/skills.sh add solana-new`).

### 6. Write `.claude/context/idea.md`

Chosen idea, wedge, scores table, demand evidence, bear case, next step.

## Idea datasets (inert JSON, ~515 entries)

In [../ext/solana-new/skills/data/ideas/](../ext/solana-new/skills/data/ideas/) (install first: `bash .claude/bin/skills.sh add solana-new`):

- [web3-ideas-combined.json](../ext/solana-new/skills/data/ideas/web3-ideas-combined.json) — master list ([summary](../ext/solana-new/skills/data/ideas/web3-ideas-summary.json)) (`bash .claude/bin/skills.sh add solana-new`)
- [a16z-big-ideas-2025.json](../ext/solana-new/skills/data/ideas/a16z-big-ideas-2025.json), [a16z-state-of-crypto-2025.json](../ext/solana-new/skills/data/ideas/a16z-state-of-crypto-2025.json) (`bash .claude/bin/skills.sh add solana-new`)
- [yc-requests-for-startups.json](../ext/solana-new/skills/data/ideas/yc-requests-for-startups.json), [yc-crypto-companies.json](../ext/solana-new/skills/data/ideas/yc-crypto-companies.json) (`bash .claude/bin/skills.sh add solana-new`)
- [alliance-ideas.json](../ext/solana-new/skills/data/ideas/alliance-ideas.json), [superteam-ideas.json](../ext/solana-new/skills/data/ideas/superteam-ideas.json) (`bash .claude/bin/skills.sh add solana-new`)
- [rwa-defi-2026-ideas.json](../ext/solana-new/skills/data/ideas/rwa-defi-2026-ideas.json), [yash-defi-2024-ideas.json](../ext/solana-new/skills/data/ideas/yash-defi-2024-ideas.json) (`bash .claude/bin/skills.sh add solana-new`)

Idea-source guides (markdown commentary on the same sources): [../ext/solana-new/skills/data/guides/](../ext/solana-new/skills/data/guides/) — plus [source-map.md](../ext/solana-new/skills/idea/find-next-crypto-idea/references/source-map.md) and [research-playbook.md](../ext/solana-new/skills/idea/find-next-crypto-idea/references/research-playbook.md) for where/how to research live (install first: `bash .claude/bin/skills.sh add solana-new`).

## Live hackathon landscape

[ext/colosseum](../ext/colosseum/skills/colosseum-copilot/SKILL.md) — 5,400+ Colosseum submissions for crowdedness checks, winner patterns, and gap analysis (requires `COLOSSEUM_COPILOT_PAT`; install first: `bash .claude/bin/skills.sh add colosseum`).

## Output format

Report spec (3 ranked candidates, scores, decision): [output-spec.md](../ext/solana-new/skills/idea/find-next-crypto-idea/references/output-spec.md) (install first: `bash .claude/bin/skills.sh add solana-new`).
