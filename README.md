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

Working in a fork or clone of this repo? Its top-level CLAUDE.md is for maintaining the kit itself; `/cleanup` swaps in CLAUDE-solana.md (see [Using as a GitHub Template](#using-as-a-github-template)).

## What This Is

A complete `.claude/` configuration that turns Claude into a Solana development expert with:

- **15 specialized agents** for different tasks (architecture, Anchor, Pinocchio, DeFi, tokens, frontend, mobile, backend, DevOps, QA, docs, games, Unity, learning, research)
- **32 workflow commands** for building, testing, deploying, profiling, migrating, and committing
- **3 MCP servers** on by default for on-chain data (Helius), Solana docs (solana-dev) and library docs (Context7), plus opt-in browser automation (Playwright), local-validator / mainnet-fork control (Surfpool) and context optimization (context-mode)
- **Four firewall tiers** (Off / Relaxed / Medium / High, default Relaxed) gating file access, destructive commands and egress — pick one with `/firewall`, see [Firewall tiers](#firewall-tiers)
- **The [safe-ai-skill](https://github.com/solanabr/safe-ai-skill) security firewall** (core): hooks that gate mainnet, value-moving and authority actions and secret reads, and pin installed skills and MCPs at session start
- **Agent teams** (opt-in, experimental) for multi-step workflows (architect → engineer → QA)
- **Progressive skill loading** that only loads context when needed (saves tokens)
- **A small always-on CLAUDE.md** carrying only the program-code house rules and workflow; everything else is on demand

## Quick Start

Pick one way to use the kit. Each code block below holds one command: `bash` blocks run in your terminal, `text` blocks are typed into Claude Code (or, for the no-install prompt, into your agent).

| Way | Use it when |
|-----|-------------|
| [Installer](#installer-recommended) (recommended) | You work in Claude Code and want the full kit in a project |
| [Codex, opencode and other agents](#codex-opencode-and-other-agents) | Your tool reads `AGENTS.md` and `.agents/skills/` instead of Claude Code's files |
| [No install](#no-install-read-the-kit-from-aikitsuperteamcodes) | You want the skills in any agent without adding files to your project |
| [Claude Code plugin](#install-as-a-claude-code-plugin-not-recommended) (not recommended) | Read that section before you use it |

### Installer (recommended)

The installer copies the kit into a project: `.claude/` (agents, commands, skills, a `settings.json` with the permissions, sandbox and hooks, and a `security.json` naming the [firewall tier](#firewall-tiers) those rules came from), `CLAUDE.md`, `.mcp.json` and `.env`. It downloads the kit's latest release tag from GitHub into a temporary directory, which it deletes when done. It installs into the current directory, so go to your project's root first (replace `your-project` with its path):

```bash
cd your-project
```

**Inspect, then run.** Download the installer, read it, then run it:

```bash
curl -fsSL https://aikit.superteam.codes/install.sh -o /tmp/solana-ai-kit-install.sh
```

```bash
less /tmp/solana-ai-kit-install.sh
```

```bash
bash /tmp/solana-ai-kit-install.sh
```

**One-liner.** The same installer without the review step:

```bash
curl -fsSL https://aikit.superteam.codes | bash
```

`aikit.superteam.codes` and `aikit.superteam.codes/install.sh` both redirect to [`install.sh` on `main`](https://raw.githubusercontent.com/solanabr/ai-kit/main/install.sh).

**From a clone.** Use this to pin a release, or to review every file it installs, not just the installer, before it reaches your project. Clone the kit outside your project; to pin a release, add `--branch` with a tag from the [tags page](https://github.com/solanabr/ai-kit/tags), e.g. `--branch v2.1.0`:

```bash
git clone --depth 1 --recurse-submodules --shallow-submodules https://github.com/solanabr/ai-kit.git "$HOME/ai-kit"
```

Then run the clone's installer from your project's root. `SOLANA_AI_KIT_LOCAL_SRC` makes it copy from the clone instead of downloading:

```bash
SOLANA_AI_KIT_LOCAL_SRC="$HOME/ai-kit" bash "$HOME/ai-kit/install.sh"
```

When the installer finishes, start Claude Code in the project:

```bash
claude
```

Starting a new repository from the kit instead? See [Using as a GitHub Template](#using-as-a-github-template).

### Codex, opencode and other agents

Use this when your tool reads `AGENTS.md` and `.agents/skills/` rather than Claude Code's `CLAUDE.md` and `.claude/`, as Codex and opencode do, or when `.claude/` is already taken. Run it from your project's root (replace `your-project` with its path):

```bash
cd your-project
```

```bash
curl -fsSL https://aikit.superteam.codes | bash -s -- --agents
```

`--agents` works with every installer variant above, e.g. `bash /tmp/solana-ai-kit-install.sh --agents`. It installs everything into `.agents/` instead of `.claude/`, with the instructions in `AGENTS.md` instead of `CLAUDE.md`, and the installed files point at `.agents/` paths. `.agents/agents/`, `.agents/commands/` and `.mcp.json` keep Claude Code's format, so other tools can use them as prompts or context. To update an `--agents` install, run this from your project's root:

```bash
bash .agents/bin/update.sh
```

### No install: read the kit from aikit.superteam.codes

Use this when you want the kit's guidance in any agent (Claude Code, Codex, Grok Build, Cursor, …) without adding files to your project. [aikit.superteam.codes](https://aikit.superteam.codes) serves this repository's files, the `ext/` skill packs included, at `https://aikit.superteam.codes/<path>` (the bare domain and `/install.sh` redirect to the installer instead). Start from these:

| What | URL |
|------|-----|
| Project instructions (what the installer writes to `CLAUDE.md` or `AGENTS.md`) | https://aikit.superteam.codes/CLAUDE-solana.md |
| Skill hub: routes each Solana task to the file to read | https://aikit.superteam.codes/.claude/skills/SKILL.md |
| Solana Foundation dev skill, the hub's default entry point | https://aikit.superteam.codes/.claude/skills/ext/solana-dev/skills/solana-dev/SKILL.md |
| Security-first code generation rules | https://aikit.superteam.codes/.claude/skills/ext/safe-solana-builder/SKILL.md |
| An agent or command as a reference prompt (any file in `.claude/agents/` or `.claude/commands/`) | https://aikit.superteam.codes/.claude/agents/anchor-engineer.md |

Paste this into your agent at the start of a session:

```text
Use the Solana AI Kit from https://aikit.superteam.codes for this session, without installing it.
1. Fetch https://aikit.superteam.codes/CLAUDE-solana.md and follow it as project instructions. Skip its HTML comments; they are maintainer notes.
2. Fetch files verbatim (for example with curl -fsSL), not through a tool that summarizes pages.
3. The kit names files by repository path, such as .claude/skills/SKILL.md. Fetch those from https://aikit.superteam.codes/<path>, and resolve relative links against the URL of the file that contains them.
4. Before Solana work, fetch https://aikit.superteam.codes/.claude/skills/SKILL.md and read only the files it routes the task to. The site has no folder listings: for a link that ends in /, fetch SKILL.md in that folder, or README.md if there is none.
5. Commands the kit names, such as /diff-review, are not installed: fetch .claude/commands/<name>.md from the site and follow it instead.
6. Skip install steps in these files (install.sh, skills.sh add, /add-skill): every linked file is already on the site.
```

Trade-offs:

- **Not pinned.** The site deploys this repository's `main` branch, so a file can change between two sessions. Pinned copies of the kit's own files are on GitHub at a release tag, e.g. https://raw.githubusercontent.com/solanabr/ai-kit/v2.1.0/CLAUDE-solana.md. That host doesn't serve the `ext/` packs (they are git submodules), so a pinned pack file comes from the pack's own repository, at the commit the kit pins.
- **A trust decision.** What the agent fetches becomes instructions it follows. Point it only at a host you trust, and read the files you rely on as you would a dependency.
- **Instructions only.** Nothing registers agents or commands, runs hooks (such as the mainnet-deploy gate), configures MCP servers or applies the permission and sandbox policy. The agent needs a web-fetch tool or network access for `curl` (Codex, for example, asks before it uses the internet), and every file costs a fetch.

### Config is gitignored by default

To keep your project clean, the installer adds `.claude/`, `CLAUDE.md`, `.mcp.json`, and `.gitmodules` to `.gitignore` — the kit reads as ignorable infrastructure, not your app code (the `ext/` skill packs are ignored too; `bash .claude/bin/update.sh` re-fetches the core packs and the project's extensions).

Want the config tracked in git (team setup, reproducible config)? Run `/commit-claude-config` — it un-ignores those files and commits them (or edit `.gitignore` by hand). If your project already commits `.claude/` or its own `.gitmodules`, the new ignore lines are a no-op — git keeps tracking files it already tracks.

### Security firewall: safe-ai-skill

[safe-ai-skill](https://github.com/solanabr/safe-ai-skill) is a core part of the kit. It is a Claude Code plugin whose hooks gate mainnet, value-moving and authority actions, block reads of keypairs and `.env`, and pin installed skills and MCPs at session start. The kit's `stbr` marketplace lists it next to the kit plugin, pinned to a specific commit.

- **Plugin install:** `solana-ai-kit@stbr` depends on `safe-ai-skill@stbr`, so installing the kit installs it.
- **Full install:** `.claude/settings.json` registers the `stbr` marketplace and enables `safe-ai-skill@stbr`. After you trust the folder, Claude Code reports the plugin as enabled but not installed until you run `claude plugin install safe-ai-skill@stbr --scope project` once.
- **`--agents` install (Codex, opencode):** the hooks are Claude Code only. Vet add-ons with the CLI instead: `npx @stbr/safe-ai-skill add skill|mcp <source>`.

Its engine ships prebuilt for macOS and Linux (x64, arm64) and fails closed elsewhere, such as native Windows. To turn it off for yourself in a full install, set `"safe-ai-skill@stbr": false` under `enabledPlugins` in `.claude/settings.local.json`.

### MCP Setup (Optional)

After installation, configure the MCP servers from inside Claude Code in your project:

```text
/setup-mcp
```

This guides you through the Helius API key and offers the [optional MCP servers](#optional-mcp-servers).

## Install as a Claude Code plugin (not recommended)

We recommend against installing the kit, or anything else, from a plugin marketplace. A plugin runs with your user permissions: its hooks run shell commands and its stdio MCP servers run as local processes, both outside Claude Code's sandbox, and it can add executables to the PATH of Claude's shell and instructions to Claude's context. A marketplace fetches all of it from a remote repository, and with auto-update on, a plugin changes on disk after you reviewed it. Every marketplace you add is one more publisher, and one more account that can be compromised, able to ship code to your machine. The [installer](#installer-recommended) ships hooks too, but as plain files in your project that you can read and that change only when you run `/update`.

The full install uses this mechanism for one plugin, [safe-ai-skill](#security-firewall-safe-ai-skill): its `.claude/settings.json` registers this repository's `stbr` marketplace (default branch, not pinned) for the project and enables `safe-ai-skill@stbr`. Claude Code registers the marketplace only after you trust the folder, and fetches the plugin only when you run `claude plugin install safe-ai-skill@stbr --scope project`, at the commit the marketplace pins.

If you use the plugin anyway, keep the exposure small:

1. Add the marketplace pinned to a release tag instead of the default branch. Replace `v2.1.0` with the newest tag on the [tags page](https://github.com/solanabr/ai-kit/tags):

   ```text
   /plugin marketplace add solanabr/ai-kit#v2.1.0
   ```

2. Read what it runs, at that tag: the hooks in [`plugin/hooks/hooks.json`](plugin/hooks/hooks.json) and the MCP servers in [`.mcp.json`](.mcp.json).
3. Install it for one project and only for you (local scope, recorded in that project's `.claude/settings.local.json`). Run it from the project's root (replace `your-project` with its path):

   ```bash
   cd your-project
   ```

   ```bash
   claude plugin install solana-ai-kit@stbr --scope local
   ```

4. List the hooks, MCP servers, agents and commands that were installed:

   ```bash
   claude plugin details solana-ai-kit
   ```

5. Keep auto-update off. It is off by default for third-party marketplaces such as `stbr`, and `/plugin` → **Marketplaces** → `stbr` shows the toggle. Update on purpose, after reading what changed upstream:

   ```bash
   claude plugin marketplace update stbr
   ```

   ```bash
   claude plugin update solana-ai-kit@stbr --scope local
   ```

The plugin ships the **core kit**: the 15 agents, 32 commands (`/firewall` included, though a plugin install has no tier for it to set — see below), the local go-to-market + registry skills (idea-sprint, pitch-deck, hackathon), the token-extensions skill, the 3 default MCP servers, and the hooks (session banner, secrets gate, approval for on-chain writes; see [Permissions and Safety Gates](#permissions-and-safety-gates)). Installing it also installs safe-ai-skill, which it declares as a dependency. Commands and skills are namespaced — `/deploy` becomes `/solana-ai-kit:deploy`.

What the plugin **cannot** carry (Claude Code plugins are plain git clones — they can't init submodules or ship a permissions/sandbox policy), so these stay exclusive to the **full install** (`install.sh`):

- the project `CLAUDE.md` with the program-code house rules
- the curated permissions allowlist + sandbox policy — and therefore the [firewall tier](#firewall-tiers): a plugin's `settings` object honors only `agent` and `subagentStatusLine`, so its `permissions` and `sandbox` keys are dropped at load. A plugin install has hooks and no tier
- the `ext/` skill packs: the core packs by default, extensions on demand (protocol, security, infra, ecosystem depth)

For skill-pack depth, use the full install or the [no-install route](#no-install-read-the-kit-from-aikitsuperteamcodes) rather than adding each pack's own marketplace (`sendaifun/skills`, `trailofbits/skills`, …): every marketplace is one more publisher to trust.

Don't enable the plugin and the full install in the same project: both load the same commands, hooks and MCP servers, and `/doctor` warns about it.

## External Skill Submodules

The kit pins every skill pack below as a git submodule, except `anthropic-skills`, which it pins to an upstream commit. **Core** packs install with every full install. **Extensions** are pinned the same way but install on demand, so a project carries only the packs it uses (in `--agents` installs, Codex and opencode load every nested `SKILL.md` they find, so each pack costs context on every request).

| Submodule | Tier | Source | Purpose |
|-----------|------|--------|---------|
| `ext/solana-dev` | Core | [solana-foundation/solana-dev-skill](https://github.com/solana-foundation/solana-dev-skill) | Core Solana development (programs, frontend, testing, security) |
| `ext/safe-solana-builder` | Core | [frankcastleauditor/safe-solana-builder](https://github.com/frankcastleauditor/safe-solana-builder) | Security-first code generation (70+ audit-derived rules) |
| `ext/trailofbits` | Extension | [trailofbits/skills](https://github.com/trailofbits/skills) | Security auditing and vulnerability scanning |
| `ext/ghostsecurity` | Extension | [ghostsecurity/skills](https://github.com/ghostsecurity/skills) | 7 AppSec skills: SAST criteria, SCA, secrets, validation |
| `ext/defending-code` | Extension | [anthropics/defending-code-reference-harness](https://github.com/anthropics/defending-code-reference-harness) | Anthropic vuln-discovery reference harness + 6 skills |
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
| `ext/colosseum` | Extension | [ColosseumOrg/colosseum-copilot](https://github.com/ColosseumOrg/colosseum-copilot) | Startup research, idea validation, hackathon projects |
| `anthropic-skills` (not a submodule) | Extension | [anthropics/skills](https://github.com/anthropics/skills) | Anthropic's Apache-2.0 frontend-design, webapp-testing and mcp-builder as top-level skills any agent loads ([details](#anthropics-skills-in-any-agent)) |

**Installing extensions.** At install time: `bash install.sh --with sendai,jupiter` (`--with all` installs every pack). Later: `/add-skill <id>` or `bash .claude/bin/skills.sh add <id>` (`.agents/bin/` for `--agents` installs); `skills.sh list` shows every pack and when to use it. Agents do the same on their own: each hub row, agent and command line that links into an extension names its install command. `/update` keeps the extensions a project installed (recorded in `.claude/skills/extensions.txt`); installs made before the core/extension split keep every pack.

**Updates.** Dependabot opens one grouped pull request a week that bumps the pins (`.github/dependabot.yml`, with a 7-day cooldown on upstream commits). CI runs `validate.sh` on it, which resolves every `ext/` link in the hub, agents, commands and local skills against the new pins, so a path an upstream pack moved fails the PR instead of a user's session.

**Adding a pack.** `git submodule add <url> .claude/skills/ext/<id>`, then an entry in [`skill-registry.json`](.claude/skills/skill-registry.json) with `tier`, `path`, `triggers` and the install command, a hub route, and a row in the hub's Extensions table; `tests/test_skill_extensions.sh` checks they agree. New packs come in as extensions from official or organization-owned repos with a permissive license and recent activity.

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

`.claude/settings.json` ships the sandbox, permission rules, hooks and attribution, registers the `stbr` marketplace (`extraKnownMarketplaces`) and enables `safe-ai-skill@stbr`, and pins nothing about how Claude works. Its permission and sandbox block is generated from the [firewall tier](#firewall-tiers) and rewritten whole when the tier changes, so edit the tier with `/firewall` rather than the block. Turn these on yourself with the command shown or in `.claude/settings.local.json`, which `/update` never touches:

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

- **Claude-official:** [anthropics/claude-code](https://github.com/anthropics/claude-code) plugins (non-OSI license; overlaps `/diff-review` + `cso`). Anthropic's Apache-2.0 skills are the `anthropic-skills` extension above
- **Dev-workflow:** [wshobson/agents](https://github.com/wshobson/agents) · [gsd-build/get-shit-done](https://github.com/gsd-build/get-shit-done)
- **Frontend/Design:** [zarazhangrui/frontend-slides](https://github.com/zarazhangrui/frontend-slides) · [uxKero/anydesign](https://github.com/uxKero/anydesign) · [dylantarre/animation-principles](https://github.com/dylantarre/animation-principles)
- **UX/Writing:** [content-designer/ux-writing-skill](https://github.com/content-designer/ux-writing-skill) · [cuellarfr/design-skills](https://github.com/cuellarfr/design-skills)
- **Testing:** [SawyerHood/dev-browser](https://github.com/SawyerHood/dev-browser) · [conorluddy/ios-simulator-skill](https://github.com/conorluddy/ios-simulator-skill)
- **Data:** [K-Dense-AI/scientific-agent-skills](https://github.com/K-Dense-AI/scientific-agent-skills) · [Nansen](https://github.com/nansen-ai/nansen-cli) (paid analytics MCP)

**Where we scout** new tools (aggregators, not installable): [ComposioHQ/awesome-claude-skills](https://github.com/ComposioHQ/awesome-claude-skills) · [travisvn/awesome-claude-skills](https://github.com/travisvn/awesome-claude-skills) · [davepoon/buildwithclaude](https://github.com/davepoon/buildwithclaude) · [hesreallyhim/awesome-claude-code](https://github.com/hesreallyhim/awesome-claude-code) · [VoltAgent/awesome-claude-code-subagents](https://github.com/VoltAgent/awesome-claude-code-subagents).

For broader Solana coverage, see solana-new's vendored catalogs at `ext/solana-new/cli/data/` (MCPs, skills, clonable repos; install the solana-new extension first).

See [`skill-registry.json`](.claude/skills/skill-registry.json) for the complete extended catalog — every entry with its install command, license, and safety caveats. The same file records the tier and triggers of each pinned pack above; entries without a tier are these opt-in add-ons.

## Use with Codex, Grok Build and other agents

The kit's skills are [Agent Skills](https://agentskills.io) folders, which most coding agents load. Pick the install by where your agent looks:

| Agent | Install | It reads | Enforces the [firewall tier](#firewall-tiers)? |
|-------|---------|----------|-----------------------------|
| Claude Code | `install.sh` (default) | `CLAUDE.md`, `.claude/` (skills, agents, commands, hooks), `.claude/security.json`, `.mcp.json` | **Yes.** Permission rules, sandbox and hooks all apply, so the tier is what it says it is |
| Claude Code | plugin marketplace | the plugin's agents, commands, skills, `.mcp.json` and `hooks/hooks.json` | **No tier at all.** A plugin's `plugin.json` `settings` object honors only `agent` and `subagentStatusLine`; `permissions` and `sandbox` keys are dropped at load. You get the hooks — the mainnet, secrets and on-chain gates — and nothing else. There is no file fence, no sandbox, no egress denylist |
| Grok Build | default (`--agents` works too) | Claude Code's files, plus `AGENTS.md` and `.agents/skills/`, once you trust the folder (`/hooks-trust` or `grok --trust`) | **Hooks only, and only partly.** It reads `.claude/settings.json` for hooks and maps Claude's tool names, but sends camelCase `toolInput` and is **fail-open on malformed hook output** — a hook written for Claude Code's payload silently permits there. The kit's hooks now read both shapes. Permission rules and the sandbox are Claude Code's and do not apply |
| Codex | `--agents` | `AGENTS.md` and `.agents/skills/` | **No.** Even with hooks wired up, its PreToolUse coverage is `Bash`, `exec_command` and `apply_patch` — there is **no `Read` tool**, so file reads cannot be gated at all. Codex's own docs call hooks "a useful guardrail, not a complete enforcement boundary" |
| Cursor, GitHub Copilot, Gemini CLI, opencode and other Agent Skills clients | `--agents` | `AGENTS.md` and `.agents/skills/` | **No.** Instructions only: no hooks, no permission rules, no sandbox. The house rules are a request, not a boundary |

Grok Build caveats, per the [Grok Build docs](https://docs.x.ai/build/features/project-rules):

- Grok skips instruction files that `.gitignore` lists, and the installer gitignores `CLAUDE.md` (or `AGENTS.md`) by default. Run `/commit-claude-config`, or take the file out of the kit's `.gitignore` block, so Grok loads the house rules. Skills and commands load either way.
- Grok sends [hooks](https://docs.x.ai/build/features/hooks) camelCase JSON (`toolInput`) where Claude Code sends `tool_input`. The kit's hooks read both, so the secret-read, pre-commit and mainnet-deploy gates in `.claude/settings.json` do fire under Grok — but Grok is fail-open on malformed hook output, so a hook that errors permits rather than blocks, and no permission rule or sandbox entry applies at all. The project `CLAUDE.md` still tells agents on other runtimes to get an explicit go-ahead before any mainnet step.

Gemini CLI reads `GEMINI.md` unless you add `AGENTS.md` to `context.fileName` in its `settings.json`.

### Anthropic's skills in any agent

The `anthropic-skills` extension installs three Apache-2.0 skills from [anthropics/skills](https://github.com/anthropics/skills) as top-level skills, so each agent above loads them by description: `frontend-design` (distinctive UI direction), `webapp-testing` (Playwright tests of a local web app) and `mcp-builder` (MCP servers for a program or API). They land in `.claude/skills/<name>/`, or in `.agents/skills/<name>/` with `--agents`:

```bash
bash install.sh --with anthropic-skills /path/to/your-project   # add --agents for Codex and the others
bash .claude/bin/skills.sh add anthropic-skills                  # later (.agents/bin/ with --agents), or /add-skill anthropic-skills
```

`skills.sh` fetches only those three folders, at the commit pinned in [`skill-registry.json`](.claude/skills/skill-registry.json), and copies them unchanged with their `LICENSE.txt`. It refuses the repo's restricted skills whatever the registry lists: `docx`, `pdf`, `pptx` and `xlsx` are proprietary and licensed for use only within Anthropic's services, and `doc-coauthoring` has no license. Claude users get the document skills first-party from Anthropic: they power file creation in the Claude apps, and Claude Code installs them from Anthropic's own marketplace (`/plugin marketplace add anthropics/skills`, then `/plugin install document-skills@anthropic-agent-skills`).

Two of the three run code: `webapp-testing`'s `scripts/with_server.py` starts the server commands it is given through a shell, and `mcp-builder`'s evaluation script calls the Anthropic API with `ANTHROPIC_API_KEY`.

The pin moves by hand, not through Dependabot: review the upstream diff of the three folders, update `commit` in the registry entry, then run `bash tests/test_anthropic_skills.sh`, which re-checks each skill's license and frontmatter at the new commit.

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
├── .github/dependabot.yml       # Weekly grouped PR bumping the ext/ skill pins
├── .github/workflows/
│   ├── ci.yml                       # PR validation
│   ├── claude-code-review.yml       # Automatic Claude review of every PR (advisory)
│   └── claude.yml                   # @claude mention responder (issues/PRs)
├── .github/templates/
│   └── claude-code.yml              # Claude Code action template (copy into a project's own workflows/)
└── .claude/
    ├── VERSION                  # Semver version (e.g. 2.2.0)
    ├── agents/                  # 15 specialized agents
    ├── bin/
    │   ├── update.sh                # In-place update from upstream
    │   ├── resync.sh                # Submodule resync script
    │   ├── firewall.sh              # Generates a tier's permission + sandbox rules
    │   └── skills.sh                # List skill packs, install extensions on demand
    ├── commands/                # 32 workflow commands
    ├── hooks/                   # PreToolUse/SessionStart gate scripts
    ├── skills/                  # Progressive-loading knowledge
    │   ├── SKILL.md                 # Unified hub routing to all skills
    │   ├── ext/                     # External skill submodules (core: installed; others: extensions)
    │   │   ├── solana-dev/              # Solana Foundation dev skill (core)
    │   │   ├── safe-solana-builder/   # Security-first code generation (core)
    │   │   ├── sendai/                  # SendAI protocol skills (DeFi)
    │   │   ├── solana-game/             # Solana game skill (Unity, PSG1)
    │   │   ├── cloudflare/              # Cloudflare Workers, Agents SDK
    │   │   ├── trailofbits/             # Trail of Bits security skills
    │   │   ├── qedgen/                # QEDGen formal verification (Lean 4)
    │   │   ├── solana-mobile/           # Mobile Wallet Adapter, Genesis Token
    │   │   ├── colosseum/              # Colosseum Copilot (startup research)
    │   │   ├── vercel/                # Vercel deployment, Next.js, AI SDK
    │   │   ├── solana-new/            # SendAI idea→launch journey skills + datasets
    │   │   ├── ghostsecurity/         # Ghost Security AppSec skills
    │   │   ├── defending-code/        # Anthropic vuln-discovery reference harness
    │   │   ├── jupiter/               # Official Jupiter skills (swap, lend, VRFD)
    │   │   ├── metaplex/              # Official Metaplex (NFT, candy machine)
    │   │   ├── magicblock/            # Official MagicBlock (Ephemeral Rollups)
    │   │   ├── helius/                # Official Helius infra + SVM internals
    │   │   ├── alchemy/               # Official Alchemy (Solana RPC, DAS, gRPC)
    │   │   ├── quicknode-anchor/      # Anchor/Quasar reference files (quarantined)
    │   │   └── eth-to-sol/            # EVM/Solidity → Anchor porting
    │   ├── skill-registry.json     # Pack tiers (core/extension) + opt-in add-on catalog
    │   ├── idea-sprint/             # Wrapper: find + validate crypto ideas (GTM)
    │   ├── pitch-deck/              # Wrapper: pitch decks for crypto projects (GTM)
    │   ├── hackathon/               # Wrapper: hackathon submissions + grants (GTM)
    │   ├── token-extensions/        # Token-2022 extensions: pick, combine, create (local)
    │   ├── backend-async.md         # Axum/Tokio patterns (local)
    │   └── deployment.md            # Deployment workflows (local)
    ├── security.json            # Firewall tier in force + the exact rules it enforced
    └── settings.json            # Sandbox, permissions, hooks, stbr marketplace + safe-ai-skill@stbr
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
| `/firewall` | Show or switch the firewall tier (Off / Relaxed / Medium / High) |
| `/setup-mcp` | Configure MCP server API keys and connections |
| `/resync` | Resync external skill submodules to latest |
| `/add-skill` | Install a pinned skill extension on demand, or list core packs and extensions |
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
| `install.sh` | One-liner installer: copies config to your project (`--agents` for non-Claude tools, `--with <ids>` for skill extensions) |
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

## Permissions and Safety Gates

Edits and commits run without hooks, formatters or extra prompts. The gates sit around secrets, on-chain writes and destructive commands.

| Gate | Where | What happens |
|------|-------|--------------|
| Firewall tier | `.claude/security.json` names it; `/firewall` writes the matching rules into `.claude/settings.json` | Decides how much of the policy below applies, plus which paths are readable and writable. Default: **Relaxed**. See [Firewall tiers](#firewall-tiers) |
| Private keys, wallet vaults, credentials (`~/.ssh`, `~/.config/solana/id.json`, browser wallet storage, `gh auth token`, ...) | `Read` deny rules (also enforced by the sandbox) + PreToolUse hook | Blocked; the message points to `solana address` or asks the user to run it |
| `--final`, `solana program close --bypass-warning`, `program-v4 finalize`, `spl-token authorize --disable` | deny rules + PreToolUse hook | Blocked; the user runs them |
| Program deploys, upgrades, buffer writes, `extend`, closes and authority changes; `spl-token transfer`/`authorize`; stake and vote withdrawals | `ask` rules + PreToolUse hook | Approval prompt on every cluster, naming the cluster it resolved (flag, `Anchor.toml` or `solana config`) |
| `bash .claude/bin/skills.sh list` and `add <id>` (`.agents/bin/` with `--agents`) | allow rules | No prompt, so an agent can install the extension pack it needs. `add` clones the kit and its submodules over the network and installs the pack; each pack is pinned to a commit (submodule or registry `commit`) that moves only through a reviewed PR. `prune`, `select` and `uninstalled` still prompt |
| `git push --force-with-lease`, `git clean`, `gh pr merge`, `gh issue delete`, `--receive-pack`/`--upload-pack` overrides, `solana-keygen new`/`recover` with `--force` (overwrites `~/.config/solana/id.json` unless `-o` is given) | `ask` rules | Approval prompt |
| `sudo`, `rm -rf` on `/*`, `~*` or `.*`, `dd`, `kill -9`/`pkill`/`killall`, `chmod 777`, `chown`, plain `git push --force`, `git reset --hard`, `solana transfer`, `spl-token burn`/`close`, `docker rm`/`rmi`/`system prune` | deny rules | Blocked |
| Bash sandbox | `sandbox` | On; local ports can bind (validators, dev servers); `git push/pull/fetch` and `gh pr/run/issue` run outside it because SSH and `gh` can't work inside |
| [safe-ai-skill](#security-firewall-safe-ai-skill) | Its own Claude Code hooks | Gates secrets and mainnet actions too, so some commands pass two checks. It also blocks `.env` reads, which `/setup-mcp` relies on |

The prompts in that table come from the PreToolUse hooks. The matching `permissions.ask` entries are belt-and-braces, not the control: in a sandboxed session a Bash command matching an `ask` rule was observed to run with no prompt, while a `deny` rule on the same command blocked it. Whether `ask` prompts in default (non-bypass) mode with the sandbox off is untested, so the kit does not rest any gate — or any tier distinction — on `permissions.ask`. Hard blocks are a `deny` rule or a hook `exit 2`; both were observed to hold.

Plugin installs get the hooks only; the permission rules and sandbox come with `install.sh`. `/update` re-applies the tier's rules on every run, replacing only the rules the kit itself wrote — so existing installs do pick these up, and rules you added yourself survive.

### Firewall tiers

One tier is in force per project. `.claude/security.json` names it; `/firewall` (or `/firewall <tier>`) switches it and rewrites the kit-owned rules in `.claude/settings.json` to match. The default is **Relaxed**. A switch takes effect in the **next** session: permission and sandbox rules are read once at session start, so the session you are in keeps the rules it started with, whether the change was a tightening or a loosening.

| Tier | Readable | Writable | On-chain | Use it for |
|------|----------|----------|----------|------------|
| **Off** | Everything your user account can read. The sandbox is off. | Everything. | The hooks still run: mainnet and authority writes stop for approval, irreversible ones are refused. | A machine you have already isolated — a container or throwaway VM — or a session where you supply your own policy in `~/.claude/settings.json`. |
| **Relaxed** (default) | Leaves open: your Solana config dir (so `solana config get` and `anchor`'s `wallet =` keep working), the project's `.env`, and host credential files outside the never-allowed set — cloud, registry and git-host tokens such as `~/.aws`, `~/.netrc`, `~/.git-credentials`, `~/.npmrc` and the `gh` host file. Denies the never-allowed set: SSH and GPG keys, keychains and keyrings, browser profiles and wallet extension stores, shell startup files, shell and REPL history, `~/.cargo/config.toml` and `~/.cargo/credentials*`, `~/.gitconfig`. | The repo, the platform temp dir, the toolchain caches (`~/.cargo`, `~/.rustup`, `~/.avm`, the Solana caches) and the project's `.env`. Writes outside the repo are allowed. | Mainnet writes stop for your approval on every cluster, naming the cluster it resolved. `--final`, program close and `spl-token authorize --disable` are refused outright. `npm`/`cargo publish` ask. | **Local development.** Your own machine and your own repo, where the toolchain should just work. Also the tier to run headless — see below. |
| **Medium** | Relaxed's denials, plus the Solana config dir's `*.json` (the wallet files; `cli/config.yml` stays readable), session transcript `*.jsonl`, and the host credential files Relaxed leaves open. | The repo and the toolchain carve-outs. Writes outside the repo ask. The project's `.env` becomes **write-deny** — nothing in a Solana build legitimately rewrites it, and an ask there is walked around by `python3 -c`, `perl -pi` or `sed -i`. | As Relaxed, plus `npm`/`cargo publish` and `gh api` denied, and force push asks. | Reading code you did not write — audits, dependency triage, a repo you cloned to look at. Interactive sessions only. |
| **High** | Only the working directory and the toolchain roots the build needs. `permissions.blockReadsOutsideWorkingDirectories` is on and the sandbox denies `~/` with a narrow `allowRead` carve-out for `~/.cargo`, `~/.rustup` and the Solana caches. The project's `.env` becomes read-deny. | The repo plus those toolchain roots (cargo needs *write* to the registry cache or the build dies); everything else outside the repo is denied. The project's `.env` stays writable, since the model can no longer read it back. | Mainnet writes are denied outright rather than asked. Recoverable git operations ask. | A repo you actively distrust, or a session on a machine that holds production credentials. Interactive sessions only. |

`permissions.deny` is identical at every tier — the never-allowed set above, plus the destructive-command rules in the table before this one, plus the kit's own settings files. Deny is the one axis where every tier agrees, which is why merging it across settings sources is harmless. Everything that varies between tiers lives in `sandbox.filesystem`, in two scalars (`permissions.blockReadsOutsideWorkingDirectories` and `sandbox.enabled`), and in the hooks.

The rest of this section is what the tiers do **not** do. It is here because a security feature that is oversold is worse than one that is understood.

**Tiers are regenerated, not layered.** Claude Code merges permission lists across every settings file it loads, and a `deny` from any scope wins: there is no un-deny and no un-ask. So Relaxed cannot be expressed as High plus exceptions — a layered design collapses to the strictest rule any layer ever wrote, permanently, for the life of the file. `/firewall` and `/update` therefore rewrite the whole kit-owned block rather than appending to it, tracked by the exact rule strings recorded in `.claude/security.json` under `enforced.ruleIds`. A rule you added yourself is not in that list, so the rewrite leaves it alone.

**`.claude/settings.local.json` can only make a tier stricter — with exactly two exceptions.** Because lists merge and deny wins, anything you add in a local file tightens the policy. Two keys are not lists, and these two do loosen it: `sandbox.filesystem.allowRead` re-opens a narrower path inside a denied region (narrowness decides, not source order — this is the only genuine carve-out in the system, and it is how the tiers express themselves); and `sandbox.enabled: false` turns the OS layer off, which a `false` in your own `~/.claude/settings.json` can also do to a project's `true`. That is the whole surface. Nothing else in a local file weakens a tier.

`permissions.blockReadsOutsideWorkingDirectories` is **not** one of them, despite looking like it should be: a `true` in *any* settings source wins, so a local `false` cannot undo High's read fence. It is a one-way ratchet — a repository can turn the fence on for itself and cannot turn yours off, and you cannot turn a project's off either. Turning High's fence off means moving off High.

**What High's read fence actually covers, in three layers.** The file tools — Read, Grep, Glob and LSP — refuse an outside path in every permission mode. Bash refuses one too when the shell parser can resolve the path, and **escalates to a prompt** when it cannot: an inline interpreter (`python3 -c`, `node -e`, `bash -c`, `osascript -e`, …) or a path computed at runtime is unanalysable, so it asks rather than guessing, which in `claude -p` is a refusal. The third layer is the sandbox's own `denyRead` over `/Users/`, `/home/` and `/Volumes/`, and it is the only one of the three that sandbox state changes — turn the sandbox off and the file tools still refuse.

**The tier is not immune to the agent.** The kit denies `Edit` on `.claude/settings.json`, `.claude/settings.local.json`, `.claude/security.json`, `.claude/hooks/**` and `.mcp.json`, and those denies hold under `bypassPermissions`, where protected-path writes are otherwise allowed and allow rules no longer pre-approve them — an explicit deny is the only thing left that stops the agent rewriting its own tier. A Bash arm covers rewriting the same files from the shell, and `Bash(claude …)` is denied because a nested `claude -p --dangerously-skip-permissions` re-rolls the whole policy in a child process. But a hook matcher is a regex, and `.claude/` is a path Claude Code only *prompts* about — and auto-approves under `bypassPermissions`. The only tier an agent cannot talk its way out of lives in root-owned managed settings (`/Library/Application Support/ClaudeCode/managed-settings.json` and its `.d` directory), which needs root and which the kit will not install for you. What the kit does instead is **detect**: the SessionStart hook compares the tier declared in `.claude/security.json` against what `.claude/settings.json` actually enforces, and `/doctor`'s check 9 fails on a mismatch. Residuals nothing can close from inside a project: `--settings`, `--permission-mode`, `--setting-sources` (excluding a source drops its deny rules *and* its sandbox entries) and `CLAUDE_CONFIG_DIR`.

**What Relaxed actually guarantees** is "your secrets won't additionally reach a third party" — not confidentiality. Relaxed deliberately leaves the project's `.env` readable; that is a product decision, not an oversight. Once a value is read it is in the transcript and has been sent to the model provider. The tier narrows what can happen to that value next; it does not keep it from the model. If you need that, use Medium or High, or keep the secret somewhere the session cannot read.

**High is interactive-only; Relaxed is the tier for CI.** High expresses its gates as prompts, and under `claude -p` a prompt is a hard failure, not a pause — a High session in a pipeline fails on the first gated command. Medium's hook-asks behave the same way. This is by design, and it is documented here so you meet it in a README rather than in a red pipeline. Relaxed is CI-safe by design: it emits no `ask` rules at all, and the kit's hooks return no decision when there is no interactive user — except for an irreversible set (mainnet writes and `--final`), which **deny** headless unless an explicit environment confirmation is set. Where a higher tier gates an irreversible action, that refusal holds headless too, so a pipeline on Medium cannot publish unprompted. Run CI on Relaxed or Off. The kit's own `.github/workflows/claude.yml` runs inside this repository and therefore runs Relaxed.

**Egress: what the kit can enforce, and what it cannot.** A `sandbox.network.deniedDomains` list is honored in every mode, so the known-exfil denylist the kit ships — request bins, tunnel services, paste sites, file drops — does work. An `allowedDomains` allowlist is a different matter: from project scope it only *prompts* in default mode, and under `bypassPermissions` it is inert entirely. `strictAllowlist` would make it deterministic, but it is honored only from user, managed, or `--settings` scope — project settings are ignored, verified against the 2.1.267 binary and the published documentation. So an allowlist is not something the kit can enforce from the files it writes.  `strictAllowlist` is a line *you* add to your own `~/.claude/settings.json`; the kit does not install it, and cannot install it on your behalf. Three primitives survive any destination layer anyway, because their destination is legitimately allowlisted: `npm publish`, `cargo publish`, and `git push` to a remote that was just added. Publishing is gated by tier in a hook rather than by a permission rule — Relaxed allows it, Medium and High refuse it — because a `deny` rule cannot vary between tiers, so denying it anywhere would deny it at Relaxed too. Data-carrying `curl`/`wget` is gated by a hook anchored to argument position rather than by a glob: Relaxed gates the `@file` and `--upload-file` forms only, because an ask on `curl -d` would fire on `curl -X POST -d '{"jsonrpc":"2.0",...}' https://api.devnet.solana.com`, the most common `curl` in Solana development; inline bodies become ask at Medium and deny at High.

**MCP is ungateable, at every tier.** A permission rule for an MCP tool is tool-name-only: there is no path or argument specifier, so you can allow or deny a whole tool but never "that tool, to these hosts". Local MCP servers run as your user, outside the sandbox, with your full access. So attaching a server that is an arbitrary HTTP client (`playwright`'s `browser_network_request`) or an arbitrary executor (`context-mode`'s `ctx_execute` runs commands outside the Bash tool, hence outside every rule and every hook) removes the egress guarantee whatever tier you are on. The mitigating fact is the default set: only `helius`, `solana-dev` and `context7` ship on, Claude Code asks once per project before starting even those, and the two servers that would do this — Playwright and context-mode — are [opt-in](#optional-mcp-servers).

## Code Quality

Before merging, run `/diff-review` or check diff against main:

```bash
git diff main...HEAD
```

Remove: excessive comments, abnormal try/catch blocks, verbose errors, redundant validation.

Keep: legitimate security checks, non-obvious explanations, matching error patterns.

## Using as a GitHub Template

1. Click "Use this template" on GitHub (or fork the repo).
2. Clone your new repository with its skill submodules (replace `your-name/your-project` with its GitHub path):

   ```bash
   git clone --recurse-submodules https://github.com/your-name/your-project.git
   ```

3. Start Claude Code in the clone:

   ```bash
   cd your-project
   ```

   ```bash
   claude
   ```

4. Run `/cleanup`. It copies `CLAUDE-solana.md` → `CLAUDE.md` and removes config repo scaffolding (tests, install scripts, docs):

   ```text
   /cleanup
   ```

5. Start building!

For monorepos, add a `CLAUDE.md` to each package/module with architecture decisions scoped to that directory. Claude Code automatically loads these when working in that subdirectory.

## Updating

Run these from your project's root (replace `your-project` with its path); in `--agents` installs, use `.agents/bin/` instead of `.claude/bin/`. Inside Claude Code, `/update` runs the same update.

```bash
cd your-project
```

Update the kit in place. It pulls the kit's `main` branch and keeps your `.env` and `CLAUDE.md`; when the kit's `CLAUDE.md` differs from yours, it writes the kit's version to `CLAUDE.md.upstream` for you to merge:

```bash
bash .claude/bin/update.sh
```

Preview the update without writing anything:

```bash
bash .claude/bin/update.sh --dry-run
```

List the skill packs, then install an extension by its id (`sendai` here; `/add-skill <id>` does the same inside Claude Code):

```bash
bash .claude/bin/skills.sh list
```

```bash
bash .claude/bin/skills.sh add sendai
```

Check that every link in the skill hub resolves:

```bash
bash .claude/bin/resync.sh
```

In a fork of this repository, where the `ext/` packs are git submodules, `resync.sh` also moves them to their latest upstream commits. An installed project holds plain copies of the packs, so there `update.sh` is what refreshes them.

## License

MIT - See [LICENSE](LICENSE)
