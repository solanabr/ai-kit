# Skill packs and add-ons

The kit's Solana knowledge is not written here: it is pinned from the ecosystem's own skill repositories — Solana Foundation, Colosseum, Jupiter, Metaplex, MagicBlock, Helius, Alchemy, SendAI, Solana Mobile and more — and routed by [`.claude/skills/SKILL.md`](../.claude/skills/SKILL.md), which loads only the files a task needs.

## External Skill Submodules

The kit pins every skill pack below as a git submodule, except `anthropic-skills`, which it pins to an upstream commit. Every entry records that commit in [`skill-registry.json`](../.claude/skills/skill-registry.json), and `validate.sh` fails if the record and the gitlink disagree — the registry is the only pin a user project carries, since ext/ packs arrive as vendored copies with their gitfiles stripped. **Core** packs install with every full install. **Extensions** are pinned the same way but install on demand, so a project carries only the packs it uses (in `--agents` installs, Codex and opencode load every nested `SKILL.md` they find, so each pack costs context on every request).

A pack's *own* submodules are not fetched: they are pinned by that pack's author, not here, and the install vendors what it fetches, so recursing would copy a third-party tree into your project at a commit nobody in this repo records. Two packs have one — `auditor-skill` → `trailofbits` (CC-BY-SA-4.0), `solana-game` → a second `solana-dev` at a different commit — and both test for it and fall back when it is absent. The registry's `vendored` field records those pins so a bump moves them in review rather than silently. `/update` prunes them for the same reason (its clone recurses, from a frozen code path). To opt in, clone the tree yourself at the commit `vendored` records — in a project an installed pack is a plain copy with no git metadata, so `git submodule update` there has nothing to act on, and the next `/update` removes it again.

| Submodule | Tier | Source | Purpose |
|-----------|------|--------|---------|
| `ext/solana-dev` | Core | [solana-foundation/solana-dev-skill](https://github.com/solana-foundation/solana-dev-skill) | Core Solana development (programs, frontend, testing, security) |
| `ext/auditor-skill` | Core | [solanabr/auditor-skill](https://github.com/solanabr/auditor-skill) | Security audits: 20 checklists / 1,424 items / 138 known vectors, over programs and the code around them. MIT. Replaces the trailofbits, ghostsecurity, defending-code and safe-solana-builder packs |
| `ext/colosseum` | Core | [ColosseumOrg/colosseum-copilot](https://github.com/ColosseumOrg/colosseum-copilot) | Startup research, idea validation, hackathon archives. **Proprietary** (README: Copyright Colosseum; no LICENSE file) — the only non-open-source pack installed by default. Signs in with `npx @colosseum-org/copilot-connect login`, Node 20+ |
| `ext/qedgen` | Extension | [QEDGen/solana-skills](https://github.com/QEDGen/solana-skills) | Formal verification with Lean 4 theorem proving |
| `ext/sendai` | Extension | [sendaifun/skills](https://github.com/sendaifun/skills) | DeFi protocol integrations (Jupiter, Raydium, Kamino, perps, cross-chain, oracles, etc.) |
| `ext/jupiter` | Extension | [jup-ag/agent-skills](https://github.com/jup-ag/agent-skills) | Official Jupiter skills: Ultra swap, Lend, swap migration, VRFD |
| `ext/metaplex` | Extension | [metaplex-foundation/skill](https://github.com/metaplex-foundation/skill) | Official Metaplex: Core, Token Metadata, Bubblegum, Candy Machine, Genesis |
| `ext/magicblock` | Extension | [magicblock-labs/magicblock-dev-skill](https://github.com/magicblock-labs/magicblock-dev-skill) | Official MagicBlock: Ephemeral Rollups, private payments, VRF, cranks |
| `ext/helius` | Extension | [helius-labs/core-ai](https://github.com/helius-labs/core-ai) | Official Helius infra skill + unique SVM internals skill |
| `ext/alchemy` | Extension | [alchemyplatform/skills](https://github.com/alchemyplatform/skills) | Official Alchemy: Solana RPC, DAS, Yellowstone gRPC, x402 gateway |
| `ext/quicknode-anchor` | Extension | [quicknode/solana-finance-claude-plugin](https://github.com/quicknode/solana-finance-claude-plugin) | Anchor/financial-math/Quasar reference files (quarantined — refs only) |
| `ext/eth-to-sol` | Extension | [solana-foundation/eth-to-sol-skill](https://github.com/solana-foundation/eth-to-sol-skill) | EVM/Solidity → Anchor two-pass porting |
| `ext/solana-game` | Extension | [solanabr/solana-game-skill](https://github.com/solanabr/solana-game-skill) | Game development (Unity, PlaySolana, PSG1) |
| `ext/solana-mobile` | Extension | [solana-mobile/solana-mobile-skills](https://github.com/solana-mobile/solana-mobile-skills) | Mobile Wallet Adapter, Genesis Token, SKR address resolution |
| `ext/cloudflare` | Extension | [cloudflare/skills](https://github.com/cloudflare/skills) | Infrastructure (Workers, Agents SDK, MCP servers) |
| `ext/vercel` | Extension | [vercel-labs/agent-skills](https://github.com/vercel-labs/agent-skills) | Vercel deployment, Next.js, AI SDK, v0, edge functions |
| `ext/solana-new` | Extension | [sendaifun/solana-new](https://github.com/sendaifun/solana-new) | 32 idea→launch journey skills + idea datasets/knowledge base; routed via local wrappers |
| `anthropic-skills` (not a submodule) | Extension | [anthropics/skills](https://github.com/anthropics/skills) | Anthropic's Apache-2.0 frontend-design, webapp-testing and mcp-builder as top-level skills any agent loads ([details](#anthropics-skills-in-any-agent)) |

**Installing extensions.** At install time: `bash install.sh --with sendai,jupiter` (`--with all` installs every pack). Later: `/add-skill <id>` or `bash .claude/bin/skills.sh add <id>` (`.agents/bin/` for `--agents` installs); `skills.sh list` shows every pack and when to use it; `skills.sh add --force <id>` reinstalls a pack. Agents do the same on their own: each hub row, agent and command line that links into an extension names its install command. `/update` keeps the extensions a project installed (recorded in `.claude/skills/extensions.txt`); installs made before the core/extension split keep every pack. When a kit update drops a pack from the registry, `/update` removes it from projects the kit installed it in (`skills/kit-packs.txt`, `extensions.txt`); folders you put in `skills/ext/` yourself stay.

**Updates.** Dependabot opens one grouped pull request a week that bumps the pins (`.github/dependabot.yml`, with a 7-day cooldown on upstream commits). CI runs `validate.sh` on it, which resolves every `ext/` link in the hub, agents, commands and local skills against the new pins, so a path an upstream pack moved fails the PR instead of a user's session.

**Adding a pack.** `git submodule add <url> .claude/skills/ext/<id>`, then an entry in [`skill-registry.json`](../.claude/skills/skill-registry.json) with `tier`, `path`, `triggers` and the install command, a hub route, and a row in the hub's Extensions table; `tests/test_skill_extensions.sh` checks they agree. New packs come in as extensions from official or organization-owned repos with a permissive license and recent activity.

## Extended Skills & Add-on Registry

Beyond the bundled submodules above, the kit ships a curated catalog of **opt-in** skills, plugins, and MCPs that are **not installed by default** — the agent installs them only on your request, at your own expense. The set is deduped against [solana-new's](https://github.com/sendaifun/solana-new) vendored ecosystem catalogs so it surfaces net-new, high-signal picks rather than restating what's already reachable.

Featured add-ons by domain:

- **Claude-official:** [anthropics/claude-code](https://github.com/anthropics/claude-code) plugins (non-OSI license; overlaps `/diff-review` + `cso`). Anthropic's Apache-2.0 skills are the `anthropic-skills` extension above
- **Dev-workflow:** [wshobson/agents](https://github.com/wshobson/agents)
- **Frontend/Design:** [zarazhangrui/frontend-slides](https://github.com/zarazhangrui/frontend-slides) · [uxKero/anydesign](https://github.com/uxKero/anydesign) · [dylantarre/animation-principles](https://github.com/dylantarre/animation-principles)
- **UX/Writing:** [content-designer/ux-writing-skill](https://github.com/content-designer/ux-writing-skill) · [cuellarfr/design-skills](https://github.com/cuellarfr/design-skills)
- **Testing:** [SawyerHood/dev-browser](https://github.com/SawyerHood/dev-browser) · [conorluddy/ios-simulator-skill](https://github.com/conorluddy/ios-simulator-skill)
- **Data:** [K-Dense-AI/scientific-agent-skills](https://github.com/K-Dense-AI/scientific-agent-skills) · [Nansen](https://github.com/nansen-ai/nansen-cli) (paid analytics MCP)

**Where we scout** new tools (aggregators, not installable): [ComposioHQ/awesome-claude-skills](https://github.com/ComposioHQ/awesome-claude-skills) · [travisvn/awesome-claude-skills](https://github.com/travisvn/awesome-claude-skills) · [davepoon/buildwithclaude](https://github.com/davepoon/buildwithclaude) · [hesreallyhim/awesome-claude-code](https://github.com/hesreallyhim/awesome-claude-code) · [VoltAgent/awesome-claude-code-subagents](https://github.com/VoltAgent/awesome-claude-code-subagents).

For broader Solana coverage, see solana-new's vendored catalogs at `ext/solana-new/cli/data/` (MCPs, skills, clonable repos; install the solana-new extension first).

See [`skill-registry.json`](../.claude/skills/skill-registry.json) for the complete extended catalog — every entry with its install command, license, and safety caveats. The same file records the tier and triggers of each pinned pack above; entries without a tier are these opt-in add-ons.

## Anthropic's skills in any agent

The `anthropic-skills` extension installs three Apache-2.0 skills from [anthropics/skills](https://github.com/anthropics/skills) as top-level skills, so every harness in [other-agents.md](other-agents.md) loads them by description: `frontend-design` (distinctive UI direction), `webapp-testing` (Playwright tests of a local web app) and `mcp-builder` (MCP servers for a program or API). They land in `.claude/skills/<name>/`, or in `.agents/skills/<name>/` with `--agents`:

```bash
bash install.sh --with anthropic-skills /path/to/your-project   # add --agents for Codex and the others
bash .claude/bin/skills.sh add anthropic-skills                  # later (.agents/bin/ with --agents), or /add-skill anthropic-skills
```

`skills.sh` fetches only those three folders, at the commit pinned in [`skill-registry.json`](../.claude/skills/skill-registry.json), and copies them unchanged with their `LICENSE.txt`. It refuses the repo's restricted skills whatever the registry lists: `docx`, `pdf`, `pptx` and `xlsx` are proprietary and licensed for use only within Anthropic's services, and `doc-coauthoring` has no license. Claude users get the document skills first-party from Anthropic: they power file creation in the Claude apps, and Claude Code installs them from Anthropic's own marketplace (`/plugin marketplace add anthropics/skills`, then `/plugin install document-skills@anthropic-agent-skills`).

Two of the three run code: `webapp-testing`'s `scripts/with_server.py` starts the server commands it is given through a shell, and `mcp-builder`'s evaluation script calls the Anthropic API with `ANTHROPIC_API_KEY`.

The pin moves by hand, not through Dependabot: review the upstream diff of the three folders, update `commit` in the registry entry, then run `bash tests/test_anthropic_skills.sh`, which re-checks each skill's license and frontmatter at the new commit.
