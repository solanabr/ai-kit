---
name: skill-packs
description: Which optional skill pack the kit has for the work at hand, and how to offer it. Read it when starting work the kit pins a pack for and that pack may not be installed yet — program development and formal verification, landing pages and UI design, motion and animation, NFTs, DeFi SDKs, Unity games, mobile, RPC and indexing, pitch and go-to-market, data visualization — or when the user asks what packs exist. Covers the pinned extensions and also the unpinned add-ons that only skill-registry.json records.
user-invocable: true
---

# Which skill pack for this work

Four packs ship installed — solana-dev, auditor-skill, colosseum and anthropic-skills — and everything else arrives on demand. The point of this file is that the user does not have to know the catalogue: notice from the work itself that a pack would help, name it, and let them decide. A core pack is never the answer here, because it is already there; this file only covers what still has to be fetched.

## What the kit can promise about a pack

| | Pinned extension | Add-on |
|---|---|---|
| In [skill-registry.json](../skill-registry.json) | `"tier": "extension"` | no tier |
| Install | `bash .claude/bin/skills.sh add <id>`, or `/add-skill <id>` | the `install.command` in its registry entry — read the entry rather than reconstructing the command, because the method varies (submodule, clone, npx, a plugin marketplace) |
| Commit installed | the `commit` its registry entry records — reviewed here, and checked against the gitlink by `validate.sh` | whatever upstream HEAD is that day, reviewed by nobody here |
| Kept by `/update` | yes | no |
| Who runs it | the user, on a yes | the user, and only after `safe-ai-skill add skill\|mcp <source>` returns `proceed: true` |

An add-on entry's `license` and `safety` lines are load-bearing, so read them out before the user installs: several packs carry no license (usable, not redistributable), a few have been stale for a year, and some write hooks or a statusline into `settings.json` when run through their own installer.

## Work to packs

Ids in the middle column install with `bash .claude/bin/skills.sh add <id>`. Ids in the right column need their registry entry.

| Work | Pinned extensions | Add-ons |
|------|-------------------|---------|
| Any program work: Anchor, Pinocchio, native | `qedgen` (Lean 4 proof that the invariant you just wrote holds), `quicknode-anchor` (fixed-point and financial math) | — |
| Porting a Solidity or EVM contract | — | `eth-to-sol` (the Solana Foundation's type, pattern and stdlib mappings; it carries no licence file, so read it where it lands rather than vendoring it) |
| Landing page, marketing site, any UI surface | `vercel` (web design review, Next.js and React performance), `get-shit-pretty` (brand identity and a design system: shadcn theme, design tokens, UI critique, WCAG audit — 45 skills, 13 sub-agents), `solana-new` (brand design, design taste, frontend design guidelines, number formatting) | `anydesign` (an image, URL or Figma frame into design tokens), `design-skills` (design critique, accessibility audit, journey mapping), `ux-writing-skill` (onboarding, error and empty-state copy) |
| Animation, motion, transitions, page-load choreography | `solana-new` (page-load animation and video-craft references) | `emilkowalski-skill` (animate, review-animations, apple-design; markdown only), `animation-principles` (motion principles as prose; unmaintained since December 2025) |
| NFTs, collections, compressed NFTs | `metaplex` | — |
| Swaps, lending, perps, oracles, bridges | `jupiter`, `sendai` | `meteora-invent` (Meteora's own skill, deeper than the sendai folder) |
| Unity, C#, PSG1, real-time games | `solana-game`, `magicblock` (ephemeral rollups for real-time state) | — |
| React Native, Expo, Seeker, dApp Store | `solana-mobile` | `ios-simulator-skill`, `swiftui-design-skill` |
| RPC, DAS, webhooks, indexing, edge hosting | `helius`, `alchemy`, `cloudflare` | — |
| Browser QA of a dApp that is already running | — | `playwright-skill`, `dev-browser` |
| An MCP server for your program or API | `cloudflare` (Agents SDK, MCP servers on Workers) | `anthropic-claude-code-plugins` (its mcp-server-dev plugin: deployment models, tool design, auth) |
| Pitch deck, demo day, hackathon, competitive research | `solana-new` | `frontend-slides` (animation-rich HTML decks) |
| Charts, dashboards, on-chain data visualization | — | `claude-d3js-skill` (no license, so read it, don't vendor it), `scientific-agent-skills` |

Some work needs no offer at all, because the pack for it already ships. A security audit, a dependency or secret scan, a threat model has no row above: read the core auditor-skill pack, which superseded the trailofbits, ghostsecurity, defending-code and safe-solana-builder packs the kit used to pin. General program, client and test work rests on core solana-dev — the program row above adds only the specialists on top of it. A visual direction for a UI, and Playwright QA of a running app, are core anthropic-skills: its `frontend-design` and `webapp-testing` install top-level and are listed every session, so they are already in front of you. Its third skill, `mcp-builder`, is not in the pack any more — Anthropic ships it per-user from its own marketplace. Colosseum archives, idea validation and competitive research are core colosseum, which signs in through its own helper rather than an API key, so the key section below does not list it ([the hub](../SKILL.md) has the sign-in). Offering any of these is a wasted question.

The registry holds more entries than this table: watchlist items, archived repos, and duplicates of a pack already listed here. Search it by `domain` or `tags` when the work fits no row.

## Packs that need a key

Name the key when offering the pack, and check whether it is set with `bash .claude/bin/env-keys.sh`, which prints one `KEY set|empty` line and never a value. Reading `.env` is denied at the Medium and High firewall tiers, and a value read into the transcript has already left the machine.

- `qedgen` — `MISTRAL_API_KEY` for fill-sorry and generate, `ARISTOTLE_API_KEY` for the aristotle commands. Without either, its Lean references still read but nothing generates, so the pack is worth installing only alongside a key.
- `alchemy` — `ALCHEMY_API_KEY` for the alchemy-api skill; its agentic-gateway skill is keyless (x402), so the pack still earns its place without a key.

A pack that is inert without a key the user has not set is a question, not an install: say which key it needs and what it would do once set.

## Offering rules

- One or two packs, with a sentence each on what they add that the kit does not already have. The user asked for the work, not for a shopping list.
- Already installed (`bash .claude/bin/skills.sh list` marks it) means read it and carry on, with no offer. `bash .claude/bin/skills.sh uninstalled` is the list still worth offering.
- Install on a yes, never ahead of one: it is a network fetch and a write under `.claude/skills/`. An extension goes through `/add-skill <id>`; an add-on's command is the user's to run.
- A no stands for the rest of the session. Do the work with what is installed.
- No `.claude/bin/skills.sh` means a plugin install or a kit older than the core/extension split, where no extension is installable. Route to the upstream marketplace or the full install instead, as [the hub](../SKILL.md) describes.
- Which files to read once a pack is installed is [the hub](../SKILL.md)'s job, not this file's. This one only answers which pack.
