---
description: "Configure MCP server API keys in .env and add the optional MCP servers"
model: sonnet
---

Walk the user through filling in `.env`. Secrets go in `.env`, never in `.mcp.json`.

## Steps

1. If `.env` is missing, copy `.env.example` to `.env` (or create an empty one).
2. For each key below, in order, ask the user to paste a value or say "skip". Write or update that line in `.env` and leave skipped keys empty. Don't echo values back.

   MCP server key (the only one `.mcp.json` reads):
   - `HELIUS_API_KEY`: Helius RPC and DAS API for the `helius` MCP server (https://dev.helius.xyz)

   Optional skill/CLI keys, read at runtime by skill CLIs in `.claude/skills/ext/`, not by any MCP server:
   - `COLOSSEUM_COPILOT_PAT`: Colosseum Copilot startup-research skill (PAT at https://arena.colosseum.org/copilot)
   - `COLOSSEUM_COPILOT_API_BASE`: the default `https://copilot.colosseum.com/api/v1` works for most
   - `MISTRAL_API_KEY`: QEDGen formal-verification CLI, for `fill-sorry` and `generate` (https://console.mistral.ai)
   - `ARISTOTLE_API_KEY`: QEDGen formal-verification CLI, for the `aristotle` proof-search commands (https://aristotle.harmonic.fun)
   - `THEGRID_API_KEY`: TheGrid Colosseum project-graph queries (https://thegrid.id)
   - `THEGRID_GRAPHQL_ENDPOINT`: the default `https://beta.node.thegrid.id/graphql` works for most
   - `QUICKNODE_RPC_URL`, `QUICKNODE_WSS_URL`, `QUICKNODE_API_KEY`: QuickNode RPC, WebSocket/Streams and DAS for the `quicknode` skill (https://www.quicknode.com)
   - `X_BEARER_TOKEN`: X API bearer token for the `ct-alpha` CT research skill (https://developer.x.com)
   - `DFLOW_API_KEY`: DFlow order-flow integration skill (credentials from hello@dflow.net)
3. Ask which optional MCP servers to add; the default is none, since each one starts with every session. Run the command for each one the user picks. It adds the server for this user and project only; append `--scope project` only if the user wants to share it through `.mcp.json`.
   - Playwright, browser automation (needs a browser Playwright can launch): `claude mcp add playwright -- npx -y @playwright/mcp@latest --headless`
   - Surfpool, local validator and mainnet-fork control: `claude mcp add surfpool -- surfpool mcp`. It needs the `surfpool` CLI on PATH; check with `command -v surfpool`, and if it is missing give the user the install command (`curl -L https://surfpool.run/install | sh` or `brew install txtx/taps/surfpool`) rather than running it.
   - context-mode, keeps large tool output out of context: `claude mcp add context-mode -- npx -y context-mode@latest`

## Output

Configured or skipped for each key (names only), grouped as MCP and skill/CLI, then the optional servers added, then remind the user to restart Claude Code so the changes are picked up.
