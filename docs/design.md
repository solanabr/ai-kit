# How the kit is designed

Why the always-on context is small, how the rest arrives on demand, and the stack the kit assumes.

## Progressive disclosure, by default

The idea here is to provide a generic CLAUDE.md that relies on subagents to plan and execute actions, dynamically loading markdown files, saving tokens and context in the end of the day. This config fully leverages the official Claude Code config recommendations:

- Nothing loads up front except a small CLAUDE.md and one-line agent/command descriptions; agent, command and skill bodies load only when used;
- SKILL.md is a mega hub to dynamically-disclosed skill files that are directly fetched from the best skill repos distributed across the ecosystem (Solana Foundation, Colosseum, Solana Mobile, SendAI, etc);
- Plus, its CLAUDE-solana.md is less than half the size of the usual CLAUDE.md, leaving space for its self improvements programmed into the agents, noting and learning from anti-patterns, errors, recurrency and more. For less important notes, CLAUDE.local.md is constantly maintained by agents as well and, on monorepos, per-folder CLAUDE.md is also maintained.

Current multi-agent workflow favors monorepos, so we use a single CLAUDE.md/config for the whole project while leveraging agents and context-specific skills to solve each step of builder flow.

## Token-Efficient Design

- CLAUDE.md is delivered as a user message (not system prompt) — shorter = better adherence
- Skills load progressively (not all at once)
- Agents reference skills instead of duplicating content
- No always-loaded rules: Claude Code reads only `paths:` from a rule file and loads anything else every session, so the kit ships no rules and `validate.sh` fails on an unscoped one
- Agent and command descriptions are listed in every session, so they stay one or two sentences
- `CLAUDE.local.md` for private scratch notes (gitignored, never shared)
- Subdirectory CLAUDE.md files lazy-load in monorepos
- Decision frameworks live in agents, not global context

## Modern Stack (2026)

| Layer | Stack |
|-------|-------|
| Programs | Anchor 1.0+, Pinocchio, Rust 1.82+ |
| Token Extensions | Token-2022 (transfer hooks, confidential transfers, metadata) |
| Testing | Mollusk, LiteSVM, Surfpool, Trident |
| Frontend | @solana/kit, Next.js 15, React 19 |
| Mobile | React Native, Expo, Mobile Wallet Adapter |
| Backend | Axum 0.8+, Tokio 1.40+, sqlx |
| Unity Games | Solana.Unity-SDK, .NET 9, C# 13 |
| PlaySolana | PSG1 console, PlayDex, SvalGuard |
| DeFi | Jupiter, Kamino, Raydium, Orca, Meteora |
| Infrastructure | Cloudflare Workers, GitHub Actions, Docker |
