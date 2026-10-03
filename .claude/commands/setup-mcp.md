---
description: "Configure MCP server API keys in .env and add the optional MCP servers"
model: sonnet
---

Walk the user through filling in `.env`. Secrets go in `.env`, never in `.mcp.json`.

Never read `.env` — the firewall denies it at Medium and High, and a value read into the transcript has already left the machine. Appending is the only contact this command has with the file.

## Steps

1. Don't create `.env` yourself. If it may be missing, print this for the user to run and wait for them:
   ```bash
   cp .env.example .env
   ```
2. See which keys are already set, by name only:
   ```bash
   bash .claude/bin/env-keys.sh 2>/dev/null || echo "HELPER_UNAVAILABLE"
   ```
   It prints one `KEY set|empty` line per key and never a value. Skip keys it reports as `set` unless the user asks to replace one; for a replacement, print the edit for the user to make rather than rewriting the file. On `HELPER_UNAVAILABLE`, ask which keys they want to set instead of guessing.
3. For each remaining key below, in order, ask the user to paste a value or say "skip". Append accepted values; leave skipped keys alone; never echo a value back.
   ```bash
   printf '%s=%s\n' "$KEY" "$VALUE" >> .env
   ```
   Append, never read-modify-write: there is nothing to read first. If the append is refused (Medium denies `.env` writes), print the line for the user to run.

   MCP server key (the only one `.mcp.json` reads):
   - `HELIUS_API_KEY`: Helius RPC and DAS API for the `helius` MCP server (https://dev.helius.xyz)

   Optional skill/CLI keys, read at runtime by skill CLIs in `.claude/skills/ext/`, not by any MCP server:
   - `MISTRAL_API_KEY`: QEDGen formal-verification CLI, for `fill-sorry` and `generate` (https://console.mistral.ai)
   - `ARISTOTLE_API_KEY`: QEDGen formal-verification CLI, for the `aristotle` proof-search commands (https://aristotle.harmonic.fun)
   - `THEGRID_API_KEY`: TheGrid Colosseum project-graph queries (https://thegrid.id)
   - `THEGRID_GRAPHQL_ENDPOINT`: the default `https://beta.node.thegrid.id/graphql` works for most
   - `QUICKNODE_RPC_URL`, `QUICKNODE_WSS_URL`, `QUICKNODE_API_KEY`: QuickNode RPC, WebSocket/Streams and DAS for the `quicknode` skill (https://www.quicknode.com)
   - `X_BEARER_TOKEN`: X API bearer token for the `ct-alpha` CT research skill (https://developer.x.com)
   - `DFLOW_API_KEY`: DFlow order-flow integration skill (credentials from hello@dflow.net)

   Not an env key: the core `colosseum` skill signs in through its own helper, which keeps the credential in the OS store. If the user wants it working now, have them run `npx @colosseum-org/copilot-connect login` (Node 20+; `--device` where no browser can open) and check it with `status`. Never ask for a `COLOSSEUM_COPILOT_PAT` — that mechanism is retired.
4. Ask which optional MCP servers to add; the default is none, since each one starts with every session. Print the command for each one the user picks, for them to run — `Bash(claude *)` is denied at every firewall tier, since a nested `claude` re-rolls the whole policy. Each adds the server for this user and project only; append `--scope project` only if the user wants to share it through `.mcp.json`.
   - Playwright, browser automation (needs a browser Playwright can launch): `claude mcp add playwright -- npx -y @playwright/mcp@latest --headless`
   - Surfpool, local validator and mainnet-fork control: `claude mcp add surfpool -- surfpool mcp`. It needs the `surfpool` CLI on PATH; check with `command -v surfpool`, and if it is missing give the user the install command (`curl -L https://surfpool.run/install | sh` or `brew install txtx/taps/surfpool`) rather than running it.
   - Chainstack, multi-chain RPC platform control: `claude mcp add --transport http chainstack https://mcp.chainstack.com/mcp`. It needs a key from https://console.chainstack.com/user/settings/api-keys for most of what it does — node deployment, project management and testnet funding — passed as `--header "Authorization: Bearer <key>"` on that command. Five read-only tools (docs search, platform status, pricing) answer without one. Every tool is listed either way, so a keyless install looks complete and fails at the call; say which half works before the user adds it.
   - Nansen, wallet and token intelligence: `claude mcp add --transport http nansen https://mcp.nansen.ai/ra/mcp --header "NANSEN-API-KEY: <key>"`. Paid product: the server answers nothing without a key (a free API account at https://app.nansen.ai works within its credit limits; premium data needs a paid plan). It is also heavy — around 50 tool schemas load into context in every session it is attached to — so suggest it only when the user wants on-chain analytics, not as a default extra. Have the user paste the key into their own command; don't ask them to send it here.

   context-mode ships in `.mcp.json` as a default server, so it is not offered here.

   **Not in that list: Phantom** (`claude mcp add phantom -- npx -y @phantom/mcp-server`). Don't offer it alongside the servers above. It is a 29-tool wallet and trading surface, not a data source: `solana_sign`/`solana_send` and `evm_sign`/`evm_send` land signed transactions, and `buy`, `pay`, `transfer`, `wallet_rebalance`, `withdraw_from_hyperliquid_spot` and nine `perps_*` tools (open, close, leverage, deposit, withdraw) move real funds. It takes no key — `phantom_login` authenticates and keeps the session on disk — so nothing else stands between an attached server and a trade. Give the command only if the user asks for wallet or trading actions, and tell them what it exposes when you do.

## Output

Configured or skipped for each key (names only — nothing in this command ever holds a value past the append), grouped as MCP and skill/CLI, then the commands printed for the optional servers, then remind the user to restart Claude Code so the changes are picked up.
