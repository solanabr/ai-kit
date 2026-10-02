# Changelog

All notable changes to solana-ai-kit.

## [2.2.0] - 2026-10-02

### Added
- **Agentic firewall with four tiers** — `Off / Relaxed / Medium / High`, default **Relaxed**, gating file access, destructive commands and egress. The tier is recorded in `.claude/security.json` together with the exact rule strings written (`enforced.ruleIds`) and a hash; `.claude/bin/firewall.sh` regenerates the `permissions` + `sandbox` block in `.claude/settings.json` **wholesale** on every switch. Lists merge and never override across settings sources (effective policy is `deny = ∪denies`, `ask = ∪asks − deny`, `allow = ∪allows − deny − ask`), so a layered tier system would collapse to the strictest tier any layer ever wrote; whole-block regeneration is the only way a tier can be *lowered*. Tier-varying path decisions live in `sandbox.filesystem.denyRead`/`allowRead`, the one layer in Claude Code with a genuine carve-out (narrowness decides, not source order, so it survives merging).
- **`/firewall` command** — show the current tier and switch between them.
- **Egress guard hook** — a position-anchored PreToolUse gate for data-carrying `curl`/`wget`. It reads argument *positions*, not command prose, so `--upload-file`/`@file` bodies and reader→network-sink pipelines are caught while documentation, commit messages and issue bodies that merely *name* a credential path are not.
- **`permissions.deny` is identical at every tier** — the never-allowed set: credential stores and vaults, code-execution-on-next-build files (`~/.cargo/config.toml`, `~/.zshenv`, `~/.gitconfig`, in-project `**/.cargo/config.toml`), login-shell and autostart persistence, shell/REPL history, the kit's own settings and hooks (as `Edit(...)`, not `Read(...)`, so the kit can still read its own config), `Bash(claude *)` policy re-roll, and matcher-evading wrappers (`env`, `sh -c`, `git -c`, `git -C`, `flock`, `docker exec`, …). Deny is the one axis where merge-monotonicity is harmless, because every tier agrees.
- **Tier migration in `update.sh`** — existing installs now receive the firewall. An install whose `permissions` block still matches the shipped baseline adopts `relaxed`; one with a hand-edited policy adopts `off` and prints a notice rather than silently rewriting a tuned policy; a symlinked `settings.json` is reported `[skipped]`.
- **`tests/test_firewall.sh` and `tests/test_egress_guard.sh`**, plus four `validate.sh` checks (`security.json` validity and tier range, `enforced.ruleIds` ⊆ the live lists, generator idempotency and tier round-trip, and a rejection of `/`-anchored path rules in anything destined for `~/.claude/`, where `/secrets/**` resolves to `~/.claude/secrets/**` rather than the project).

### Fixed
- **Sandbox read-denies were bypassable through `sandbox.excludedCommands`** — any entry lifts the OS sandbox for the **entire** command line, so `git push -h >/dev/null 2>&1; <read of a denied path>` exited 0 where the bare read got EPERM. The six git/gh entries are gone; exactly two remain, `surfpool *` and `anchor test*`, because Surfpool needs unsandboxed Mach access.
- **`anchor test` was broken on a default install** — `surfpool start` panics instantly under the Bash sandbox (macOS SystemConfiguration), which also took out `/test-rust`, `/test-ts`, `/profile-cu` and `/debug-user-tx` on Anchor 1.x's default path. `network.allowLocalBinding` does not cover it.
- **`cargo build` could not write its registry cache** — the toolchain roots (`~/.cargo/**`, `~/.rustup/**`, `~/.cache/solana/**`, `~/.local/share/solana/**`, `~/.avm/**`) are now carved out of the outside-write deny at every tier, with credentials and `config.toml` still denied.
- **`/update` and `/add-skill` failed at `mktemp -d` under the sandbox** — the platform temp root is now writable at every tier. The same failure truncated a tracked file when an unguarded variable expanded to empty.
- **Two-wildcard permission patterns never matched** — a mid-pattern `*` does not match an empty string, so `Bash(anchor * --final*)` did not stop `anchor --final`, and `Bash(git push * -f *)` did not stop `git push origin -f`. Every two-wildcard rule now ships its zero-gap twin.
- **`permissions.ask` rules never fired** — verified twice in-session: `git clean -n` matched an ask rule and ran silently while a deny rule blocked `sudo -n true`, with the sandbox on. Every prompt is now a hook returning `permissionDecision: "ask"`; no tier distinction rests on `permissions.ask`.
- **`Bash(git clean -fd *)` and `Bash(git push --force *)` sat in both `deny` and `ask`** — deny wins, so both ask rules were dead. The lists are de-duplicated and a test forbids any pattern appearing in both.
- **The secrets hook matched command prose instead of argument positions** — it blocked a diagnostic `ls -l` on a wallet path, a `gh issue create` whose body mentioned `--final`, and heredocs that merely named a credential directory. Because the workaround for a false positive was identical to the workaround for a true positive, it taught evasion; two commands already documented the route-around.
- **The on-chain hook resolved the wrong cluster** with `ANCHOR_PROVIDER_URL=` set or `-C`/`--config` passed, mislabelling mainnet as devnet and vice versa. It is also headless-aware now, instead of returning `ask` for every on-chain write on every cluster and hard-failing every `-p` run.
- **Rules that protected nothing** — `Read(**/Local Extension Settings/**)` is cwd-bounded while browser profiles live under `~/Library`, so it never matched; mainnet denies anchored to the cluster string blocked read-only `anchor verify --provider.cluster mainnet` and `solana program dump --url mainnet-beta`, and now anchor to the verb.
- **Verified-live git and CLI evasions closed** — `git clean -xdf`, `git reset --ha HEAD` (long options abbreviate in git), `git restore .` (absent from the policy entirely), `git branch --delete --force`, `git gc --prune=all`, `git push origin +main`, `solana config set -k /path`, `npm run release` wrapping `npm publish`, `gh api -X DELETE /repos/O/R`, and `gh variable set`.

### Changed
- **The Solana config directory is never added to `sandbox.filesystem.denyRead`** — only `*.json` under it. `anchor init` writes `wallet = "~/.config/solana/id.json"` into `Anchor.toml`, `Read` denies project into `denyRead`, and the sandbox covers Bash *and its children*, so a directory-wide read deny left `solana`/`anchor` unable to resolve a signer at all. `cli/config.yml` stays readable so `solana config get` keeps working.
- **Project keypairs stay `allow` at Medium**, correcting the approved matrix — Medium asking for the file High allows made Medium stricter than High on exactly that file. The control is a `Read` deny plus a sandbox `allowRead`, which blocks the model while letting the subprocess read.
- **Project `.env` write is `deny` at Medium, not `ask`** — an ask is walked around by `python3 -c`, `perl -pi` or `sed -i`, nothing in a Solana build legitimately rewrites it, and the deny removes a headless hard-fail. `/setup-mcp`, `/cleanup`, `/build-app` and `/doctor` were rewritten to a names-and-presence helper, which also resolves the safe-ai-skill `secret_read` hard-guard conflict.
- **Unrecoverable git is `deny` at every tier including Relaxed** — `git reflog expire --expire=now --all` and `git gc --prune=all` are what make history truly unrecoverable; everything else is reflog-recoverable.
- **Relaxed emits zero `permissions.ask` entries**, which keeps it CI-safe. Medium and High hard-fail headless by design; `.github/workflows/claude.yml` runs Relaxed or Off.
- **Writes under `git rev-parse --git-common-dir` are allowed** so submodule init survives a linked worktree.
- **Egress is documented as unenforceable, not claimed** — `sandbox.network.strictAllowlist` has no effect from the scopes the kit writes, and `sandbox.credentials` is not applied from project or local settings at all. What ships is a `deniedDomains` exfil denylist, command rules for `npm publish`/`cargo publish`/`git push`, and the egress hook; `strictAllowlist` is documented as a line the user adds to `~/.claude/settings.json`. Local MCP servers run outside the sandbox and outside every rule and hook, so attaching servers beyond the three defaults removes the guarantee. Relaxed's honest guarantee is "your secrets won't additionally reach a third party", not confidentiality.
- **`--agents` installs are unfirewalled** — `settings.json` is inert there; `.claude/security.json` installs with its paths rewritten and the mode is documented rather than silently looking protected.

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
