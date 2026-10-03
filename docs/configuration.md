# Configuration

What the kit configures for you, what it leaves to you, and the MCP servers that are not on by default.

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

Two caveats on those last two. **Chainstack lists every tool whether or not a key is configured**, so a keyless install looks complete and fails at the call; node deployment, project management and testnet funding all need `--header "Authorization: Bearer <key>"`. **Nansen answers nothing without a key**, and it loads roughly 50 tool schemas into every session it is attached to — a standing context cost for something most projects never call, so attach it for analytics work and detach it after.

**Playwright is the opt-in server with no gating at all.** `browser_network_request` is an arbitrary HTTP client, and no firewall tier touches it — unlike `context-mode`, it has no hook matcher and no tier deny. Attaching it voids the egress guarantee at every tier.

**Phantom is documented here but deliberately not offered by `/setup-mcp`.** It is 29 tools and not a wallet reader: `solana_sign`/`solana_send` and `evm_sign`/`evm_send` land signed transactions, and `buy`, `pay`, `transfer`, `wallet_rebalance`, `withdraw_from_hyperliquid_spot` and nine `perps_*` tools move real funds. It needs no key once `phantom_login` has run — the session lives on disk — so nothing stands between an attached server and a trade. If you want it, you add it yourself: `claude mcp add phantom -- npx -y @phantom/mcp-server`.

## Persistent memory: memsearch

Memory across sessions is not an MCP server. Zilliz ships [memsearch](https://github.com/zilliztech/memsearch) as a Claude Code **plugin**; there is no official memsearch MCP server, and the `memsearch-mcp` npm package the kit used to list in `.mcp.json` is not published, so that entry never started. `/doctor` flags a leftover `memsearch` entry, and `/update` removes it.

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

Optional, and not part of the install: Zilliz Cloud (managed, free tier) if you want memory shared across machines or a team, or self-hosted Milvus via Docker. Both are alternatives to the local file, not prerequisites.

## Settings the kit leaves to you

`.claude/settings.json` ships the sandbox, permission rules, hooks and attribution, registers the `stbr` marketplace (`extraKnownMarketplaces`) and enables `safe-ai-skill@stbr`, and pins nothing about how Claude works. Its permission and sandbox block is generated from the [firewall tier](../README.md#firewall-tiers) and rewritten whole when the tier changes, so edit the tier with `/firewall` rather than the block. Turn these on yourself with the command shown or in `.claude/settings.local.json`, which `/update` never touches:

- **Effort**: `/effort` (the kit no longer forces `max`)
- **Agent teams**: `{"env": {"CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"}}`, see [Agent Teams](agents-and-commands.md#agent-teams)
- **Code intelligence**: install the language server, then `/plugin install rust-analyzer-lsp@claude-plugins-official` (or `typescript-lsp`, `csharp-lsp`). Claude Code offers the matching plugin once the server is on your `PATH`
- **MCP auto-approval**: `"enableAllProjectMcpServers": true` skips the approval prompt for every server in `.mcp.json`

`/update` removes these keys and the retired MCP servers from files written by kit 2.1.0 or earlier, but only where they still hold the kit's value.
