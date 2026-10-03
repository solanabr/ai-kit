# Configuration

What the kit configures for you, what it leaves to you, and the MCP servers that are not on by default.

## MCP servers

Three servers are on by default in `.mcp.json` (API keys go in `.env`). Claude Code asks once per project before it starts them, so approve the ones you want. `/setup-mcp` walks through the Helius API key and offers the optional servers below.

| Server | Capabilities |
|--------|-------------|
| **Helius** | RPC, DAS API, parsed transactions, webhooks, priority fees, token and NFT data |
| **solana-dev** | Solana Foundation official MCP (remote HTTP): Solana docs, guides, and API references |
| **Context7** | Up-to-date library documentation lookup |

### Optional MCP servers

These need a browser, a CLI or a workflow choice, so they are not started by default. Add one for yourself with `claude mcp add` (add `--scope project` to share it through `.mcp.json`):

| Server | Add with | Needs |
|--------|----------|-------|
| **Playwright**: browser automation for dApp testing | `claude mcp add playwright -- npx -y @playwright/mcp@latest --headless` | A browser Playwright can launch |
| **Surfpool**: local validator / mainnet-fork control | `claude mcp add surfpool -- surfpool mcp` | The `surfpool` CLI (`brew install txtx/taps/surfpool`) |
| **context-mode**: keeps large tool output out of context | `claude mcp add context-mode -- npx -y context-mode@latest` | Nothing |

Playwright and context-mode are also the two servers that void the egress guarantee at every firewall tier: one is an arbitrary HTTP client, the other an arbitrary executor that runs commands outside the Bash tool. That is the reason they are opt-in — see [firewall.md](firewall.md#what-the-tiers-do-not-do).

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
