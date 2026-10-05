<p align="center"><img src=".github/assets/solana-ai-kit-banner.png" alt="Solana AI Kit — Skill, MCP & config aggregator for Claude Code, Codex + any agentic setup" width="100%" /></p>

# Solana AI Kit

[![CI](https://github.com/solanabr/ai-kit/actions/workflows/ci.yml/badge.svg)](https://github.com/solanabr/ai-kit/actions/workflows/ci.yml)
![Version](https://img.shields.io/badge/version-2.3.0-blue)
![License](https://img.shields.io/badge/license-MIT-blue)
![Solana](https://img.shields.io/badge/Solana-black?logo=solana)
![Claude Code](https://img.shields.io/badge/Claude_Code-powered-orange)

**Claude Code, set up to ship on Solana.** Not programs alone — the whole lifecycle: validating the idea, building the program and the app around it, shipping it, and the launch and growth work that follows. One command installs 15 specialized agents, 32 workflow commands, skill packs pinned — and scanned — at a commit from the ecosystem's own repositories, 4 MCP servers for on-chain data, live docs and context compression, and a firewall that gates mainnet deploys, secret reads and destructive commands. Almost none of it loads until a task needs it.

```bash
curl -fsSL https://aikit.superteam.codes | bash
```

Run it from your project's root — it installs into the current directory. Everything this README links out to lives in [`docs/`](docs/), which stays in this repository and is never copied into yours.

## What This Is

A complete `.claude/` configuration that turns Claude into a Solana building partner across that whole lifecycle, not program code alone:

- **15 specialized agents** for different tasks (architecture, Anchor, Pinocchio, DeFi, tokens, frontend, mobile, backend, DevOps, QA, docs, games, Unity, learning, research) — [full table](docs/agents-and-commands.md#agents)
- **32 workflow commands** for building, testing, deploying, profiling, migrating, and committing — [full table](docs/agents-and-commands.md#commands)
- **4 MCP servers** on by default for on-chain data (Helius), Solana docs (solana-dev), library docs (Context7) and context optimization (context-mode), plus opt-in browser automation (Playwright) and local-validator / mainnet-fork control (Surfpool)
- **Four firewall tiers** (Off / Relaxed / Medium / High, default Relaxed) gating file access, destructive commands, egress and `context-mode`'s code executor — pick one with `/firewall`, see [Firewall tiers](#firewall-tiers)
- **The [safe-ai-skill](https://github.com/solanabr/safe-ai-skill) security firewall** (core): hooks that gate mainnet, value-moving and authority actions and secret reads, and pin installed skills and MCPs at session start
- **Four standard plugins**, two steps at the end of the install: [memsearch](#persistent-memory-memsearch) for memory that outlives a session, and [`rust-analyzer-lsp`, `typescript-lsp`, `csharp-lsp`](#code-intelligence-language-server-plugins) so the agent reads your code through a compiler
- **Pinned skill packs** from Solana Foundation, Colosseum, Jupiter, Metaplex, MagicBlock, Helius, Alchemy, SendAI, Solana Mobile and more — three installed by default, the rest on demand ([skill-packs.md](docs/skill-packs.md))
- **Agent teams** (opt-in, experimental) for multi-step workflows (architect → engineer → QA)
- **Progressive skill loading** that only loads context when needed (saves tokens)
- **A small always-on CLAUDE.md** carrying only the house rules and workflow a strong model would not infer; everything else is on demand

## Installer (recommended)

The installer copies the kit into a project: `.claude/` (agents, commands, skills, a `settings.json` with the permissions, sandbox and hooks, and a `security.json` naming the [firewall tier](#firewall-tiers) those rules came from), `CLAUDE.md`, `.mcp.json` and `.env`. It downloads the kit's latest release tag from GitHub into a temporary directory, which it deletes when done. It installs into the current directory, so go to your project's root first (replace `your-project` with its path):

```bash
cd your-project
```

```bash
curl -fsSL https://aikit.superteam.codes | bash
```

`aikit.superteam.codes` and `aikit.superteam.codes/install.sh` both redirect to [`install.sh` on `main`](https://raw.githubusercontent.com/solanabr/ai-kit/main/install.sh).

**Verify before you run it.** Same installer, with a review step: download it, read it, then run the copy you read.

```bash
curl -fsSL https://aikit.superteam.codes/install.sh -o /tmp/solana-ai-kit-install.sh
```

```bash
less /tmp/solana-ai-kit-install.sh
```

```bash
bash /tmp/solana-ai-kit-install.sh
```

When the installer finishes, start Claude Code in the project:

```bash
claude
```

Two things finish the install from inside Claude Code, and both are part of a standard setup rather than extras: **[memsearch](#persistent-memory-memsearch)**, so the project's decisions survive the end of a session, and **[the language server plugins](#code-intelligence-language-server-plugins)**, so the agent reads your code through a compiler instead of grep.

```text
/plugin marketplace add zilliztech/memsearch
/plugin install memsearch
/plugin install rust-analyzer-lsp@claude-plugins-official
/plugin install typescript-lsp@claude-plugins-official
/plugin install csharp-lsp@claude-plugins-official
```

Take the LSP lines for the languages you actually write — Rust for programs, TypeScript for the client, C# for the Unity/PSG1 track — and install each language server first, since Claude Code offers the plugin once the binary is on your `PATH`. memsearch needs a restart.

Then `/setup-mcp` for the Helius API key. Everything past that point is genuinely optional: the [opt-in MCP servers](docs/configuration.md#optional-mcp-servers) and the [optional plugins](docs/configuration.md#optional-plugins).

### Other ways to install

Codex, opencode and anything else that reads `AGENTS.md` and `.agents/skills/` instead of Claude Code's files:

```bash
curl -fsSL https://aikit.superteam.codes | bash -s -- --agents
```

| Route | Use it when |
|-------|-------------|
| [From a clone](docs/install.md#from-a-clone) | You want to pin a release, or read every file before it reaches your project |
| [`--agents`](docs/install.md#codex-opencode-and-other-agents) | Your tool reads `AGENTS.md` and `.agents/skills/` — see [what each harness enforces](docs/other-agents.md) |
| [No install](docs/install.md#no-install-read-the-kit-from-aikitsuperteamcodes) | You want the skills in any agent without adding files to your project |
| [Claude Code plugin](docs/plugin.md) | Not recommended — read that page before you use it |
| [GitHub template](docs/install.md#using-as-a-github-template) | You are starting a new repository from the kit rather than adding it to one |

Already installed? `bash .claude/bin/update.sh`, or `/update` inside Claude Code ([details](docs/install.md#updating)). Working in a fork or clone of this repo? Its top-level `CLAUDE.md` is for maintaining the kit itself; `/cleanup` swaps in `CLAUDE-solana.md`.

### Config is gitignored by default

To keep your project clean, the installer adds `.claude/`, `CLAUDE.md`, `.mcp.json`, `.gitmodules` and `.safe-ai-skill/` to `.gitignore` — the kit reads as ignorable infrastructure, not your app code (the `ext/` skill packs are ignored too; `bash .claude/bin/update.sh` re-fetches the core packs and the project's extensions).

Want the config tracked in git (team setup, reproducible config)? Run `/commit-claude-config` — it un-ignores those files and commits them (or edit `.gitignore` by hand). If your project already commits `.claude/` or its own `.gitmodules`, the new ignore lines are a no-op — git keeps tracking files it already tracks.

### MCP setup

After installation, configure the MCP servers from inside Claude Code in your project:

```text
/setup-mcp
```

This guides you through the Helius API key and offers the [optional MCP servers](docs/configuration.md#optional-mcp-servers) — including the ones that sign transactions or reach a production database, with what each exposes before you attach it. Beyond the standard plugins above, Anthropic's marketplace has more worth adding and some that collide with the firewall: [which ones, and what each costs per session](docs/configuration.md#optional-plugins).

### Persistent memory: memsearch

Of everything in the standard install, this is the one that changes how the kit feels day to day. A Solana project accumulates context that is expensive to rediscover: which program ID is live on which cluster, the account layout you settled on and the reason you rejected the other one, the approach that failed, the protocol quirk that cost you an afternoon. Without persistent memory every session starts cold — the agent re-derives it, re-asks you, or quietly re-makes a decision you already threw out.

[memsearch](docs/configuration.md#persistent-memory-memsearch) gives it semantic recall over markdown you own, so the store can grow without the always-on context budget growing with it. That is the opposite trade from putting more in `CLAUDE.md`, which every session and every subagent pays for whether it is relevant or not. Markdown stays the source of truth, so your memory stays diffable, reviewable and portable.

Nothing leaves your machine: a local Milvus Lite store and an ONNX `bge-m3` embedder on CPU, no key and no account. Setup costs a ~558 MB model download on first launch and one restart; per session it costs four hooks and ~400 tokens of skill descriptions, plus the recent-memory preview its `SessionStart` hook injects — [the measured breakdown](docs/configuration.md#standard-plugins).

```text
/plugin marketplace add zilliztech/memsearch
/plugin install memsearch
```

It is a plugin, not an MCP server. `memsearch-mcp` was never published to npm, so an `.mcp.json` entry for it silently never starts — `/doctor` flags that entry if an older install still carries one, and `/update` removes it.

### Code intelligence: language server plugins

The other half of the standard install. Without a language server the agent navigates your code by reading files and matching text; with one it asks the compiler — go-to-definition, find-all-references, the real type of a value, the diagnostics your editor shows. On a Solana project that is three servers for three languages: Rust for the programs, TypeScript for the client and frontend, C# for the Unity/PSG1 track.

```text
/plugin install rust-analyzer-lsp@claude-plugins-official
/plugin install typescript-lsp@claude-plugins-official
/plugin install csharp-lsp@claude-plugins-official
```

**Install the language server itself first** — `rustup component add rust-analyzer`, `npm i -g typescript typescript-language-server`, and a C# server such as `csharp-ls` — and Claude Code then offers the matching plugin once the binary is on your `PATH`. Install only the ones whose language you write.

These are the cheapest additions in the kit: no hook, nothing registered in the session listing, so the standing context cost is about zero and an idle one is free. Skip a language and you simply skip its plugin.

### Security firewall: safe-ai-skill

[safe-ai-skill](https://github.com/solanabr/safe-ai-skill) is a core part of the kit. It is a Claude Code plugin whose hooks gate mainnet, value-moving and authority actions, block reads of keypairs and `.env`, and pin installed skills and MCPs at session start. The kit's `stbr` marketplace lists it next to the kit plugin, pinned to a specific commit.

- **Plugin install:** `solana-ai-kit@stbr` depends on `safe-ai-skill@stbr`, so installing the kit installs it.
- **Full install:** `.claude/settings.json` registers the `stbr` marketplace and enables `safe-ai-skill@stbr`. After you trust the folder, Claude Code reports the plugin as enabled but not installed until you run `claude plugin install safe-ai-skill@stbr --scope project` once.
- **`--agents` install (Codex, opencode):** the hooks are Claude Code only. Vet add-ons with the CLI instead: `npx @stbr/safe-ai-skill add skill|mcp <source>`.

Its engine ships prebuilt for macOS and Linux (x64, arm64) and fails closed elsewhere, such as native Windows. To turn it off for yourself in a full install, set `"safe-ai-skill@stbr": false` under `enabledPlugins` in `.claude/settings.local.json`.

**Project policy.** The full install writes `.safe-ai-skill/policy.yaml`, which safe-ai-skill deep-merges over its default policy. It sets one key, `supply_chain.verify_skills_dirs: [".claude/skills"]`, so the session-start check covers this project's skills and no longer sweeps your personal `~/.claude/skills`. `install.sh` writes it only when it is missing, and `/update` adds it to older installs, so your edits stay. The firewall denies the agent edits to it at every tier — unlike `.claude/settings.json`, which only [High](#firewall-tiers) protects: this file is a third-party security tool's policy rather than part of the installation you customize. It is gitignored with the rest of the kit config; run `/commit-claude-config` so teammates who clone the repo get it too.

The policy leaves `verify_ext_submodules` at its default, `true`, so each `ext/` pack is checked on its own. Setting it to `false` would scan all of `ext/` as one skill, and one finding would quarantine every pack. The check's heuristics are plain substring matches, so a pack whose docs mention a keypair path (the core `solana-dev` pack does) can still be quarantined at session start. That needs an upstream fix ([solanabr/safe-ai-skill#5](https://github.com/solanabr/safe-ai-skill/issues/5)).

## Firewall tiers

One tier is in force per project. `.claude/security.json` names it; `/firewall` (or `/firewall <tier>`) switches it and rewrites the kit-owned rules in `.claude/settings.json` to match. The default is **Relaxed**. A switch takes effect in the **next** session: permission and sandbox rules are read once at session start, so the session you are in keeps the rules it started with, whether the change was a tightening or a loosening.

The hooks also gate `context-mode`'s MCP tools at every tier, and Medium and High refuse its code executor and arbitrary-path reader outright — a local MCP server runs outside the OS sandbox, so the two stricter tiers cannot keep their read and egress promises while it is callable. High additionally refuses the opt-in Cloudflare server's `execute` tool, keeping its read-only `docs` and `search`; Playwright is gated by no tier. [Details](docs/firewall.md#what-the-tiers-do-not-do).

**High is also the only tier that stops the agent editing the kit's own configuration** — `.claude/settings.json`, `.claude/security.json`, `.mcp.json` and the user-scope equivalents under `~/.claude/`. Off, Relaxed and Medium allow it, on the view that customizing your own installation is your call. **The guard hooks are the exception and are denied at every tier**, Off included: `.claude/hooks/` holds the mainnet, secrets and on-chain gates as executable scripts, and `/firewall` already changes every tier knob without touching them, so customizing never means editing a guard. So below High you own your `.claude/` *configuration*, not the guards. A nested `claude --dangerously-skip-permissions`, an organization's managed settings and `safe-ai-skill`'s policy are also denied at every tier. [Details](docs/firewall.md#what-the-tiers-do-not-do).

| Tier | Readable | Writable | On-chain and destructive | Use it for |
|------|----------|----------|--------------------------|------------|
| **Off** | Everything your user account can read. The sandbox is off. | Everything. | The hooks still run: mainnet and authority writes stop for approval, irreversible ones are refused — `--final`, `program-v4 finalize`, `spl-token authorize --disable`, and `solana-keygen new --force` over your default wallet. The deny rules apply here too, the git transport overrides and `gh issue delete` included. | A machine you have already isolated — a container or throwaway VM — or a session where you supply your own policy in `~/.claude/settings.json`. |
| **Relaxed** (default) | Leaves open: your Solana config dir (so `solana config get` and `anchor`'s `wallet =` keep working), the project's `.env`, and host credential files outside the never-allowed set — cloud, registry and git-host tokens such as `~/.aws`, `~/.netrc`, `~/.git-credentials`, `~/.npmrc` and the `gh` host file. Denies the never-allowed set: SSH and GPG keys, keychains and keyrings, browser profiles and wallet extension stores, shell startup files, shell and REPL history, `~/.cargo/config.toml` and `~/.cargo/credentials*`, `~/.gitconfig`. | The repo, the platform temp dir, the toolchain caches (`~/.cargo`, `~/.rustup`, `~/.avm`, the Solana caches) and the project's `.env`. Writes outside the repo are allowed. | Mainnet writes stop for your approval on every cluster, naming the cluster it resolved. `--final`, program close, `spl-token authorize --disable` and `solana-keygen new --force` over your default wallet are refused outright. `npm`/`cargo publish` ask. Force push, `gh pr merge` and git history rewrites are allowed — this is your own repo. | **Local development.** Your own machine and your own repo, where the toolchain should just work. Also the tier to run headless — see [docs/firewall.md](docs/firewall.md#what-the-tiers-do-not-do). |
| **Medium** | Relaxed's denials, plus the Solana config dir's `*.json` (the wallet files; `cli/config.yml` stays readable), session transcript `*.jsonl`, and the host credential files Relaxed leaves open. | The repo and the toolchain carve-outs. Writes outside the repo ask. The project's `.env` becomes **write-deny** — nothing in a Solana build legitimately rewrites it, and an ask there is walked around by `python3 -c`, `perl -pi` or `sed -i`. | As Relaxed, plus `npm`/`cargo publish` and `gh api` denied, and force push and `gh pr merge` ask. | Reading code you did not write — audits, dependency triage, a repo you cloned to look at. Interactive sessions only. |
| **High** | Only the working directory and the toolchain roots the build needs. `permissions.blockReadsOutsideWorkingDirectories` is on and the sandbox denies `~/` with a narrow `allowRead` carve-out for `~/.cargo`, `~/.rustup` and the Solana caches. The project's `.env` becomes read-deny. | The repo plus those toolchain roots (cargo needs *write* to the registry cache or the build dies); everything else outside the repo is denied. The project's `.env` stays writable, since the model can no longer read it back. | Mainnet writes are denied outright rather than asked, and so are force push and `gh pr merge`. The recoverable history rewrites ask: `git rebase`, `git commit --amend`, `git stash drop`/`clear`, `git branch -d`, `git tag -d` and `git filter-branch`/`filter-repo`. | A repo you actively distrust, or a session on a machine that holds production credentials. Interactive sessions only. |

Which gate stops what, how a tier is generated, and — at length — **what the tiers do not do**: [docs/firewall.md](docs/firewall.md). Short version: High and Medium are interactive-only, an allowlist is not something the kit can enforce, an MCP server runs outside the sandbox so only the hooks reach it (and at Medium and High `context-mode`'s executor is refused outright, at High Cloudflare's too), and the tier is not immune to the agent.

## Full documentation

[`docs/`](docs/) is the kit's full spec. It is not copied into your project.

| Document | What it covers |
|----------|----------------|
| [install.md](docs/install.md) | Every install route in full, pinning a release, `--agents`, the no-install route, GitHub template, updating |
| [firewall.md](docs/firewall.md) | Permission and safety gates, tier generation, and the limits of all of it |
| [agents-and-commands.md](docs/agents-and-commands.md) | All 15 agents with their models, all 32 commands, agent teams |
| [skill-packs.md](docs/skill-packs.md) | The pinned `ext/` packs, core vs extension, the opt-in add-on registry |
| [other-agents.md](docs/other-agents.md) | Codex, Grok Build, Cursor, Gemini CLI, opencode: what each one actually enforces |
| [configuration.md](docs/configuration.md) | MCP servers including the opt-in ones, the standard plugins and the optional ones with what each costs per session, and the settings the kit leaves to you |
| [plugin.md](docs/plugin.md) | The plugin route and why it is not recommended |
| [design.md](docs/design.md) | Why the always-on context is small, and the 2026 stack |
| [repo-structure.md](docs/repo-structure.md) | Repository layout, DX scripts, the GitHub Action, branch and review workflow |

[QUICK-START.md](QUICK-START.md) is the two-minute version with usage examples per task. [FIREWALL-SPEC.md](FIREWALL-SPEC.md) is the verified spec behind the tiers.

## License

MIT - See [LICENSE](LICENSE)

## Disclaimer

**No warranty, and no liability.** This software is provided "as is", without warranty of any kind, express or implied, including without limitation the warranties of merchantability, fitness for a particular purpose and non-infringement. To the fullest extent permitted by applicable law, Superteam Brazil, its members and the contributors to this repository accept no liability for any claim, loss or damage — direct, indirect, incidental, special, consequential or exemplary, including loss of funds, keys, data, profits or goodwill — arising from or in connection with this software or its use, whether in contract, tort, negligence or otherwise, and whether or not advised of the possibility of such damage. You install and run it on your own systems, against your own keys, accounts and funds, and every action it helps you take remains your decision and your responsibility. Review what it does before you run it, especially anything that touches mainnet or moves value.

**What this repository contains, and what it does not.** This is a configuration layer and an index. It contains Superteam Brazil's own work — the agents, commands, skills, rules, hooks and settings written here — together with references to third-party projects. Those third-party projects are identified by their canonical repository URL and a recorded commit, and they are retrieved directly from their own publishers at install time, by the same public mechanisms any user would use unaided: `git submodule`, `git clone`, `npx`, or a first-party plugin marketplace. Third-party code is not rehosted, mirrored, bundled, modified or redistributed by this repository, and none of it is served from here. Removing a reference removes nothing but the reference.

**Ownership, attribution and independence.** Every referenced project remains the property of its own authors and is governed exclusively by the terms its authors attach to it, which travel with the project when it is retrieved. Nothing here asserts ownership of, or claims credit for, any third-party work, and no part of the wider stack is presented as this project's own. Inclusion is not endorsement in either direction: no affiliation with, sponsorship by, or approval from any referenced project, protocol, company or foundation is claimed or implied. Product names, trademarks and logos belong to their respective owners and appear only to identify the software they refer to, as nominative reference.

**No charge.** This repository is distributed free of charge. Nothing in it is sold, rented, licensed for a fee or placed behind a paywall, no payment is solicited or accepted for access to it, and no revenue is derived from the third-party projects it references.

**Maintainer requests.** If you maintain a project referenced here and would like the reference amended, attributed differently, or removed, open an issue in this repository and it will be actioned.
