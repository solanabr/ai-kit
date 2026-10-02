# Changelog

All notable changes to solana-ai-kit.

## [2.2.0] - 2026-10-02


### Added
- **Core and extension skill packs** — a full install ships only the core packs (`solana-dev`, `safe-solana-builder`); the other `ext/` packs stay pinned and install on demand with `install.sh --with <id>`, `bash .claude/bin/skills.sh add <id>` or the new `/add-skill` command (command count 30 → 31). `skill-registry.json` gains `tier`, `path` and `triggers`; the hub lists every extension with when to use it. Adds the official MagicBlock and Alchemy packs. Dependabot bumps the pins weekly in one grouped PR.
- **safe-ai-skill as a core plugin** — the `stbr` marketplace lists safe-ai-skill (SHA-pinned), `plugin.json` depends on it, and a full install registers the marketplace and enables `safe-ai-skill@stbr` for the project.
- **anthropic-skills extension** — installs Anthropic's Apache-2.0 skills (`frontend-design`, `webapp-testing`, `mcp-builder`) at a pinned commit into `<config>/skills/<name>/`, so Codex, Grok Build and other Agent Skills clients see them. `DENIED_SKILLS` refuses the proprietary document skills before any fetch.
- **token-extensions skill** — a kit-owned skill covering every Token-2022 extension (choosing and combining, creation order, sizing, fees, hooks, metadata and groups, issuer controls, confidential transfers, display amounts), replacing `token-2022.md`. Routed from token-engineer and both skill hubs, and bundled in the plugin.
- **Model routing** — agents and commands run on `opus`, `sonnet` or inherit the session model; `tests/test_model_routing.sh` enforces allowed values and README drift.
- **Mainnet and wallet permission gates** — ask rules plus a PreToolUse hook that names the resolved cluster replace the `CONFIRM_MAINNET=1` prefix for program deploys, upgrades, closes, authority changes, token transfers and stake withdrawals. `solana-keygen new`/`recover` with `--force` asks before overwriting the default wallet.
- **README: other agents and a no-install route** — sections for Codex, Grok Build and other AGENTS.md tools, a no-install route through aikit.superteam.codes, and copy-paste install steps (installer, one-liner, from a clone; plugin marketplace last).
- **Tests** — `test_hooks.sh`, `test_resync.sh`, `test_local_skills.sh`, `test_skill_extensions.sh`, `test_anthropic_skills.sh`, `test_validate.sh`; `test_plugin.sh` validates a dereferenced copy of the plugin tree; `test_cross_references.sh` follows the from-a-clone install steps.

### Changed
- **Always-loaded context cut ~91%** — the five `.claude/rules/` files used `globs:`, which Claude Code ignores, so all of them loaded every session. They are gone; CLAUDE-solana.md drops to 36 lines, agent descriptions are routing-only, and agent, command and hub bodies are slimmed. `validate.sh` fails on an unscoped rule and on over-budget descriptions.
- **settings.json stops pinning session behavior** — drops the agent-teams env flag, `enableAllProjectMcpServers`, the top-level `defaultMode`, the LSP `enabledPlugins` and `modelDefaults`. `/update` removes these from installs made by kit 2.1.0 or earlier, only where they still hold the kit's value.
- **Default MCP servers trimmed** to helius, solana-dev (now native HTTP) and context7. playwright, surfpool and context-mode are opt-in; memsearch is dropped.
- **Hooks** — read stdin JSON and block with exit 2; the Stop, SubagentStop, PostToolUse and git-commit hooks are removed; SessionStart shows the banner to the user and gives Claude the RPC host and wallet. The plugin's `hooks.json` mirrors settings.json, including the secrets gate.
- **Sandbox** — git push/pull/fetch and `gh pr/run/issue` run outside it; local binding is allowed for validators and dev servers; `gh auth token` is denied.
- **`install.sh --agents`** writes AGENTS.md (HTML comments stripped), rewrites project `.claude/` paths to `.agents/`, registers `ext/` packs under `.agents/skills/ext/`, and no longer installs `/cleanup`.
- **Repo renamed** to `solanabr/ai-kit` (the frozen `update.sh:16` keeps the old URL; GitHub redirects it).
- **Skill submodules resynced** to upstream HEAD, with moved paths updated in agents, commands and the hub.
- **Plugin skills hub** moved to `plugin/skills/solana-ai-kit/SKILL.md` so every bundled skill registers.

### Fixed
- `/resync` and `/update` work in `--agents` installs; `/resync` no longer reports links into uninstalled extensions as broken; `resync.sh` runs from its target dir regardless of cwd.
- install and update no longer fail when a config subdir is a symlink.
- `update.sh --dry-run` no longer deletes `.agents/commands/cleanup.md`; `install.sh --agents` removes a `/cleanup` an older install left behind.
- The `.gitignore` config block is backfilled in both install orders, without duplicates on CRLF files.
- The manual install clones into `solana-ai-kit/`, so its `cp` steps find the files.
- `validate.sh` skips, rather than fails, links into uninitialized submodules.
- Destructive-command deny rules restored; the mainnet deploy deny rule dropped so `/deploy`'s mainnet step gets the approval prompt.
- `plugin.json` no longer declares a redundant hooks path (duplicate load error).
- Anchor TS package is `@anchor-lang/core`; `anchor-specialist` references point to `anchor-engineer`; `settings.json` syntax error fixed; `/setup-mcp` covers every `.env.example` key.

### Removed
- `.claude/rules/` (anchor, dotnet, pinocchio, rust, typescript).
- `.claude/skills/token-2022.md` (replaced by the token-extensions skill).
- Drift and Ranger Finance references (protocols gone).
- The live `claude-code.yml` workflow (moved to a template, stopping duplicate `@claude` runs).

## [2.1.0] - 2026-06-26

### Added
- **`/commit-claude-config` command** — opt back into version-controlling the kit. Strips the config block from `.gitignore`, then stages and commits `.claude/` (or `.agents/`), `CLAUDE.md`, `.mcp.json`, and `.gitmodules`. Keeps `ext/` submodules ignored (re-fetched via `git submodule update`), so it doesn't vendor 18 upstream repos. Detects `--agents` installs.
- **Config gitignored by default** — `install.sh` now adds `.gitmodules`, the config dir (`.claude/`/`.agents/`), `CLAUDE.md`, and `.mcp.json` to `.gitignore` so the kit reads as ignorable infrastructure and stays out of `git status`. Written as a marked block (`# >>> solana-ai-kit config … <<<`) so `/commit-claude-config` can remove it surgically. Safe by git semantics: already-tracked files are unaffected. The install output + README/QUICK-START document the default and the opt-in.

### Security
- **`.env` gitignored** — `install.sh` now adds `.env`/`.env.local` to `.gitignore` (the installer creates `.env` from `.env.example`, which holds API keys once filled). `.env.example` stays tracked.

### Changed
- **Parallel + shallow submodule fetch** — `install.sh` clones with `--shallow-submodules --jobs N` (floor 8) and runs `git submodule update --init --recursive --jobs N`, fetching the 18 `ext/` skill submodules concurrently at their pinned commits instead of serially. Tag resolution (`git ls-remote`) is skipped on local-source installs.
- **Banner byline centered + darkened** — the `by @SuperteamBR 🇧🇷` line (install banner + SessionStart hooks) is centered under the logo and uses a dim dark-gray so it reads as a subtle subtitle.
- Command count 29 → 30.

## [2.0.2] - 2026-06-16

### Security
- **Deny read/write access to browser-extension wallet storage** (Chrome, Brave, Edge, Firefox, Chromium, Opera, Vivaldi, Arc — across macOS, Linux, and Windows) — the profile data dirs where Phantom/Solflare/Backpack/MetaMask and other extension wallets keep encrypted vaults (`Local Extension Settings/`, `IndexedDB/`, `Local Storage/`). Added as `sandbox.denyWrite` path prefixes and `permissions.deny` `Read(...)` globs (plus a cross-cutting `Read(**/Local Extension Settings/**)`); broad profile-dir deny is wallet-agnostic and future-proof
- **Added `gate-bash-secrets` PreToolUse hook** — blocks shell (Bash) reads of private keys, wallet vaults, and credentials (exits non-zero before the command runs). Covers the key/cred paths plus all browser profile dirs above; carefully scoped so program keypairs in `target/deploy/`, project `*.pem` certs, and browser *binaries* (`google-chrome --headless`) stay allowed
- **Read-tool deny coverage for key/cred paths** — `permissions.deny` now also has `Read(...)` globs for `~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.config/solana/id.json`, `~/.npmrc`, `~/.git-credentials`, `~/.netrc`, `~/.config/gh/hosts.yml`, `~/.kube/config`, `~/.cargo/credentials.toml`, `~/.docker/config.json`, `~/.pypirc`, `~/.gem/credentials` (complements the v2.0.1 `denyWrite` + the new Bash hook)

## [2.0.1] - 2026-06-16

### Security
- **Expanded `sandbox.denyWrite`** with specific credential/key files (kept the existing 4): `~/.netrc`, `~/.git-credentials`, `~/.npmrc`, `~/.cargo/credentials.toml`, `~/.docker/config.json`, `~/.config/gh/hosts.yml`, `~/.kube/config`, `~/.pypirc`, `~/.gem/credentials` — targeted credential files only (not whole tool dirs, so legit `cargo`/`gh`/`solana config` operations still work)
- **Expanded `permissions.deny`** with curated low-UX-cost guards: secret-read/exfil (`cat`/`less`/`xxd` of `*id.json`, `*keypair*.json`, `~/.ssh/*`, `~/.config/solana/*.json`, `~/.aws/*`, `~/.gnupg/*`, `*.pem`, `~/.config/gh/hosts.yml`, `~/.npmrc`, `~/.git-credentials`, `~/.netrc`); destructive-fs (`mkfs*`, `rm -rf ~`/`~/*`/`.git`/`.git/*`, `git clean -fdx*`/`-fX*`); mainnet authority/funds ops (`solana program set-upgrade-authority`, `spl-token set-authority`, `solana program close`, `solana withdraw-from-stake-account`/`-vote-account`)

### Changed
- **`/cleanup`** now also strips the kit's distribution/maintenance infra from forked-template projects: `.claude-plugin/`, `plugin/`, `vercel.json`, plus the kit-only `.claude/CHANGELOG.md` (all removed defensively, only if present)

## [2.0.0] - 2026-06-15

### Added
- **Brand ASCII banner (SessionStart + installer)**: slanted SOLANA wordmark (echoes the Solana logotype) + robotic half-block AI KIT tier, 7-row purple→green gradient, with NO_COLOR/plain-terminal fallback
- **`/doctor` command**: read-only health check for the dev environment and solana-ai-kit config — one exact fix-it command per failure
- **`/audit-infra` command**: infrastructure-first security audit (secrets archaeology, dependency supply chain, CI/CD, LLM/skill security, OWASP Top 10, STRIDE) — adapted from cso by gstack (via sendaifun/solana-new, MIT), telemetry-free
- **`/product-review` command**: product quality review with 8-dimension scorecard; `--harsh` for the brutal roast variant
- **`/dream` command**: memory consolidation — dedupe, contradiction-check, prune, re-rank MEMORY.md + CLAUDE.md Project Learnings
- **Submodules**: `ext/solana-new` ([sendaifun/solana-new](https://github.com/sendaifun/solana-new), pinned), `ext/ghostsecurity` ([ghostsecurity/skills](https://github.com/ghostsecurity/skills)), `ext/defending-code` ([anthropics/defending-code-reference-harness](https://github.com/anthropics/defending-code-reference-harness))
- **GTM wrapper skills**: `idea-sprint`, `pitch-deck`, `hackathon` — thin local wrappers routing into ext/solana-new journey skills and datasets (marketing-video is reference-routed from the hub, no wrapper)
- **`.claude/context/` phase-handoff convention**: gitignored scratch dir for idea→build→launch context files
- **Permissions**: deny `Bash(curl *convex.cloud*)` — backstop against upstream telemetry preambles
- **Surfpool MCP server in the standard install** (keyless; agent-driven local-validator / mainnet-fork control; requires the surfpool CLI) — MCP servers 6→7
- **Claude Code plugin distribution** — in-repo marketplace (`.claude-plugin/marketplace.json`, marketplace name `stbr`) + symlinked `plugin/` core-plugin (agents, commands, local skills, MCP, hooks); published via the `stbr` marketplace (`/plugin install solana-ai-kit@stbr`); commands namespace as `/solana-ai-kit:<name>`. `install.sh` remains the full install for `.claude/rules`, the permissions/sandbox policy, and the 18 ext/ submodules (plugins can't carry submodules); `/doctor` gains a dual-install guard
- **`skill-registry.json`** — structured machine-readable catalog of opt-in add-on skills/plugins/MCPs (install-on-demand, not bundled by default); curated + deduped against solana-new's catalogs
- One-line install endpoint **aikit.superteam.codes** (Vercel 308 redirect → install.sh; pulls + installs the latest release). Docs updated; raw GitHub URL retained as fallback.

### Changed
- **Resynced ext submodules to upstream HEADs** (9 advanced): sendai (−drift +phoenix/ranger-finance/lavarage/lifi/arcium/birdeye/wallet-analysis/carbium/sol-incinerator), cloudflare (agents-sdk folds in MCP/AI-agent deployment; +sandbox-sdk), qedgen, safe-solana-builder, solana-dev, solana-mobile, trailofbits, colosseum, vercel; defending-code/ghostsecurity/solana-game/solana-new already at upstream HEAD. Hub SKILL.md routing refreshed (drift row dropped, perps→ranger-finance, +cross-chain/encrypted-compute rows); README sendai purpose de-references Drift
- **Replaced the `registry/` prose skill with `skill-registry.json`** + a master-`SKILL.md` pointer (leaner): the scouting methodology and curated watchlists fold into the structured catalog; the hub's "Registry & Monitoring" section and routing row are dropped
- **Resynced vercel-labs/agent-skills** — `vercel-optimize` + `writing-guidelines` skills now present under `ext/vercel`
- **Project renamed** solana-claude-config → **solana-ai-kit** (repo URL `solanabr/solana-ai-kit`): all docs, installer, and update-tooling references updated; env vars renamed to `SOLANA_AI_KIT_*` (`SOLANA_AI_KIT_LOCAL_SRC`, `SOLANA_AI_KIT_UPSTREAM`, `SOLANA_AI_KIT_BRANCH`) with `SOLANA_CLAUDE_*` back-compat fallbacks; VERSION package name updated
- Enriched `solana-researcher` (DeFi market research + competitive landscape), `rust-backend-engineer` (indexer non-negotiables), `solana-guide` (EVM→Solana concept map + incubator loop), `token-engineer` (tokenomics pre-launch checklist), `/debug-user-tx` (common pitfalls encyclopedia), `/deploy` + `deployment.md` (upgrade-authority staging timeline)
- Skills hub (`SKILL.md`) routing for GTM journey skills and the new security submodules
- README Credits: full MIT notice for sendaifun/solana-new, cso/gstack credit, Apache-2.0 submodule notes, idea-dataset primary sources (Superteam, YC, a16z, Alliance)
- README submodule/credits rows decluttered — inline license tags removed, license notices consolidated in Credits

### Fixed
- Stale test counts and settings assertion
- README submodule link + workflows tree
- CLAUDE.md rules-frontmatter terminology
- Retroactive tags v1.4.0/v1.5.0

## [1.5.0] - 2026-04-20

### Added
- **`/debug-user-tx` command**: Reproduce a user-reported failing transaction against forked cluster state and map the error back to source. Fetches tx via RPC, identifies the failing instruction, decodes the handler discriminator (Anchor IDL ≥0.30 or `sha256("global:<name>")` for <0.30), maps Anchor `Custom(N)` codes + well-known constraint codes (2000–3012) to `#[error_code]` variants with file:line pointers, diffs writable account state, and optionally replays via Surfpool (fork) or LiteSVM. Supports three modes: signature given, tx never landed, or failure inside an external CPI target.

## [1.4.0] - 2026-04-02

### Added
- **Vercel submodule**: `ext/vercel` from [vercel-labs/agent-skills](https://github.com/vercel-labs/agent-skills) — Vercel deployment, Next.js, AI SDK, v0, edge functions
- SKILL.md routing for Vercel & deployment platform skills

### Changed
- **VERSION format**: Now includes package name (`solana-claude-config 1.4.0`) for clarity
- **install.sh / update.sh**: `.gitmodules` merge instead of overwrite — preserves user-defined submodules
- **install.sh / update.sh**: No longer ship `CHANGELOG.md` to user projects (stays in source repo)
- **install.sh / update.sh**: No longer ship `MEMORY.md` template (Claude creates it organically)
- **install.sh / update.sh**: No longer create `CLAUDE.local.md` boilerplate (Claude creates it when needed)

### Removed
- `CHANGELOG.md` from install/update targets (maintainer-only file)
- `MEMORY.md` from install protected files (interfered with organic memory)
- `CLAUDE.local.md` boilerplate creation (Claude handles this itself)

## [1.3.0] - 2026-04-01

### Fixed
- **MCP servers not loading**: Moved `.claude/mcp.json` → `.mcp.json` (project root) — Claude Code only reads `.mcp.json` at project root, the old path was silently ignored
- **MCP servers stuck in pending**: Added `enableAllProjectMcpServers: true` to `settings.json` — without this, project-level MCP servers require manual approval and are silently skipped

### Changed
- Replaced Puppeteer MCP server with Playwright (`@playwright/mcp`) — actively maintained by Microsoft, Puppeteer MCP is unmaintained
- `install.sh` now places `.mcp.json` at project root instead of inside `.claude/`
- `update.sh` updated to handle `.mcp.json` at project root

### Added
- Tests for MCP file location (must be at root, not `.claude/`) and `enableAllProjectMcpServers` setting

## [1.2.1] - 2026-03-31

### Fixed
- `install.sh` nesting bug: installing into a directory with existing `.claude/` created `.claude/.claude/` instead of merging
- `install.sh` now preserves user files (`settings.json`, `mcp.json`, `MEMORY.md`) on reinstall instead of overwriting

### Added
- `test_install_existing_claude.sh` — verifies install into pre-existing `.claude/` directory (no nesting, user files preserved, upstream content installed)
- Enhanced `test_install_idempotent.sh` with nesting checks and user file preservation assertions

## [1.2.0] - 2026-03-31

### Added
- `test_settings_deep.sh` — deep validation of settings.json structure (env, sandbox, plugins, permissions, hooks, model defaults)
- `test_cross_references.sh` — Ripple Map enforcer: cross-validates agent/command/MCP counts and names across README, QUICK-START, and CLAUDE-solana.md
- `test_install_idempotent.sh` — verifies double-install safety (backups, no duplicates, preserved local files)
- `test_cleanup.sh` — simulates /cleanup command contract (scaffolding removal, config preservation)
- `test_resync.sh` — static analysis of resync.sh integrity and submodule state
- 5 new assertion helpers: `assert_file_not_exists`, `assert_dir_not_exists`, `assert_file_contains`, `assert_file_not_contains`, `assert_count`
- CI OS matrix: ubuntu-latest + macos-latest (fail-fast: false)
- CI smoke-test job: fresh install + agents-mode install validation
- CI badge in README.md

### Changed
- `test_update.sh` rewritten: 8 → 22 assertions (dry-run, upstream detection, protected files, agents mode)
- CI JSON validation switched from `jq` to `python3` for portability
- Total test assertions: ~195 → 340 across 14 suites (was 9)

## [1.1.0] - 2026-03-31

### Added
- `/cleanup` command for forked template users to initialize project and remove scaffolding
- `/resync` command (replaces `/update-skills`) for submodule resync with integrity verification
- `CLAUDE.local.md` — private, gitignored scratchpad for per-machine notes
- Self-learning tiered system: strict (tracked CLAUDE.md) + relaxed (private CLAUDE.local.md)
- Monorepo guidance: subdirectory CLAUDE.md auto lazy-loads
- `.claude/bin/resync.sh` — submodule resync script

### Changed
- `/upgrade` renamed to `/update` (`.claude/bin/upgrade.sh` → `.claude/bin/update.sh`)
- `VERSION` and `CHANGELOG.md` moved inside `.claude/` (no longer pollute project root)
- Root `update.sh` is now a thin deprecation wrapper → `.claude/bin/update.sh`
- Token Loading Model table updated with confirmed loading behaviors
- `install.sh` now creates `CLAUDE.local.md` and adds it to `.gitignore`
- `settings.json` env vars: added `BASH_MAX_OUTPUT_LENGTH`, `MAX_MCP_OUTPUT_TOKENS`

### Removed
- `/upgrade` command (replaced by `/update`)
- `/update-skills` command (replaced by `/resync`)
- `.claude/bin/upgrade.sh` (replaced by `.claude/bin/update.sh`)
- Root `VERSION` and `CHANGELOG.md` (moved to `.claude/`)

## [1.0.0] - 2026-03-31

### Added
- 15 specialized Solana agents (Anchor, Pinocchio, DeFi, Frontend, Mobile, Unity, etc.)
- 23 slash commands for building, testing, deploying, and auditing
- 9 external skill submodules (Solana Foundation, SendAI, Trail of Bits, Cloudflare, QEDGen, Colosseum, solana-mobile, solana-game, safe-solana-builder)
- Progressive-loading skill hub with protocol-specific routing
- 6 MCP server integrations (Helius, solana-dev, Context7, Puppeteer, context-mode, memsearch)
- Agent teams support via CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS
- Dual install modes: full Claude Code + agents-only (Cursor/Windsurf/Copilot)
