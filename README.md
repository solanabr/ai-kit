<p align="center"><img src=".github/assets/solana-ai-kit-banner.png" alt="Solana AI Kit — Skill, MCP & config aggregator for Claude Code, Codex + any agentic setup" width="100%" /></p>

# Solana AI Kit

[![CI](https://github.com/solanabr/ai-kit/actions/workflows/ci.yml/badge.svg)](https://github.com/solanabr/ai-kit/actions/workflows/ci.yml)
![Version](https://img.shields.io/badge/version-2.2.0-blue)
![License](https://img.shields.io/badge/license-MIT-blue)
![Solana](https://img.shields.io/badge/Solana-black?logo=solana)
![Claude Code](https://img.shields.io/badge/Claude_Code-powered-orange)

Production-ready Claude Code configuration for full-stack Solana development. Combines best practices from multiple sources into an agent-optimized, token-efficient config you can install and adapt to your specific project.

The idea here is to provide a generic CLAUDE.md that relies on subagents to plan and execute actions, dynamically loading markdown files, saving tokens and context in the end of the day. This config fully leverages the official Claude Code config recommendations:
- Nothing loads up front except a small CLAUDE.md and one-line agent/command descriptions; agent, command and skill bodies load only when used;
- SKILL.md is a mega hub to dynamically-disclosed skill files that are directly fetched from the best skill repos distributed across the ecosystem (Solana Foundation, Colosseum, Solana Mobile, SendAI, etc);
- Plus, its CLAUDE-solana.md is than half the size of the usual CLAUDE.md, leaving space for its self improvements programmed into the agents, noting and learning from anti-patterns, errors, recurrency and more. For less important notes, CLAUDE.local.md is constantly maintained by agents as well and, on monorepos, per-folder CLAUDE.md is also maintained.

Current multi-agent workflow favors monorepos, so we use a single CLAUDE.md/config for the whole project while leveraging agents and context-specific skills to solve each step of builder flow.

If you installed manually, remember to rename ./CLAUDE-solana.md back to ./CLAUDE.md, as the current top-level CLAUDE.md file is focused on maintaining the repo itself.

## What This Is

A complete `.claude/` configuration that turns Claude into a Solana development expert with:

- **15 specialized agents** for different tasks (architecture, Anchor, Pinocchio, DeFi, tokens, frontend, mobile, backend, DevOps, QA, docs, games, Unity, learning, research)
- **30 workflow commands** for building, testing, deploying, profiling, migrating, and committing
- **3 MCP servers** on by default for on-chain data (Helius), Solana docs (solana-dev) and library docs (Context7), plus opt-in browser automation (Playwright), local-validator / mainnet-fork control (Surfpool) and context optimization (context-mode)
- **Agent teams** (opt-in, experimental) for multi-step workflows (architect → engineer → QA)
- **Progressive skill loading** that only loads context when needed (saves tokens)
- **A small always-on CLAUDE.md** carrying only the program-code house rules and workflow; everything else is on demand

## Quick Start

```bash
# Option 0: Fork Template (Github UI)
claude -m "/cleanup"  # then start claude code running /cleanup so top-level directory of your project isn't polluted


# Option 1: One-liner installer (Claude Code)
curl -fsSL https://aikit.superteam.codes | bash
# Fallback (or before the aikit.superteam.codes DNS is live): curl -fsSL https://raw.githubusercontent.com/solanabr/ai-kit/main/install.sh | bash

# Option 2: One-liner installer + AGENTS.md bridge (Codex, Cursor, Copilot)
curl -fsSL https://aikit.superteam.codes | bash -s -- --agents
# Fallback (or before the aikit.superteam.codes DNS is live): curl -fsSL https://raw.githubusercontent.com/solanabr/ai-kit/main/install.sh | bash -s -- --agents

# Option 3: Manual setup
git clone --recurse-submodules https://github.com/solanabr/ai-kit.git
cp -r solana-ai-kit/.claude /path/to/your-project/
cp solana-ai-kit/CLAUDE-solana.md /path/to/your-project/CLAUDE.md
cd /path/to/your-project && git submodule update --init --recursive

# Option 4: Claude Code plugin (run inside Claude Code)
/plugin marketplace add https://github.com/solanabr/ai-kit.git
/plugin install solana-ai-kit@stbr
# Commands then namespace as /solana-ai-kit:<name>. The plugin is the CORE kit
# (agents/commands/local skills/MCP/hooks); the curl one-liner (Option 1) is the
# FULL install, adding CLAUDE.md + permissions/sandbox + the 18 ext/ submodules.
# Details: see "Install as a Claude Code plugin" below.

# Start Claude Code
claude
```

### `--agents` Flag

Pass `--agents` to add a **bridge** on top of the normal install, for harnesses that read `AGENTS.md` and `.agents/skills/` — Codex, Cursor and GitHub Copilot. It does not create a second config tree: you get the usual `.claude/` install plus three small files.

| File | Purpose |
|---|---|
| `AGENTS.md` | The same instructions as `CLAUDE.md`, with the maintainer HTML comments stripped — Claude Code drops those before the model sees them, Codex does not |
| `.agents/skills/solana-ai-kit/SKILL.md` | One router skill pointing at `.claude/skills/SKILL.md` |
| `.codex/hooks.json` | A `PreToolUse` gate blocking mainnet deploys unless the command is prefixed `CONFIRM_MAINNET=1` — the same script Claude Code uses |

```bash
bash install.sh --agents /path/to/your-project
```

**In Codex, run `/hooks` once to review and trust the deploy gate** — project hooks stay inactive until you do.

Why one router instead of registering every skill: Codex divides a single metadata budget across all discovered skills and truncates each description to its share. Registering the ~230 vendored `ext/` packs drives that share to zero, so every description arrives empty. One entry keeps the hub readable and costs about 165 tokens per request.

**Grok Build needs no bridge.** It reads `.claude/` natively — skills, agents, MCP servers, hooks and `CLAUDE.md` — with [`[compat.claude]` defaulting to true](https://docs.x.ai/build/features/skills-plugins-marketplaces). Install it from `x.ai/cli/install.sh`; the npm packages named `grok-cli` are community projects, not xAI's.

opencode also reads `AGENTS.md` and `.agents/skills/`, so the bridge happens to work there, but it isn't tested or supported.

Updates use the normal path, since there is only one tree:

```bash
# Run from your project root:
bash .claude/bin/update.sh
```

### Config is gitignored by default

To keep your project clean, the installer adds `.claude/`, `CLAUDE.md`, `.mcp.json`, and `.gitmodules` to `.gitignore` — the kit reads as ignorable infrastructure, not your app code (the `ext/` skill submodules are ignored too, re-fetched via `git submodule update`).

Want the config tracked in git (team setup, reproducible config)? Run `/commit-claude-config` — it un-ignores those files and commits them (or edit `.gitignore` by hand). If your project already commits `.claude/` or its own `.gitmodules`, the new ignore lines are a no-op — git keeps tracking files it already tracks.

### MCP Setup (Optional)

After installation, configure MCP servers for enhanced capabilities:

```bash
# In your project with Claude Code running:
/setup-mcp
```

This guides you through the Helius API key and offers the [optional MCP servers](#optional-mcp-servers).

## Install as a Claude Code plugin

solana-ai-kit is also its own Claude Code marketplace serving one **core plugin**. From inside Claude Code:

```text
/plugin marketplace add https://github.com/solanabr/ai-kit.git
/plugin install solana-ai-kit@stbr
```

The plugin ships the **core kit**: the 15 agents, 30 commands, the local go-to-market + registry skills (idea-sprint, pitch-deck, hackathon), the 3 default MCP servers, and the dev hooks (banner, formatter, pre-deploy/commit gates). Commands and skills are namespaced — `/deploy` becomes `/solana-ai-kit:deploy`.

What the plugin **cannot** carry (Claude Code plugins are plain git clones — they can't init submodules or ship a permissions/sandbox policy), so these stay exclusive to the **full install** (`install.sh`):

- the project `CLAUDE.md` with the program-code house rules
- the curated permissions allowlist + sandbox policy
- the 18 `ext/` skill submodules (protocol, security, infra, ecosystem depth)

For protocol-skill depth in plugin form, add the upstream marketplaces instead (routing, not copying) — e.g. `/plugin marketplace add sendaifun/skills`, `ghostsecurity/skills`, `trailofbits/skills`, `cloudflare/skills`. The plugin's skill hub and `skill-registry.json` list the current targets.

The two paths are complementary: individuals wanting Solana agents/commands across **all** their projects → plugin at user scope; project teams working in one repo → `install.sh` (full kit). If you enable both in the same project, `/doctor` warns about duplicate commands/hooks/MCP and advises picking one. Plugin auto-update is off by default for third-party marketplaces — refresh with `/plugin marketplace update` + `claude plugin update`.

## External Skill Submodules

| Submodule | Source | Purpose |
|-----------|--------|---------|
| `ext/solana-dev` | [solana-foundation/solana-dev-skill](https://github.com/solana-foundation/solana-dev-skill) | Core Solana development (programs, frontend, testing, security) |
| `ext/sendai` | [sendaifun/skills](https://github.com/sendaifun/skills) | DeFi protocol integrations (Jupiter, Raydium, Kamino, perps, cross-chain, oracles, etc.) |
| `ext/solana-game` | [solanabr/solana-game-skill](https://github.com/solanabr/solana-game-skill) | Game development (Unity, PlaySolana, PSG1) |
| `ext/cloudflare` | [cloudflare/skills](https://github.com/cloudflare/skills) | Infrastructure (Workers, Agents SDK, MCP servers) |
| `ext/trailofbits` | [trailofbits/skills](https://github.com/trailofbits/skills) | Security auditing and vulnerability scanning |
| `ext/qedgen` | [QEDGen/solana-skills](https://github.com/QEDGen/solana-skills) | Formal verification with Lean 4 theorem proving |
| `ext/solana-mobile` | [solana-mobile/solana-mobile-dev-skill](https://github.com/solana-mobile/solana-mobile-dev-skill) | Mobile Wallet Adapter, Genesis Token, SKR address resolution |
| `ext/colosseum` | [ColosseumOrg/colosseum-copilot](https://github.com/ColosseumOrg/colosseum-copilot) | Startup research, idea validation, hackathon projects |
| `ext/safe-solana-builder` | [frankcastleauditor/safe-solana-builder](https://github.com/frankcastleauditor/safe-solana-builder) | Security-first code generation (70+ audit-derived rules) |
| `ext/vercel` | [vercel-labs/agent-skills](https://github.com/vercel-labs/agent-skills) | Vercel deployment, Next.js, AI SDK, v0, edge functions |
| `ext/solana-new` | [sendaifun/solana-new](https://github.com/sendaifun/solana-new) | 32 idea→launch journey skills + idea datasets/knowledge base; routed via local wrappers |
| `ext/ghostsecurity` | [ghostsecurity/skills](https://github.com/ghostsecurity/skills) | 7 AppSec skills: SAST criteria, SCA, secrets, validation |
| `ext/defending-code` | [anthropics/defending-code-reference-harness](https://github.com/anthropics/defending-code-reference-harness) | Anthropic vuln-discovery reference harness + 6 skills |
| `ext/jupiter` | [jup-ag/agent-skills](https://github.com/jup-ag/agent-skills) | Official Jupiter skills: Ultra swap, Lend, swap migration, VRFD |
| `ext/metaplex` | [metaplex-foundation/skill](https://github.com/metaplex-foundation/skill) | Official Metaplex: Core, Token Metadata, Bubblegum, Candy Machine, Genesis |
| `ext/helius` | [helius-labs/core-ai](https://github.com/helius-labs/core-ai) | Official Helius infra skill + unique SVM internals skill |
| `ext/quicknode-anchor` | [quiknode-labs/solana-anchor-claude-skill](https://github.com/quiknode-labs/solana-anchor-claude-skill) | Anchor/financial-math/Quasar reference files (quarantined — refs only) |
| `ext/eth-to-sol` | [solana-foundation/eth-to-sol-skill](https://github.com/solana-foundation/eth-to-sol-skill) | EVM/Solidity → Anchor two-pass porting |

### Agent Teams

Each agent loads its own specialized context on invocation:

```
"Use solana-architect to design the vault program"
"Use anchor-engineer to implement the deposit instruction"
"Use defi-engineer to integrate Jupiter swaps"
"Use solana-qa-engineer to write comprehensive tests"
```

Claude will spawn each specialized agent by itself based on context. Agent teams, where several Claude sessions share a task list and message each other, are an experimental Claude Code feature that is off by default, and the kit leaves it off: while it is on, a subagent Claude names can launch as a teammate, which costs more tokens. To opt in, add this to `.claude/settings.local.json`:

```json
{ "env": { "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1" } }
```

Then ask for a team:

```
"Create an agent team: solana-architect for design, anchor-engineer for implementation, solana-qa-engineer for testing"
```

Recommended team patterns:

| Pattern | Flow | Use Case |
|---------|------|----------|
| **program-ship** | architect → anchor/pinocchio → qa | Build program from spec to tested |
| **full-stack** | architect → anchor → frontend → qa | End-to-end feature |
| **audit-and-fix** | qa → trailofbits context → anchor | Audit and remediate |
| **game-ship** | game-architect → unity → qa | Game feature |
| **research-and-build** | researcher → architect → anchor/pinocchio | Investigate a protocol or pattern, then design and implement |
| **defi-compose** | researcher → defi-engineer → qa | DeFi integration |
| **token-launch** | token-engineer → frontend → qa | Token creation + launch UI |

### MCP Server Integrations

On by default in `.mcp.json` (API keys go in `.env`). Claude Code asks once per project before it starts them, so approve the ones you want:

| Server | Capabilities |
|--------|-------------|
| **Helius** | RPC, DAS API, parsed transactions, webhooks, priority fees, token and NFT data |
| **solana-dev** | Solana Foundation official MCP (remote HTTP): Solana docs, guides, and API references |
| **Context7** | Up-to-date library documentation lookup |

#### Optional MCP servers

These need a browser, a CLI or a workflow choice, so they are not started by default. Add one for yourself with `claude mcp add` (add `--scope project` to share it through `.mcp.json`):

| Server | Add with | Needs |
|--------|----------|-------|
| **Playwright**: browser automation for dApp testing | `claude mcp add playwright -- npx -y @playwright/mcp@latest --headless` | A browser Playwright can launch |
| **Surfpool**: local validator / mainnet-fork control | `claude mcp add surfpool -- surfpool mcp` | The `surfpool` CLI (`brew install txtx/taps/surfpool`) |
| **context-mode**: keeps large tool output out of context | `claude mcp add context-mode -- npx -y context-mode@latest` | Nothing |

The kit used to list `memsearch` too, but its `memsearch-mcp` package is not published on npm, so it never started. For persistent memory, Zilliz ships memsearch as a plugin: `/plugin marketplace add zilliztech/memsearch`, then `/plugin install memsearch`.

#### Settings the kit leaves to you

`.claude/settings.json` ships the sandbox, permission rules, hooks and attribution, and nothing that pins how Claude works. Turn these on yourself with the command shown or in `.claude/settings.local.json`, which `/update` never touches:

- **Effort**: `/effort` (the kit no longer forces `max`)
- **Agent teams**: `{"env": {"CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"}}`, see [Agent Teams](#agent-teams)
- **Code intelligence**: install the language server, then `/plugin install rust-analyzer-lsp@claude-plugins-official` (or `typescript-lsp`, `csharp-lsp`). Claude Code offers the matching plugin once the server is on your `PATH`
- **MCP auto-approval**: `"enableAllProjectMcpServers": true` skips the approval prompt for every server in `.mcp.json`

`/update` removes these keys and the retired MCP servers from files written by kit 2.1.0 or earlier, but only where they still hold the kit's value.

### Token-Efficient Design

- CLAUDE.md is delivered as a user message (not system prompt) — shorter = better adherence
- Skills load progressively (not all at once)
- Agents reference skills instead of duplicating content
- No always-loaded rules: Claude Code reads only `paths:` from a rule file and loads anything else every session, so the kit ships no rules and `validate.sh` fails on an unscoped one
- Agent and command descriptions are listed in every session, so they stay one or two sentences
- `CLAUDE.local.md` for private scratch notes (gitignored, never shared)
- Subdirectory CLAUDE.md files lazy-load in monorepos
- Decision frameworks live in agents, not global context

### Modern Stack (2026)

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

## Extended Skills & Add-on Registry

Beyond the bundled submodules above, the kit ships a curated catalog of **opt-in** skills, plugins, and MCPs that are **not installed by default** — the agent installs them only on your request, at your own expense. The set is deduped against [solana-new's](https://github.com/sendaifun/solana-new) vendored ecosystem catalogs so it surfaces net-new, high-signal picks rather than restating what's already reachable.

Featured add-ons by domain:

- **Claude-official:** [anthropics/skills](https://github.com/anthropics/skills) · [anthropics/claude-code](https://github.com/anthropics/claude-code) plugins (non-OSI license; overlaps `/diff-review` + `cso`)
- **Dev-workflow:** [wshobson/agents](https://github.com/wshobson/agents) · [gsd-build/get-shit-done](https://github.com/gsd-build/get-shit-done)
- **Frontend/Design:** [zarazhangrui/frontend-slides](https://github.com/zarazhangrui/frontend-slides) · [uxKero/anydesign](https://github.com/uxKero/anydesign) · [dylantarre/animation-principles](https://github.com/dylantarre/animation-principles)
- **UX/Writing:** [content-designer/ux-writing-skill](https://github.com/content-designer/ux-writing-skill) · [cuellarfr/design-skills](https://github.com/cuellarfr/design-skills)
- **Testing:** [SawyerHood/dev-browser](https://github.com/SawyerHood/dev-browser) · [conorluddy/ios-simulator-skill](https://github.com/conorluddy/ios-simulator-skill)
- **Data:** [K-Dense-AI/scientific-agent-skills](https://github.com/K-Dense-AI/scientific-agent-skills) · [Nansen](https://github.com/nansen-ai/nansen-cli) (paid analytics MCP)

**Where we scout** new tools (aggregators, not installable): [ComposioHQ/awesome-claude-skills](https://github.com/ComposioHQ/awesome-claude-skills) · [travisvn/awesome-claude-skills](https://github.com/travisvn/awesome-claude-skills) · [davepoon/buildwithclaude](https://github.com/davepoon/buildwithclaude) · [hesreallyhim/awesome-claude-code](https://github.com/hesreallyhim/awesome-claude-code) · [VoltAgent/awesome-claude-code-subagents](https://github.com/VoltAgent/awesome-claude-code-subagents).

For broader Solana coverage, see solana-new's vendored catalogs at `ext/solana-new/cli/data/` (MCPs, skills, clonable repos).

See [`skill-registry.json`](.claude/skills/skill-registry.json) for the complete extended catalog — every entry with its install command, license, and safety caveats.

## Repository Structure

```
.
├── CLAUDE.md                    # Main hub - Claude reads this first
├── README.md                    # This file
├── .mcp.json                    # MCP server configurations (project root)
├── install.sh                   # One-liner installer
├── update.sh                    # Deprecation wrapper → .claude/bin/update.sh
├── validate.sh                  # Config integrity checker
├── LICENSE                      # MIT
├── tests/                       # Config integrity test suite
├── .github/workflows/
│   ├── ci.yml                       # PR validation
│   └── claude.yml                   # @claude mention responder (issues/PRs)
├── .github/templates/
│   └── claude-code.yml              # Claude Code action template (copy into a project's own workflows/)
└── .claude/
    ├── VERSION                  # Semver version (e.g. 2.1.0)
    ├── agents/                  # 15 specialized agents
    ├── bin/
    │   ├── update.sh                # In-place update from upstream
    │   └── resync.sh                # Submodule resync script
    ├── commands/                # 30 workflow commands
    ├── skills/                  # Progressive-loading knowledge
    │   ├── SKILL.md                 # Unified hub routing to all skills
    │   ├── ext/                     # External skill submodules
    │   │   ├── solana-dev/              # Solana Foundation dev skill (core)
    │   │   ├── sendai/                  # SendAI protocol skills (DeFi)
    │   │   ├── solana-game/             # Solana game skill (Unity, PSG1)
    │   │   ├── cloudflare/              # Cloudflare Workers, Agents SDK
    │   │   ├── trailofbits/             # Trail of Bits security skills
    │   │   ├── qedgen/                # QEDGen formal verification (Lean 4)
    │   │   ├── solana-mobile/           # Mobile Wallet Adapter, Genesis Token
    │   │   ├── colosseum/              # Colosseum Copilot (startup research)
    │   │   ├── safe-solana-builder/   # Security-first code generation
    │   │   ├── vercel/                # Vercel deployment, Next.js, AI SDK
    │   │   ├── solana-new/            # SendAI idea→launch journey skills + datasets
    │   │   ├── ghostsecurity/         # Ghost Security AppSec skills
    │   │   ├── defending-code/        # Anthropic vuln-discovery reference harness
    │   │   ├── jupiter/               # Official Jupiter skills (swap, lend, VRFD)
    │   │   ├── metaplex/              # Official Metaplex (NFT, candy machine)
    │   │   ├── helius/                # Official Helius infra + SVM internals
    │   │   ├── quicknode-anchor/      # Anchor/Quasar reference files (quarantined)
    │   │   └── eth-to-sol/            # EVM/Solidity → Anchor porting
    │   ├── skill-registry.json     # Opt-in add-on catalog (repos/skills/MCPs)
    │   ├── idea-sprint/             # Wrapper: find + validate crypto ideas (GTM)
    │   ├── pitch-deck/              # Wrapper: pitch decks for crypto projects (GTM)
    │   ├── hackathon/               # Wrapper: hackathon submissions + grants (GTM)
    │   ├── token-2022.md            # Token Extensions guide (local)
    │   ├── backend-async.md         # Axum/Tokio patterns (local)
    │   └── deployment.md            # Deployment workflows (local)
    └── settings.json            # Sandbox, permissions, hooks
```

## Agents

| Agent | Purpose | Model |
|-------|---------|-------|
| **solana-architect** | System design, PDA schemes, token economics, multi-program architecture | Inherit |
| **anchor-engineer** | Anchor development, IDL generation, account constraints | Opus |
| **pinocchio-engineer** | CU optimization (80-95% savings), zero-copy, minimal binary | Inherit |
| **defi-engineer** | DeFi integrations: Jupiter, Kamino, Raydium, Orca, Meteora | Opus |
| **token-engineer** | Token-2022 extensions, token economics, launch mechanics | Opus |
| **solana-frontend-engineer** | React/Next.js, wallet UX, transaction flows, accessibility | Sonnet |
| **mobile-engineer** | React Native/Expo, mobile wallet adapter, deep linking | Sonnet |
| **rust-backend-engineer** | Axum APIs, indexers, WebSocket services | Sonnet |
| **devops-engineer** | CI/CD, monitoring, RPC infrastructure, Cloudflare Workers | Sonnet |
| **solana-qa-engineer** | Testing (Mollusk/LiteSVM/Trident), CU profiling, code quality | Opus |
| **tech-docs-writer** | READMEs, API docs, integration guides | Sonnet |
| **game-architect** | Solana game design, Unity architecture, on-chain game state, PlaySolana | Inherit |
| **unity-engineer** | Unity/C# implementation, Solana.Unity-SDK, wallet integration, NFT display | Sonnet |
| **solana-guide** | Learning, tutorials, concept explanations, progressive learning paths | Sonnet |
| **solana-researcher** | Ecosystem research, protocol investigation, SDK analysis | Sonnet |

**Model routing:** `Opus` for deep reasoning where Opus is the right fit; `Sonnet` for implementation-heavy, mechanical, docs or high-volume work; `Inherit` means no `model:` line, so the agent runs on your session model (architecture and unsafe low-level code get the strongest model you run, Fable included). The kit never pins `fable`. Commands inherit your session model too, except `/doctor`, `/setup-mcp`, `/resync`, `/update`, `/cleanup`, `/commit-claude-config` and `/scaffold`, which run on Sonnet for that turn. `CLAUDE_CODE_SUBAGENT_MODEL` in your settings `env` sets the model for `Inherit` agents; add `CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1` to apply it to every agent.

## Commands

### Building
| Command | Purpose |
|---------|---------|
| `/build-program` | Build Anchor or native Solana program |
| `/build-app` | Build Next.js/Vite web client |
| `/build-unity` | Build Unity project (WebGL, Desktop, PSG1) |
| `/scaffold` | Generate project scaffolding (program + frontend + tests + CI) |

### Testing & Quality
| Command | Purpose |
|---------|---------|
| `/test-rust` | Run Mollusk, LiteSVM, Surfpool, Trident tests |
| `/test-ts` | Run TypeScript tests (Anchor, Vitest, Playwright) |
| `/test-dotnet` | Run .NET/C# tests (Unity Test Framework, NUnit) |
| `/test-and-fix` | Run tests and auto-fix common issues |
| `/audit-solana` | Comprehensive security audit |
| `/audit-infra` | Infra-first security audit: secrets, supply chain, CI/CD, LLM/skill security, OWASP, STRIDE |
| `/product-review` | Product quality review — UX walkthrough, 8-dimension scorecard (`--harsh` for the roast variant) |
| `/diff-review` | AI-powered diff review for Solana-specific issues |
| `/profile-cu` | CU profiling per instruction with optimization suggestions |
| `/benchmark` | CU benchmarks with before/after comparison |
| `/debug-user-tx` | Replay a user's failing tx against forked state, map error to source |

### Deployment & Migration
| Command | Purpose |
|---------|---------|
| `/deploy` | Deploy to devnet (always first) or mainnet |
| `/migrate-web3` | Migrate from @solana/web3.js to @solana/kit |
| `/generate-idl-client` | Generate typed clients from IDL (Codama/Shank) |

### Workflow & Setup
| Command | Purpose |
|---------|---------|
| `/quick-commit` | Create branch, format, lint, conventional commit |
| `/commit-claude-config` | Version the kit config in git (un-ignores `.claude/`, `CLAUDE.md`, `.mcp.json`, `.gitmodules`) |
| `/setup-ci-cd` | Configure GitHub Actions pipeline |
| `/setup-mcp` | Configure MCP server API keys and connections |
| `/resync` | Resync external skill submodules to latest |
| `/write-docs` | Generate documentation for programs, APIs, components |
| `/explain-code` | Explain complex code with visual diagrams |
| `/plan-feature` | Plan feature implementation with specifications |
| `/update` | Update config to latest version from upstream |
| `/cleanup` | Initialize forked template — setup CLAUDE.md, remove scaffolding |
| `/doctor` | Health check for dev environment + config — read-only, one fix-it command per failure |
| `/dream` | Memory consolidation — dedupe, prune, re-rank MEMORY.md and Project Learnings |

## DX Scripts

| Script | Purpose |
|--------|---------|
| `install.sh` | One-liner installer: copies config to your project (`--agents` adds the AGENTS.md bridge) |
| `update.sh` | Deprecation wrapper → `.claude/bin/update.sh` |
| `validate.sh` | Validates all config integrity (agents, commands, skills, settings, versioning) |
| `tests/run_all.sh` | Runs full test suite for config validation |

## GitHub Action for Team Collaboration

This config includes a pre-built GitHub Action (`.github/templates/claude-code.yml`) for PR-based iteration:

1. Add `ANTHROPIC_API_KEY` to your repository secrets
2. Copy `.github/templates/claude-code.yml` to `.github/workflows/claude-code.yml` in your project
3. Team members can `@claude` in PR comments
4. Claude responds with code suggestions using this configuration

## Branch Workflow

All new work starts on a feature branch:

```bash
# Format: <type>/<scope>-<description>-<DD-MM-YYYY>
git checkout -b feat/program-vault-15-01-2026
git checkout -b fix/frontend-auth-15-01-2026
```

Use `/quick-commit` to automate branch creation and commits.

## Code Quality

Before merging, run `/diff-review` or check diff against main:

```bash
git diff main...HEAD
```

Remove: excessive comments, abnormal try/catch blocks, verbose errors, redundant validation.

Keep: legitimate security checks, non-obvious explanations, matching error patterns.

## Using as a GitHub Template

1. Click "Use this template" on GitHub (or fork the repo)
2. Clone your new repo
3. Run Claude Code and use `/cleanup` — this copies `CLAUDE-solana.md` → `CLAUDE.md` and removes config repo scaffolding (tests, install scripts, docs)
4. Start building!

For monorepos, add a `CLAUDE.md` to each package/module with architecture decisions scoped to that directory. Claude Code automatically loads these when working in that subdirectory.

## Updating

```bash
# Preferred: use /update in Claude Code, or run directly:
bash .claude/bin/update.sh

# Preview changes without applying:
bash .claude/bin/update.sh --dry-run

# Resync skill submodules only:
bash .claude/bin/resync.sh

# Or manually update submodules
git submodule update --remote --merge
```

## License

MIT - See [LICENSE](LICENSE)
