# Configuration

What the kit configures for you, what it leaves to you, the MCP servers that are not on by default, and the Claude Code plugins alongside them — the four a standard install adds, and the ones worth considering after that.

## MCP servers

Four servers are on by default in `.mcp.json` (API keys go in `.env`). Claude Code asks once per project before it starts them, so approve the ones you want. `/setup-mcp` walks through the Helius API key and offers the optional servers below.

| Server | Capabilities |
|--------|-------------|
| **Helius** | RPC, DAS API, parsed transactions, webhooks, priority fees, token and NFT data |
| **solana-dev** | Solana Foundation official MCP (remote HTTP): Solana docs, guides, and API references |
| **Context7** | Up-to-date library documentation lookup |
| **context-mode** | Keeps large tool output out of the context window (no key; needs Node 22.5+) |

**`context-mode` is the one default server with a code executor**, so it is also the one the firewall has an opinion about. `ctx_execute` runs shell, Python, JavaScript, Go, Rust and more in a subprocess, and like every local MCP server it runs outside the OS sandbox — `ls ~/.claude/ide` is refused through Bash and succeeds through it. The kit's three `PreToolUse` guards therefore match its tools as well as Bash, so a credential read, a mainnet write or a denied egress host in a `ctx_execute` payload is gated the way the shell equivalent is; and **Medium and High deny `ctx_execute`, `ctx_execute_file`, `ctx_batch_execute`, `ctx_fetch_and_index` and `ctx_index` by name**, keeping only the search and stats tools. If you want the compression without the executor at Relaxed, drop the server from `.mcp.json`. Full reasoning, and what the gating does not cover, in [firewall.md](firewall.md#what-the-tiers-do-not-do).

### Optional MCP servers

These need a browser, a CLI, a key or a workflow choice, so they are not started by default. Add one for yourself with `claude mcp add` (add `--scope project` to share it through `.mcp.json`):

| Server | Add with | Needs |
|--------|----------|-------|
| **Playwright**: browser automation for dApp testing | `claude mcp add playwright -- npx -y @playwright/mcp@latest --headless` | A browser Playwright can launch |
| **Surfpool**: local validator / mainnet-fork control | `claude mcp add surfpool -- surfpool mcp` | The `surfpool` CLI (`brew install txtx/taps/surfpool`) |
| **Chainstack**: multi-chain RPC platform control | `claude mcp add --transport http chainstack https://mcp.chainstack.com/mcp` | Nothing for 5 read-only tools; a key for the rest |
| **Nansen**: wallet and token intelligence | `claude mcp add --transport http nansen https://mcp.nansen.ai/ra/mcp --header "NANSEN-API-KEY: <key>"` | A paid Nansen API key (free tier within credits); ~50 tool schemas per session |
| **Supabase**: the Postgres backend behind an indexer or dApp | `claude mcp add --transport http supabase "https://mcp.supabase.com/mcp?read_only=true&project_ref=<ref>"` (drop the parameters for write access) | A Supabase account (the server starts its own auth flow; nothing answers unauthenticated) |
| **Cloudflare**: operate the Workers, KV, R2, D1, DNS and Queues behind a dApp | `claude mcp add --transport http cloudflare https://mcp.cloudflare.com/mcp --header "Authorization: Bearer <token>"` | A narrowly scoped [Cloudflare API token](https://dash.cloudflare.com/profile/api-tokens), or OAuth if you drop the `--header` |
| **Phantom**: a wallet and trading surface — signing, sending, swaps, payments and perps | `claude mcp add phantom -- npx -y @phantom/mcp-server` | A Phantom wallet; `phantom_login` sets up the session and no key goes in a config file |

Two caveats on Chainstack and Nansen. **Chainstack lists every tool whether or not a key is configured**, so a keyless install looks complete and fails at the call; node deployment, project management and testnet funding all need `--header "Authorization: Bearer <key>"`. **Nansen answers nothing without a key**, and it loads roughly 50 tool schemas into every session it is attached to — a standing context cost for something most projects never call, so attach it for analytics work and detach it after.

**Supabase is listed read-only and project-scoped because that is the right default, not because the other form is off-limits.** Which one you want depends on the work: reading your indexer's tables is the common case, and applying a migration from the agent is a real one. What the two query parameters change, exactly:

- **`read_only=true`** hides the 12 write tools and forces `execute_sql` into a read-only Postgres session. The server exposes 36 tools, 13 of them not read-only; an unflagged install gets `DEFAULT_FEATURES`, which is 31 tools of which 12 write.
- **`project_ref=<ref>`** drops the entire `account` group, which is what removes cross-project reach and `create_project`.

Drop either or both when you want what they withhold — write access to one project, or account-level reach across projects. Three things are worth knowing whichever form you pick:

- **`execute_sql` is an unrestricted SQL channel into your app's Postgres** — `DROP`, `DELETE` and `TRUNCATE` included, with no statement filtering — and `apply_migration` is the same reach with DDL. Pointed at a production project, that is the hazard. `create_project` and `create_branch` also spend money; preview branches are billed hourly on paid plans until deleted.
- **`https://mcp.supabase.com/mcp` is the server; `https://mcp.supabase.com/api/mcp` is a documentation page.** Same host, adjacent path, and the wrong one returns HTML rather than an error you'd notice. Copy the path exactly.
- **The stdio form's `SUPABASE_ACCESS_TOKEN` is an account-wide personal access token**, reaching every organization and project you belong to: `npx -y @supabase/mcp-server-supabase@latest --read-only --project-ref=<ref>`. `--project-ref` narrows what the server does with the token, not what the token can do — it stays a full-account credential sitting in your environment, which is why the HTTP form above is the one listed.

Unlike Chainstack there is no keyless half to mis-describe: `POST initialize` answers 401 even with `?features=docs`, so the server tells you nothing until you have signed in. One more form worth knowing about: **`?features=docs` narrows the server to documentation lookup alone**, which is what Supabase's own repository pins in its `.mcp.json`. If documentation is all you were after, the `supabase` skill pack ([skill-packs.md](skill-packs.md)) covers that ground with no credential at all.

**Cloudflare's selling point is its context cost, and that is also what hides its reach.** `cloudflare/mcp` exposes the entire Cloudflare API — 2,594 endpoints — through **three** tools, because the OpenAPI spec stays on the server and the agent writes JavaScript against it: `docs` searches Cloudflare's developer documentation, `search` runs code against `spec.paths` to find endpoints, and `execute` runs code calling `cloudflare.request()`. Three tools cost about 1,100 tokens. The same server with `?codemode=false` registers a tool per endpoint and costs ~244,000, so code mode is the form to use — but it means **one of the three tools is the whole write API**, and a tool count tells you nothing about it. The README's own first examples are creating a KV namespace and adding a DNS A record; `execute` will equally deploy a Worker, edit a zone's records or purge a Queue.

So the lever is the credential, which is why it is offered rather than only documented: **`execute` can reach exactly what the token can reach, and you choose the token's scopes.** Create one scoped to the specific zone or account resources you want reachable rather than reusing a broad token — for an account token, add `Account Resources : Read` so the server can auto-detect the account ID (the README recommends it; nothing enforces it, and nothing stops a token that is wider). The OAuth path instead asks you to pick permissions on Cloudflare's consent screen, which is fine interactively but leaves no artifact to review later. Two smaller notes: tokens with Client IP Address Filtering enabled are not supported, and each tool result is capped at ~6,000 tokens unless you pass `?truncateToolResult=false`. Nothing answers unauthenticated — `POST initialize` returns 401 — so there is no keyless half to try first.

Two more things. **`execute` is a code executor the firewall reaches at exactly one tier.** [High denies `mcp__cloudflare__execute`](firewall.md#what-the-tiers-do-not-do) by exact tool name, leaving `docs` and `search` callable; Off, Relaxed and Medium do not, and the hooks' matcher (`Bash|mcp__context-mode__.*`) does not cover it either, so below High the token's scopes are the only boundary — which is the whole reason the hardening above is the credential. Medium is deliberately not included: `context-mode` ships on by default and both gated tiers have to speak for a user who never chose it, while attaching Cloudflare is itself a decision. Note that the deny matches the server *name*, so add it as `cloudflare` (as above) if you want High's rule to apply, and avoid the `?codemode=false` form, whose ~2,500 per-endpoint tools the rule does not name.

And the kit already pins a `cloudflare` **skill** pack ([skill-packs.md](skill-packs.md)), which is a different thing, not a lesser one: 16 skills and 52 reference folders — Workers, Durable Objects, Wrangler, the Agents SDK, ten files on Queues and Workflows alone — with no credential and no reach into an account. Reach for the pack to write Worker code, the server to change what is deployed.

**Playwright is the other opt-in server with no gating at all.** `browser_network_request` is an arbitrary HTTP client, and no firewall tier touches it — unlike `context-mode`, it has no hook matcher and no tier deny. Attaching it voids the egress guarantee at every tier.

**Phantom is the one opt-in server that acts on your funds rather than reporting on them**, and the 29 tools are worth reading before you attach it. `solana_sign`/`solana_send` and `evm_sign`/`evm_send` land signed transactions. `buy`, `pay`, `transfer`, `wallet_rebalance`, `withdraw_from_hyperliquid_spot` and nine `perps_*` tools (open, close, leverage, deposit, withdraw) move real funds. Authentication is `phantom_login`, which keeps the session on disk, so no key goes in a config file — and equally, nothing re-prompts between an attached server and a trade. No firewall tier denies its tools by name, though the kit's mainnet and value-movement hooks do not reach an MCP server either (`Bash|mcp__context-mode__.*` is the matcher), so at every tier the boundary is what the logged-in wallet holds. Attach it when you want the agent transacting — a bot, a payment flow, a position you are managing — and fund the wallet accordingly.

## Claude Code plugins worth installing

Skill packs are not the only thing you can attach. Claude Code has its own plugin system, and Anthropic's official marketplace lists **315 plugins**: 39 Anthropic-authored under `plugins/`, 14 thin MCP wrappers under `external_plugins/`, and 262 external repositories. Claude Code registers that marketplace itself the first time you start an interactive session, so there is no `marketplace add` step — install by name:

```text
/plugin install rust-analyzer-lsp@claude-plugins-official
```

A plugin is not a skill pack. It can carry hooks, MCP servers, agents, commands, skills and language servers at once, all running with your user permissions and outside the OS sandbox, so [plugin.md](plugin.md)'s caveats apply to any plugin — that page is about installing *this kit* as one, which is a different question from whether to install someone else's.

**The first thing to check is whether a plugin ships a hook**, because a `SessionStart` hook is a cost you pay every session whether or not you use the plugin. Seven of the 39 first-party plugins have a `hooks/` directory: `claude-security`, `code-modernization`, `explanatory-output-style`, `hookify`, `learning-output-style`, `ralph-loop` and `security-guidance`. The second thing is the standing cost of what it registers — skill, command and agent descriptions all load into every session — which is why a hook-free plugin can still be the expensive one. Both numbers are below, measured as characters over four.

### Standard plugins

Four plugins are part of a standard install rather than extras. Two commands add memory; three more add code intelligence, one per language you write. The three LSP plugins are free standing; memsearch is the one that costs something, and what it spends is your own project history:

```text
/plugin marketplace add zilliztech/memsearch
/plugin install memsearch
```

```text
/plugin install rust-analyzer-lsp@claude-plugins-official
/plugin install typescript-lsp@claude-plugins-official
/plugin install csharp-lsp@claude-plugins-official
```

| Plugin | What it gives a Solana project | Standing cost per session |
|--------|-------------------------------|---------------------------|
| `memsearch` | Semantic recall over markdown you own, so a project's decisions, dead ends and live program IDs survive the end of a session instead of being re-derived. Local store, no key, no account — [full section below](#persistent-memory-memsearch) | 4 hooks, 3 skills: ~400 tokens of descriptions, plus whatever the `SessionStart` hook injects (below) |
| `rust-analyzer-lsp`, `typescript-lsp`, `csharp-lsp` | Code intelligence for programs, the frontend, and the Unity/PSG1 track: go-to-definition, references, real types and the compiler's own diagnostics, instead of navigating by text match | No hook, nothing registered: ~0 |

**memsearch is the one standard plugin with hooks, and it is worth being precise about them**, since the rule above is to check for a hook first. Version 0.4.13 registers four: `SessionStart`, `UserPromptSubmit`, and an async `Stop` and `SessionEnd`. The `SessionStart` one injects a preview of up to 40 lines from each of your two most recent daily memory files, so unlike an instruction-injecting hook the tokens it spends are your project's own history — the thing you installed it for — and the three skill descriptions add ~1,600 characters, about 400 tokens. It comes from Zilliz's own marketplace, which is why it takes the extra `marketplace add` line, and it does not activate until you restart Claude Code. Its one other cost is a ~558 MB embedding model downloading on first launch.

**The LSP plugins need the language server itself installed first** — `rustup component add rust-analyzer`, `npm i -g typescript typescript-language-server`, a C# server such as `csharp-ls` — and Claude Code then offers the matching plugin once the binary is on your `PATH`. Install the ones whose language you write and skip the rest; there is no cost to a missing one and no benefit to a plugin whose server is absent.

### Optional plugins

Worth considering, none of them assumed:

| Plugin | What it gives a Solana project | Standing cost per session |
|--------|-------------------------------|---------------------------|
| `code-review` | A second pass over the diff with confidence-scored findings. It reads for generic correctness where `/diff-review` and `/audit-solana` read for PDA, CPI and arithmetic classes, so they stack | No hook, 1 command: ~6 tokens |
| `session-report` | An HTML report of tokens, cache efficiency, subagents and skills from your local transcripts. The kit budgets context deliberately; this is how you check the budget held | No hook, 1 skill: ~38 tokens |
| `skill-creator` | Authoring, evaluating and benchmarking skills — useful if you write a local skill or a pack of your own | No hook, 1 skill: ~80 tokens |
| `mcp-server-dev` | Designing an MCP server (deployment models, tool design, auth) for your own indexer or RPC | No hook, 3 skills: ~336 tokens |
| `superpowers` | TDD, systematic debugging, brainstorming and plan-execution discipline, as 15 skills | `SessionStart` hook: **~1,450 tokens** (below) |
| `plugin-dev` | Hooks, MCP, commands and agents for authoring plugins — relevant to this repository's own `plugin/` subtree | No hook, but 7 skills + 3 agents: **~1,676 tokens**, the priciest here. Install while authoring, remove after |

**On `superpowers`, which is the one people ask about.** Its `SessionStart` hook — matching `startup|clear|compact`, so it fires again on every `/clear` and every compaction — injects the full 3,192 characters of its `using-superpowers/SKILL.md` wrapped in `<EXTREMELY_IMPORTANT>`, about 798 tokens, and its 15 skill descriptions add ~2,617 characters, so budget roughly **1,450 tokens per session, unconditionally**. The content is clear and compact for what it does. Three things to know anyway: it is an external entry, not a first-party one — every `./plugins/*` folder in the marketplace carries `author: Anthropic` and this one carries no `author` field at all, so it has none of the first-party standing that `code-review` or `code-simplifier` do, and it moves on its author's schedule rather than Anthropic's. Its `<EXTREMELY_IMPORTANT>` framing also runs against this repository's house style of stating rules calmly and giving the reason, so expect a tonal clash with `CLAUDE.md`. And **`npm install superpowers` is not it**: that package is an unrelated 2022 stub, version 0.0.2, maintainer `01studio`, with the literal description `> TODO: description`. The plugin is the only correct route.

**Install external plugins from `claude-plugins-official`, not from the author's own marketplace, and this is the reason.** Every one of the 262 remote entries there is pinned to a specific commit — 262 of 262 carry a `sha` — so you get the commit Anthropic listed. Add the upstream marketplace instead and you get whatever its own entry resolves to, which is usually the default branch. `superpowers` is the worked example: Anthropic pins `5bf4e78`, while `obra/superpowers`' own marketplace (named `superpowers-dev`) declares `"source": "./"`, so installing from there follows HEAD — `8ca22db` at the time of writing, declaring 6.4.2 where the pin resolves to 6.4.1. Same plugin, same author, different and moving code. The property generalises to all 262.

Name confusion is the other reason. Anthropic also publishes a community marketplace, `claude-community`, with 2,283 entries that Claude Code does **not** add on its own; alongside the real `obra/superpowers` it lists eight more entries whose names contain "superpowers" — `superpowers-optimized`, `decibel-superpowers`, `sdd-superpowers`, `superpowers-beads`, `ux-superpowers`, `zsl-superpowers`, `ai-craftsman-superpowers`, `superpower-builder` — plus `ultrapowers`, all from accounts with no track record in this space, and two of them pointing at repositories literally named `superpowers` under a different owner. Read the `@marketplace` suffix, not the plugin name.

### Left out, and why

- **`hookify` conflicts rather than overlaps.** It installs its own `PreToolUse`, `PostToolUse`, `Stop` and `UserPromptSubmit` hooks that gate tool calls from rules in markdown files — which is the job of this kit's [firewall](firewall.md) and of `safe-ai-skill`. Two independent hook layers deciding on the same events is not defence in depth; it is two policies with no defined precedence, and a `deny` you cannot attribute.
- **`security-guidance` duplicates the review for the wrong bug classes.** Its hooks fire on `SessionStart` — with a 180-second budget, because on first run it builds a venv under `~/.claude/security/` and pip-installs the Agent SDK into it — then on *every* `UserPromptSubmit`, and on every `Edit`/`Write` plus `git commit` and `git push`. What it looks for is injection, XSS, SSRF and hardcoded secrets: real, but not the classes that break a Solana program, which `/audit-solana`, the `auditor-skill` pack and the kit's own secrets gate already cover.
- **`claude-security`** has no unconditional hook (its `PostToolUse` entries are `if`-guarded to its own scripts, `git push` and `gh pr create`), but it registers 9 agents for ~570 tokens a session to cover ground `/audit-solana` and the `cso` skill already hold — a standing cost for a second opinion on bug classes the kit already reads for.
- **`code-modernization`** is for legacy estates, not this audience, and carries a `SessionStart` telemetry hook plus ~860 tokens of command and agent descriptions.
- **`explanatory-output-style` and `learning-output-style`** inject 1,018 and 3,034 characters of instructions at `SessionStart` — ~254 and ~758 tokens, every session, unconditionally. `solana-guide` and the `virtual-solana-incubator` skill teach on demand instead, at no standing cost.
- **`pr-review-toolkit`** (~1,583 tokens of agent descriptions), **`commit-commands`**, **`claude-md-management`** and **`frontend-design`** each restate something the kit ships: `/diff-review` plus `code-review`, `/quick-commit`, the `CLAUDE.md` learning protocol with `/dream`, and, exactly, the `frontend-design` skill: the plugin's `SKILL.md` is byte-identical to the one the `anthropic-skills` extension already pins from `anthropics/skills`, so installing it gets you a second copy of a file the kit fetches at a commit it records.
- **The 14 `external_plugins/` entries are MCP servers in plugin clothing**, mostly a `.mcp.json` and a `plugin.json`. `claude mcp add` gets you the same server without adding a publisher. Two are worth naming: the `context7` wrapper points at the remote `mcp.context7.com/mcp` where the kit pins the local `@upstash/context7-mcp`, and the `playwright` wrapper runs `@playwright/mcp@latest` unpinned — attach either knowingly rather than ending up with two of one server.

## Persistent memory: memsearch

Part of a [standard install](#standard-plugins), and the detail behind that row. Memory across sessions is not an MCP server: Zilliz ships [memsearch](https://github.com/zilliztech/memsearch) as a Claude Code **plugin**; there is no official memsearch MCP server, and the `memsearch-mcp` npm package the kit used to list in `.mcp.json` is not published, so that entry never started. `/doctor` flags a leftover `memsearch` entry, and `/update` removes it.

Three steps, and the third is the one people miss:

```text
/plugin marketplace add zilliztech/memsearch
```

```text
/plugin install memsearch
```

Then **restart Claude Code** — the plugin does not activate until you do.

**No API key, no account, no backend.** Storage defaults to a local Milvus Lite file at `~/.memsearch/milvus.db`, and embeddings default to ONNX `bge-m3` running locally on CPU. "Vector memory backed by Milvus" reads like it needs a cloud account; it does not.

**The one real cost: a ~558 MB model downloads from HuggingFace on first launch.** Expect that on a metered or slow connection the first time you start Claude Code after installing.

**Checking that it works**, which is worth doing because capture is silent — daily markdown files appear here after a few conversations:

```bash
ls .memsearch/memory/
```

Those memories are plain markdown you can read, edit and commit; the Milvus index is a derived cache that can be rebuilt from them, not the source of truth. Recall is `/memory-recall <question>`, or just asking naturally — the skill self-invokes when a question needs history.

Note that `.memsearch/` lands in the **project** directory, not only in `~`. This repository's `.gitignore` lists it; `install.sh` does not add it to yours, so add `.memsearch/` to your project's `.gitignore` before you commit, or you will check in a memory index.

Beyond the standard install: Zilliz Cloud (managed, free tier) if you want memory shared across machines or a team, or self-hosted Milvus via Docker. Both are alternatives to the local file, not prerequisites.

## Settings the kit leaves to you

`.claude/settings.json` ships the sandbox, permission rules, hooks and attribution, registers the `stbr` marketplace (`extraKnownMarketplaces`) and enables `safe-ai-skill@stbr`, and pins nothing about how Claude works. Its permission and sandbox block is generated from the [firewall tier](../README.md#firewall-tiers) and rewritten whole when the tier changes, so edit the tier with `/firewall` rather than the block. Turn these on yourself with the command shown or in `.claude/settings.local.json`, which `/update` never touches:

- **Effort**: `/effort` (the kit no longer forces `max`)
- **Agent teams**: `{"env": {"CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"}}`, see [Agent Teams](agents-and-commands.md#agent-teams)
- **Code intelligence**: part of a standard install rather than a setting — install the language server, then `/plugin install rust-analyzer-lsp@claude-plugins-official` (or `typescript-lsp`, `csharp-lsp`). Nothing in `settings.json` turns these on; see [standard plugins](#standard-plugins)
- **MCP auto-approval**: `"enableAllProjectMcpServers": true` skips the approval prompt for every server in `.mcp.json`

`/update` removes these keys and the retired MCP servers from files written by kit 2.1.0 or earlier, but only where they still hold the kit's value.
