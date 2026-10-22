# Agents and commands

The complete reference: 15 agents with the model each one runs on, 34 workflow commands, and how to compose them into a team. Nothing here loads up front — Claude Code lists only each agent's and command's one-line description, and reads a body when a task needs it.

## Agents

| Agent | Purpose | Model |
|-------|---------|-------|
| **solana-architect** | System design, PDA schemes, token economics, multi-program architecture | Opus |
| **anchor-engineer** | Anchor development, IDL generation, account constraints | Opus |
| **pinocchio-engineer** | CU optimization (80-95% savings), zero-copy, minimal binary | Opus |
| **defi-engineer** | DeFi integrations: Jupiter, Kamino, Raydium, Orca, Meteora | Opus |
| **token-engineer** | Token-2022 extensions, token economics, launch mechanics | Opus |
| **solana-frontend-engineer** | React/Next.js, wallet UX, transaction flows, accessibility | Opus |
| **mobile-engineer** | React Native/Expo, mobile wallet adapter, deep linking | Opus |
| **rust-backend-engineer** | Axum APIs, indexers, WebSocket services | Opus |
| **devops-engineer** | CI/CD, monitoring, RPC infrastructure, Cloudflare Workers | Opus |
| **solana-qa-engineer** | Testing (Mollusk/LiteSVM/Trident), CU profiling, code quality | Opus |
| **tech-docs-writer** | READMEs, API docs, integration guides | Opus |
| **game-architect** | Solana game design, Unity architecture, on-chain game state, PlaySolana | Opus |
| **unity-engineer** | Unity/C# implementation, Solana.Unity-SDK, wallet integration, NFT display | Opus |
| **solana-guide** | Learning, tutorials, concept explanations, progressive learning paths | Opus |
| **solana-researcher** | Ecosystem research, protocol investigation, SDK analysis | Opus |

**Model routing:** every agent pins `model: opus`, because Opus 5.5 is currently the best value for this work — implementation, docs and research included, not only deep reasoning. The trade accepted: a pinned agent ignores your session model, so a Fable session's subagents run on Opus. The kit never pins `fable`. Commands inherit your session model, except `/doctor`, `/setup-mcp` and `/scaffold`, which run on Sonnet for that turn: they are mechanical and you run them at the start of a session, where a model switch costs no cached prompt. Since no agent inherits, `CLAUDE_CODE_SUBAGENT_MODEL` in your settings `env` changes none of them on its own; add `CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1` to apply it to every agent.

## Agent Teams

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
| **audit-and-fix** | qa → auditor-skill context → anchor | Audit and remediate |
| **game-ship** | game-architect → unity → qa | Game feature |
| **research-and-build** | researcher → architect → anchor/pinocchio | Investigate a protocol or pattern, then design and implement |
| **defi-compose** | researcher → defi-engineer → qa | DeFi integration |
| **token-launch** | token-engineer → frontend → qa | Token creation + launch UI |

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
| `/inspect-mint` | Decode a mint from raw bytes (RPC `jsonParsed` drops extensions), list live authorities, flag integration risks |

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
| `/pr-description` | Write a PR title and body a reviewer can verify: repro without funds, test plan with real counts, risk |
| `/commit-claude-config` | Version the kit config in git (un-ignores `.claude/`, `.mcp.json`, `.gitmodules` and commits them with `CLAUDE.md`) |
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
