---
name: skill-packs
description: Which optional skill pack the kit has for the work at hand, and how to offer it. Read it when starting work the kit pins a pack for and that pack may not be installed yet — program development and formal verification, landing pages and UI design, motion and animation, NFTs, DeFi SDKs, Unity games, mobile, RPC and indexing, security audits, pitch and go-to-market, data visualization — or when the user asks what packs exist. Covers the pinned extensions and also the unpinned add-ons that only skill-registry.json records.
user-invocable: true
---

# Which skill pack for this work

Two packs ship installed; everything else arrives on demand. The point of this file is that the user does not have to know the catalogue: notice from the work itself that a pack would help, name it, and let them decide.

## What the kit can promise about a pack

| | Pinned extension | Add-on |
|---|---|---|
| In [skill-registry.json](../skill-registry.json) | `"tier": "extension"` | no tier |
| Install | `bash .claude/bin/skills.sh add <id>`, or `/add-skill <id>` | the `install.command` in its registry entry — read the entry rather than reconstructing the command, because the method varies (submodule, clone, npx, `claude mcp add`) |
| Commit installed | the one the kit reviewed and pins | whatever upstream HEAD is that day, reviewed by nobody here |
| Kept by `/update` | yes | no |
| Who runs it | the user, on a yes | the user, and only after `safe-ai-skill add skill\|mcp <source>` returns `proceed: true` |

An add-on entry's `license` and `safety` lines are load-bearing, so read them out before the user installs: several packs carry no license (usable, not redistributable), a few have been stale for a year, `get-shit-pretty` merges hooks and a statusline into `settings.json`, and `ghostsecurity` — pinned, same caution — ships unpinned `curl | bash` installers.

## Work to packs

Ids in the middle column install with `bash .claude/bin/skills.sh add <id>`. Ids in the right column need their registry entry.

| Work | Pinned extensions | Add-ons |
|------|-------------------|---------|
| Any program work: Anchor, Pinocchio, native | `qedgen` (Lean 4 proof that the invariant you just wrote holds), `trailofbits` (vulnerability scanner, audit prep), `quicknode-anchor` (fixed-point and financial math), `defending-code` (threat model while the account layout is still open) | — |
| Porting a Solidity or EVM contract | `eth-to-sol` | — |
| Landing page, marketing site, any UI surface | `anthropic-skills` (frontend-design: a visual direction that is not the default template), `vercel` (web design review, Next.js and React performance), `solana-new` (brand design, design taste, frontend design guidelines, number formatting) | `anydesign` (an image, URL or Figma frame into design tokens), `design-skills` (design critique, accessibility audit, journey mapping), `ux-writing-skill` (onboarding, error and empty-state copy), `get-shit-pretty` (45 design skills; writes hooks into settings.json) |
| Animation, motion, transitions, page-load choreography | `solana-new` (page-load animation and video-craft references) | `emilkowalski-skill` (animate, review-animations, apple-design; markdown only), `animation-principles` (motion principles as prose; unmaintained since December 2025) |
| NFTs, collections, compressed NFTs | `metaplex` | — |
| Swaps, lending, perps, oracles, bridges | `jupiter`, `sendai` | `meteora-invent` (Meteora's own skill, deeper than the sendai folder) |
| Unity, C#, PSG1, real-time games | `solana-game`, `magicblock` (ephemeral rollups for real-time state) | — |
| React Native, Expo, Seeker, dApp Store | `solana-mobile` | `ios-simulator-skill`, `swiftui-design-skill` |
| RPC, DAS, webhooks, indexing, edge hosting | `helius`, `alchemy`, `cloudflare` | `dexpaprika-mcp` (free DEX market data), `nansen-mcp` (wallet labels and smart money; paid), `chainstack-mcp` |
| Security audit, AppSec, dependency and secret scanning | `trailofbits`, `ghostsecurity`, `defending-code` | — |
| Browser QA of a dApp that is already running | `anthropic-skills` (webapp-testing) | `playwright-skill`, `dev-browser` |
| An MCP server for your program or API | `anthropic-skills` (mcp-builder) | — |
| Pitch deck, demo day, hackathon, competitive research | `solana-new`, `colosseum` (Colosseum's hackathon archives) | `frontend-slides` (animation-rich HTML decks) |
| Charts, dashboards, on-chain data visualization | — | `claude-d3js-skill` (no license, so read it, don't vendor it), `scientific-agent-skills` |

The registry holds more entries than this table: watchlist items, archived repos, and duplicates of a pack already listed here. Search it by `domain` or `tags` when the work fits no row.

## Packs that need a key

Name the key when offering the pack, and check whether it is set with `bash .claude/bin/env-keys.sh`, which prints one `KEY set|empty` line and never a value. Reading `.env` is denied at the Medium and High firewall tiers, and a value read into the transcript has already left the machine.

- `qedgen` — `MISTRAL_API_KEY` for fill-sorry and generate, `ARISTOTLE_API_KEY` for the aristotle commands. Without either, its Lean references still read but nothing generates, so the pack is worth installing only alongside a key.
- `colosseum` — `COLOSSEUM_COPILOT_PAT`. Every answer is a query against Colosseum's API, so with no PAT the pack returns nothing. Ask for the key before installing, not after.
- `alchemy` — `ALCHEMY_API_KEY` for the alchemy-api skill; its agentic-gateway skill is keyless (x402), so the pack still earns its place without a key.
- `anthropic-skills` — frontend-design and webapp-testing need no key; only mcp-builder's evaluation script does (`ANTHROPIC_API_KEY`).
- `nansen-mcp` — `NANSEN_API_KEY`, billed per credit. `get-shit-pretty` — `FIGMA_ACCESS_TOKEN`, optional.

A pack that is inert without a key the user has not set is a question, not an install: say which key it needs and what it would do once set.

## Offering rules

- One or two packs, with a sentence each on what they add that the kit does not already have. The user asked for the work, not for a shopping list.
- Already installed (`bash .claude/bin/skills.sh list` marks it) means read it and carry on, with no offer. `bash .claude/bin/skills.sh uninstalled` is the list still worth offering.
- Install on a yes, never ahead of one: it is a network fetch and a write under `.claude/skills/`. An extension goes through `/add-skill <id>`; an add-on's command is the user's to run.
- A no stands for the rest of the session. Do the work with what is installed.
- No `.claude/bin/skills.sh` means a plugin install or a kit older than the core/extension split, where no extension is installable. Route to the upstream marketplace or the full install instead, as [the hub](../SKILL.md) describes.
- Which files to read once a pack is installed is [the hub](../SKILL.md)'s job, not this file's. This one only answers which pack.
