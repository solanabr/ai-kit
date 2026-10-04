# Quick Start: Use This Config in 2 Minutes

## TL;DR

Each code block holds one command. The installer installs into the current directory, so go to your project's root first (replace `your-project` with its path):

```bash
cd your-project
```

Download the installer, read it, then run it:

```bash
curl -fsSL https://aikit.superteam.codes/install.sh -o /tmp/solana-ai-kit-install.sh
```

```bash
less /tmp/solana-ai-kit-install.sh
```

```bash
bash /tmp/solana-ai-kit-install.sh
```

Or run the same installer in one line, without the review step:

```bash
curl -fsSL https://aikit.superteam.codes | bash
```

Then start Claude Code:

```bash
claude
```

That's it. Claude now has Solana superpowers.

> The installer gitignores the kit (`.claude/`, `CLAUDE.md`, `.mcp.json`, `.gitmodules`, `.safe-ai-skill/`) by default to keep your repo clean. To version it instead (team setup), run `/commit-claude-config`.

> A full install starts on the **Relaxed** firewall tier, meant for local development: it blocks SSH and GPG keys, keychains, browser profiles, shell startup files and history, and it deliberately leaves your Solana config dir and the project's `.env` readable so the toolchain works. `/firewall` switches tier; [README → Firewall tiers](README.md#firewall-tiers) has the full matrix and [docs/firewall.md](docs/firewall.md) the limits.

> The kit's security firewall, [safe-ai-skill](https://github.com/solanabr/safe-ai-skill), is a Claude Code plugin that `.claude/settings.json` enables. After you trust the folder, install it once with `claude plugin install safe-ai-skill@stbr --scope project`. The README's "Security firewall: safe-ai-skill" section covers what it gates and how to opt out.

---

## Other ways to use the kit

- **Codex, opencode and other agents that read `AGENTS.md`:** install into `.agents/` instead, from your project's root:

  ```bash
  cd your-project
  ```

  ```bash
  curl -fsSL https://aikit.superteam.codes | bash -s -- --agents
  ```

- **Pin a release or review every file first:** clone the kit and run the installer from the clone, as in [docs/install.md → From a clone](docs/install.md#from-a-clone).
- **No install:** point any agent that can fetch URLs at https://aikit.superteam.codes/CLAUDE-solana.md and the skill hub at https://aikit.superteam.codes/.claude/skills/SKILL.md. [docs/install.md → No install](docs/install.md#no-install-read-the-kit-from-aikitsuperteamcodes) has a copy-paste prompt and the trade-offs.
- **Claude Code plugin marketplace: not recommended.** A plugin runs hooks and MCP servers with your user permissions and can update from a remote repository, so every marketplace you add widens your supply-chain attack surface. If you use it anyway, [docs/plugin.md](docs/plugin.md) shows how to pin a release, install at local scope and keep auto-update off.

---

## Optional: Configure MCP Servers

On by default (Claude Code asks once before it starts them):
- **Helius** — On-chain data, DAS API, webhooks (needs API key from helius.dev)
- **solana-dev** — Solana Foundation official docs and API references (no key needed)
- **Context7** — Library documentation lookup (no key needed)
- **context-mode** — Keeps large tool output out of the context window (no key needed; Node 22.5+)

Opt-in, because each needs a browser, a CLI, a key or a workflow choice. Run `/setup-mcp` to set the Helius key and add any of these:
- **Playwright** — Browser automation for dApp testing
- **Surfpool** — Agent-driven local validator / mainnet-fork control (requires the `surfpool` CLI)
- **Chainstack** — Multi-chain RPC platform control (needs a key for most tools; 5 read-only ones answer without)
- **Nansen** — Wallet and token intelligence (paid key required, free tier within credits; ~50 tool schemas per session)
- **Supabase** — The Postgres backend behind an indexer or dApp. Add it in the hardened form only: `?read_only=true&project_ref=<ref>`. Unflagged it hands over 12 write tools, `execute_sql` among them — an unrestricted SQL channel into your database
- **Cloudflare** — Operate the Workers, KV, R2, D1, DNS and Queues behind a dApp. Three tools for the whole Cloudflare API, and one of them, `execute`, reaches every one of its 2,594 endpoints — so scope the API token to the specific zone or account resources you want reachable

Documented but deliberately not offered by `/setup-mcp`: **Phantom** (`claude mcp add phantom -- npx -y @phantom/mcp-server`) is a 29-tool wallet and trading surface — signing, transfers, payments and perps — that needs no key once logged in. Add it only if you want Claude able to move your funds.

The kit pins no effort level, agent teams or LSP plugins; [docs/configuration.md](docs/configuration.md#settings-the-kit-leaves-to-you) shows how to turn them on.

---

## What You Get

### 15 Specialized Agents

| Agent | Use For |
|-------|---------|
| **solana-architect** | System design, account structures, PDAs |
| **anchor-engineer** | Anchor program development |
| **pinocchio-engineer** | CU-optimized native programs |
| **defi-engineer** | DeFi integrations (Jupiter, Kamino, etc.) |
| **token-engineer** | Token-2022 extensions, token launches |
| **solana-frontend-engineer** | React/Next.js dApp frontends |
| **mobile-engineer** | React Native/Expo mobile dApps |
| **rust-backend-engineer** | Rust backend services |
| **devops-engineer** | CI/CD, monitoring, infrastructure |
| **solana-qa-engineer** | Testing, fuzzing, security |
| **tech-docs-writer** | Documentation |
| **game-architect** | Solana game design, concept docs |
| **unity-engineer** | Unity/C# with Solana.Unity-SDK |
| **solana-guide** | Learning and tutorials |
| **solana-researcher** | Ecosystem research |

Each agent runs on Opus, Sonnet, or your own session model (never a pinned Fable). See [docs/agents-and-commands.md → Agents](docs/agents-and-commands.md#agents) for the routing.

### 32 Slash Commands

**Building:**
- `/build-program` - Build Anchor or native programs
- `/build-app` - Build web client
- `/build-unity` - Build Unity projects (WebGL, PSG1)
- `/scaffold` - Generate project scaffolding

**Testing & Quality:**
- `/test-rust` - Run Rust tests
- `/test-ts` - Run TypeScript tests
- `/test-dotnet` - Run .NET/Unity tests
- `/test-and-fix` - Run tests and auto-fix issues
- `/audit-solana` - Security audit
- `/audit-infra` - Infra-first security audit (secrets, supply chain, CI/CD, LLM security)
- `/product-review` - Product quality review with scorecard (`--harsh` to roast)
- `/diff-review` - AI-powered diff review
- `/profile-cu` - CU profiling per instruction
- `/benchmark` - CU benchmarks before/after
- `/debug-user-tx` - Replay failing user tx, map error to source

**Deployment & Migration:**
- `/deploy` - Deploy to devnet/mainnet
- `/migrate-web3` - Migrate web3.js → @solana/kit
- `/generate-idl-client` - Generate typed clients from IDL

**Workflow & Setup:**
- `/quick-commit` - Format, lint, and commit
- `/commit-claude-config` - Version the kit config in git (un-ignore + commit)
- `/setup-ci-cd` - Setup CI/CD pipeline
- `/firewall` - Show or switch the firewall tier (Off / Relaxed / Medium / High)
- `/setup-mcp` - Configure MCP servers
- `/resync` - Resync external skill submodules
- `/add-skill` - Install a pinned skill extension on demand, or list them
- `/write-docs` - Generate documentation
- `/explain-code` - Explain complex code
- `/plan-feature` - Plan feature implementation
- `/update` - Update config to latest upstream
- `/cleanup` - Initialize forked template, remove scaffolding
- `/doctor` - Health check for environment + config, one fix-it command per failure
- `/dream` - Consolidate memory: dedupe, prune, re-rank learnings

### Agent Teams

Agent teams are experimental and off by default. Opt in with `{"env": {"CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"}}` in `.claude/settings.local.json`, then create multi-agent workflows:
```
"Create an agent team: solana-architect for design, anchor-engineer for code, solana-qa-engineer for tests"
```

### Small Always-On Context

Only `CLAUDE.md` (program-code house rules and workflow) and one-line agent/command descriptions load every session. The kit ships no `.claude/rules/`; add your own project rules there with `paths:` frontmatter so they load only for matching files.

### Progressive Skills

Knowledge loads on-demand:
- Solana fundamentals
- Anchor patterns
- Token-2022 extensions
- DeFi protocol integrations
- Unity SDK patterns
- PlaySolana/PSG1 integration
- Security auditing

Only the core skill packs (solana-dev, auditor-skill, colosseum, anthropic-skills) install by default. `colosseum` needs one sign-in per machine before it can answer anything: `npx @colosseum-org/copilot-connect login` (Node 20+); `/doctor` reports whether that is in place. `anthropic-skills` adds Anthropic's Apache-2.0 frontend-design and webapp-testing as top-level skills in `.claude/skills/<name>/`, which Codex, Grok Build and other agents load too ([docs/other-agents.md](docs/other-agents.md)). It is the one pack that costs you context just by being installed: top-level skills are listed at session start, so budget **~102 tokens per session** for its two descriptions. The three `ext/` core packs cost nothing standing, because Claude Code does not auto-discover `.claude/skills/ext/`. The rest of `.claude/skills/ext/` are extensions the kit pins and installs on demand: `bash install.sh --with <ids>` at install time, or `/add-skill <id>` later. The hub gives each one's install command, and agents run it when a task needs the pack.

Need a capability the kit doesn't bundle? See [`.claude/skills/skill-registry.json`](.claude/skills/skill-registry.json) — a curated catalog of opt-in skills/MCPs/repos the agent can install on request, at your own expense (not bundled by default).

---

## Supported Tech Stack

### Programs
- **Anchor** - Rapid development with macros
- **Pinocchio** - Maximum CU optimization
- **Native Rust** - Full control

### Clients
- **TypeScript** - @solana/kit, Anchor client
- **Rust** - solana-sdk, anchor-client
- **C#/Unity** - Solana.Unity-SDK

### Testing
- **Bankrun** - Fast TypeScript testing
- **LiteSVM** - Lightweight Rust testing
- **Mollusk** - Instruction-level testing
- **Trident** - Fuzz testing

### Platforms
- **Web** - React, Next.js
- **Desktop** - Tauri, Electron
- **Mobile** - React Native, Expo
- **Gaming** - Unity (WebGL, PSG1)

---

## Project Structure After Setup

```
your-project/
├── CLAUDE.md              # ← Main config (copied from CLAUDE-solana.md)
├── .claude/
│   ├── agents/            # 15 specialized AI agents
│   ├── commands/          # 32 slash commands
│   ├── skills/            # Progressive knowledge
│   │   ├── SKILL.md           # Unified hub (start here)
│   │   ├── ext/               # Skill packs: core by default, extensions as installed
│   │   │   ├── solana-dev/        # Core Solana (Foundation) (core)
│   │   │   ├── auditor-skill/     # Security audit checklists + vectors (core)
│   │   │   ├── colosseum/         # Colosseum Copilot, startup research (core)
│   │   │   │                      # anthropic-skills is core too, but installs top-level (below)
│   │   │   ├── ...                # extensions you add: sendai, jupiter, metaplex, magicblock,
│   │   │   │                      # helius, alchemy, qedgen, quicknode-anchor, solana-fuzz,
│   │   │   │                      # solana-game, solana-mobile, cloudflare, vercel, solana-new,
│   │   │   │                      # sign-safe, counterparty-gate, community-moderation,
│   │   │   │                      # position-manager-skill, content-gen-skill, writer-style-skill
│   │   ├── extensions.txt     # Extensions this project installed (kept by /update)
│   │   ├── skill-registry.json # Pack tiers (core/extension) + opt-in add-on catalog
│   │   ├── skill-packs/      # Work → pack index: which extension or add-on to offer
│   │   ├── idea-sprint/      # Wrapper: find + validate crypto ideas
│   │   ├── pitch-deck/       # Wrapper: pitch decks for crypto projects
│   │   ├── hackathon/        # Wrapper: hackathon submissions + grants
│   │   ├── frontend-design/  # anthropic-skills (core), with webapp-testing/
│   │   ├── token-extensions/ # Token-2022 extensions skill
│   │   ├── backend-async.md  # Axum/Tokio patterns
│   │   └── deployment.md     # Deploy workflows
│   ├── security.json      # Firewall tier in force (Relaxed by default)
│   └── settings.json      # Permissions, sandbox and hooks, generated from the tier
├── .mcp.json              # MCP server configs (project root)
├── .safe-ai-skill/        # safe-ai-skill project policy
├── programs/              # Your Solana programs
├── app/                   # Your frontend
└── ...
```

---

## Usage Examples

### Start a New Program
```
You: Create an escrow program
Claude: [Uses solana-architect to design, anchor-engineer to implement]
```

### DeFi Integration
```
You: Integrate Jupiter swaps into the program
Claude: [Uses defi-engineer with Jupiter protocol skills]
```

### Build and Test
```
You: /build-program
Claude: [Runs anchor build, reports any errors]

You: /test-rust
Claude: [Runs cargo test, shows results]
```

### Profile Performance
```
You: /profile-cu
Claude: [Reports CU usage per instruction, suggests optimizations]
```

### Deploy
```
You: /deploy devnet
Claude: [Deploys to devnet, provides program ID]
```

### Token Launch
```
You: Create a Token-2022 token with transfer fees
Claude: [Uses token-engineer with the token-extensions skill]
```

---

## Customization

### Add Project-Specific Context

Edit your `CLAUDE.md` to add:

```markdown
## Project-Specific

- Program ID: `YourProgram...`
- Main token: `TokenMint...`
- Custom patterns for this project
```

### Adjust Permissions

Run `/firewall` to switch tier. The permission and sandbox block in `.claude/settings.json` is generated from the tier and rewritten whole when it changes, so put your own rules in `.claude/settings.local.json`, which `/update` never touches — the kit's rewrite only replaces the rules it wrote itself. [README → Firewall tiers](README.md#firewall-tiers) covers what each tier opens and closes, and [docs/firewall.md](docs/firewall.md) what the tiers cannot enforce.

### Configure MCP Servers

Edit `.env` to add API keys for MCP servers (Helius). Run `/setup-mcp` for guided setup and the optional servers.

---

## Updating

Inside Claude Code:

```text
/update
```

Or from your project's root (replace `your-project` with its path):

```bash
cd your-project
```

```bash
bash .claude/bin/update.sh
```

Install a skill extension when a task needs one. `/add-skill` with no id lists them; replace `sendai` with the id you need:

```text
/add-skill sendai
```

Check that every link in the skill hub resolves (in a fork of the kit repo, this also moves the `ext/` submodules to their latest upstream commits):

```text
/resync
```

---

## Troubleshooting

**Claude doesn't use the config:**
- Ensure `CLAUDE.md` is in your project root
- Ensure `.claude/` folder is in your project root
- Restart Claude Code

**Commands not working:**
- Check `.claude/settings.json` permissions
- Ensure command files are in `.claude/commands/`

**Agent not spawning:**
- Verify agent file exists in `.claude/agents/`
- Check agent description matches your request

**MCP servers not connecting:**
- Run `/setup-mcp` to verify configuration
- Check API keys are set in environment

**Skill packs in `.claude/skills/ext/` missing or empty:**
- In an installed project they are plain copies: run `bash .claude/bin/update.sh` to fetch the core packs and the extensions you installed
- In a fork of the kit repo they are git submodules: run `git submodule update --init --recursive`

**A skill link points to a missing `ext/` folder:**
- It is an extension: run the `bash .claude/bin/skills.sh add <id>` command given next to the link, or `/add-skill <id>`

---

## Resources

- [CLAUDE-solana.md](./CLAUDE-solana.md) - Full configuration reference
- [.claude/agents/](./.claude/agents/) - All agent definitions
- [.claude/commands/](./.claude/commands/) - All commands
- [.claude/skills/](./.claude/skills/) - Knowledge base
- [.mcp.json](./.mcp.json) - MCP server configs

---

**Ready to build on Solana!**
