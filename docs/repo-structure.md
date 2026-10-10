# Repository structure and workflow

What is in the kit repository, which parts reach an installed project, and the workflow the kit expects of a change.

## Repository Structure

```
.
├── CLAUDE.md                    # Main hub - Claude reads this first
├── README.md                    # Install and orientation
├── docs/                        # Full spec (this directory) — not copied by install.sh
├── .mcp.json                    # MCP server configurations (project root)
├── .safe-ai-skill/policy.yaml   # safe-ai-skill project policy (install.sh copies it)
├── install.sh                   # One-liner installer
├── update.sh                    # Deprecation wrapper → .claude/bin/update.sh
├── validate.sh                  # Config integrity checker
├── LICENSE                      # MIT
├── tests/                       # Config integrity test suite
├── .github/dependabot.yml       # Weekly grouped PR bumping the ext/ skill pins
├── .github/workflows/
│   ├── ci.yml                       # PR validation
│   ├── claude-code-review.yml       # Automatic Claude review of every PR (advisory)
│   ├── claude.yml                   # @claude mention responder (issues/PRs)
│   └── submodule-review.yml         # Flags risky content in ext/ pin bumps
├── .github/scripts/
│   ├── codex-skill-budget.py        # Fails when Codex cuts a skill description (used by ci.yml)
│   └── submodule-bump-review.sh     # Diff each bumped pack (used by submodule-review.yml)
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
    │   │   ├── auditor-skill/         # Security audit checklists + vectors (core)
    │   │   ├── colosseum/              # Colosseum Copilot, startup research (core)
    │   │   ├── sendai/                  # SendAI protocol skills (DeFi)
    │   │   ├── solana-game/             # Solana game skill (Unity, PSG1)
    │   │   ├── cloudflare/              # Cloudflare Workers, Agents SDK
    │   │   ├── qedgen/                # QEDGen formal verification (Lean 4)
    │   │   ├── solana-mobile/           # Mobile Wallet Adapter, Genesis Token
    │   │   ├── vercel/                # Vercel deployment, Next.js, AI SDK
    │   │   ├── solana-new/            # SendAI idea→launch journey skills + datasets
    │   │   ├── jupiter/               # Official Jupiter skills (swap, lend, VRFD)
    │   │   ├── metaplex/              # Official Metaplex (NFT, candy machine)
    │   │   ├── magicblock/            # Official MagicBlock (Ephemeral Rollups)
    │   │   ├── helius/                # Official Helius infra + SVM internals
    │   │   ├── alchemy/               # Official Alchemy (Solana RPC, DAS, gRPC)
    │   │   ├── position-manager-skill/ # CLMM LP lifecycle (Orca, Raydium, Meteora)
    │   │   ├── content-gen-skill/      # Educational content pipeline (courses, explainers)
    │   │   ├── writer-style-skill/     # Prose in a named author's voice
    │   │   └── startup-builder/        # Idea, pitch, hackathon, pricing, fundraising, launch, BD
    │   ├── skill-registry.json     # Pack tiers (core/extension) + opt-in add-on catalog
    │   ├── skill-packs/            # Work → pack index: which extension or add-on to offer (local)
    │   ├── token-extensions/        # Token-2022 extensions: pick, combine, create (local)
    │   ├── backend-async.md         # Axum/Tokio patterns (local)
    │   └── deployment.md            # Deployment workflows (local)
    ├── security.json            # Firewall tier in force + the exact rules it enforced
    └── settings.json            # Sandbox, permissions, hooks, stbr marketplace + safe-ai-skill@stbr
```

An install copies the named `.claude/` subdirectories (`agents`, `skills`, `commands`, `bin`, `hooks`) plus `VERSION`, `settings.json`, `security.json`, `.mcp.json`, `.safe-ai-skill/policy.yaml` (Claude Code installs only) and `CLAUDE-solana.md` → `CLAUDE.md`. Everything else above — `docs/`, `tests/`, `install.sh`, `validate.sh`, the workflows — stays in the kit repository.

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

## Code Quality

Before merging, run `/diff-review` or check diff against main:

```bash
git diff main...HEAD
```

Remove: excessive comments, abnormal try/catch blocks, verbose errors, redundant validation.

Keep: legitimate security checks, non-obvious explanations, matching error patterns.
