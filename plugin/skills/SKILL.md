---
name: solana-ai-kit
description: Skill hub for the solana-ai-kit Claude Code plugin. Routes the bundled go-to-market skills and the opt-in add-on catalog, and points to upstream marketplaces or the install.sh full install for protocol, security and ecosystem depth.
user-invocable: true
---

# Solana AI Kit plugin skill hub

This is the plugin variant of the kit's skill hub. It ships only the skills that travel cleanly in a plugin: the go-to-market skills, the Token Extensions skill and the opt-in add-on catalog. The protocol, security and ecosystem skills, the project CLAUDE.md with the program-code house rules, and the curated permissions and sandbox policy come with the full install (see "Getting more depth").

When sources overlap: a protocol's official skill wins for its own SDK (Jupiter, Metaplex, Helius); the Solana Foundation `solana-dev` skill wins for general Solana work (Anchor, Pinocchio, testing, clients); community skills such as sendai fill gaps only. In plugin form, add the relevant upstream marketplace first.

## Bundled skills

These load when the plugin is enabled. Commands and skills are namespaced under `solana-ai-kit:` (for example `/solana-ai-kit:deploy`).

- [idea-sprint/SKILL.md](idea-sprint/SKILL.md): what to build; blunt interview, crypto-necessity gate, 3 scored candidates, go/no-go
- [pitch-deck/SKILL.md](pitch-deck/SKILL.md): audience-aware decks (hackathon, VC, grant, accelerator) with speaking notes and objection prep
- [hackathon/SKILL.md](hackathon/SKILL.md): scannable submissions, demo scripts under 3 minutes, track choice, Superteam Earn grants
- [skill-registry.json](skill-registry.json): catalog of opt-in add-on skills, plugins and MCPs that are not bundled. Search it by domain or tag and run an entry's install command only after the user confirms and `safe-ai-skill add skill|mcp <source>` returns `proceed: true`. Entries with a `tier` are the full install's pinned skill packs; their `source` is the upstream repo.

These three skills are adapted from sendaifun/solana-new (MIT, telemetry removed).

The kit's own [token-extensions/SKILL.md](token-extensions/SKILL.md) covers Token-2022: which extensions to use and how they combine, then per-extension CLI, Kit and Anchor setup. Its links to the Solana Foundation solana-dev skill need the full install (Option B).

## Security firewall (core)

This plugin depends on [safe-ai-skill](https://github.com/solanabr/safe-ai-skill) (`safe-ai-skill@stbr`), which installs with it. Its hooks gate mainnet, value-moving and authority actions and secret reads, and pin installed skills at session start. Its ask or deny is the user's policy, so don't retry the action another way. Its CLI is on PATH while it is enabled: `safe-ai-skill status`, `safe-ai-skill verify check <dir>`.

## Getting more depth

Plugins cannot carry git submodules, so the kit's external skill packs (the `ext` submodules) are not bundled here. Two ways to get them:

### Option A: add the upstream marketplaces

| Domain | Add the marketplace | Then install |
|--------|---------------------|--------------|
| DeFi protocols, infra, data (Jupiter, Raydium, Kamino, perps, oracles, cross-chain) | `/plugin marketplace add sendaifun/skills` | the protocol plugins you need |
| AppSec scanning (SAST, SCA, secrets) | `/plugin marketplace add ghostsecurity/skills` | `ghost` |
| Security auditing, vulnerability scanning | `/plugin marketplace add trailofbits/skills` | the audit plugins you need |
| Infrastructure (Workers, Agents SDK, MCP servers) | `/plugin marketplace add cloudflare/skills` | `cloudflare` |

For Jupiter, Metaplex, Helius, MagicBlock and Alchemy the official skill repos are the primary sources; `skill-registry.json` lists their current upstream locations. Route to a marketplace and install the plugin rather than pointing at an upstream repo's `SKILL.md`.

### Option B: full install (recommended for project teams)

Run the installer in your project to get what the plugin can't carry: the core external skill packs (extensions install on demand with `/add-skill`), the project CLAUDE.md, and the curated permissions and sandbox policy.

```bash
curl -fsSL https://raw.githubusercontent.com/solanabr/ai-kit/main/install.sh | bash
```

The project README ("External Skill Submodules" and "Install as a Claude Code plugin") explains when to pick the plugin or the full install; they are complementary. If both are active in one project, `/solana-ai-kit:doctor` flags the duplicate commands, hooks and MCP servers.

## Task routing

| User asks about | Skill |
|-----------------|-------|
| Idea validation, "what should I build" | idea-sprint/SKILL.md |
| Pitch deck, demo day, investor or grant slides | pitch-deck/SKILL.md |
| Hackathon submission, demo script, track choice | hackathon/SKILL.md |
| An add-on skill, plugin or MCP that isn't bundled | skill-registry.json |
| A safe-ai-skill ask or deny, skill or MCP supply-chain checks | Security firewall (core) above |
| Protocol SDK depth, security audits, infra | Option A marketplaces or the Option B full install |
| Token-2022 extensions: fees, hooks, metadata, pausable, confidential | token-extensions/SKILL.md |
